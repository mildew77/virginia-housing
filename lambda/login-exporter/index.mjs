import { DynamoDBClient, ScanCommand } from '@aws-sdk/client-dynamodb'
import { GetObjectCommand, S3Client } from '@aws-sdk/client-s3'
import { Upload } from '@aws-sdk/lib-storage'
import { getSignedUrl } from '@aws-sdk/s3-request-presigner'
import { randomUUID } from 'node:crypto'
import { PassThrough } from 'node:stream'

const dynamodb = new DynamoDBClient({})
const s3 = new S3Client({})
const tableName = process.env.LOG_TABLE_NAME
const exportBucket = process.env.EXPORT_BUCKET_NAME
const downloadUrlTtlSeconds = Number(process.env.DOWNLOAD_URL_TTL_SECONDS || 300)

const columns = [
  'request_id', 'accessed_at', 'expires_at', 'ip_address', 'user_agent', 'button_click',
  'country_code', 'country_name', 'city', 'region_code', 'region_name',
  'postal_code', 'latitude', 'longitude', 'time_zone',
]

const stringValue = (attribute) => attribute?.S || ''
const escapeCsv = (value) => `"${String(value ?? '').replaceAll('"', '""')}"`

function toCsvRow(item) {
  const location = item.location?.M || {}
  const values = {
    request_id: stringValue(item.request_id),
    accessed_at: stringValue(item.accessed_at),
    expires_at: item.expires_at?.N || '',
    ip_address: stringValue(item.ip_address),
    user_agent: stringValue(item.user_agent),
    button_click: item.button_click?.BOOL === true ? 'TRUE' : 'FALSE',
    country_code: stringValue(location.country_code),
    country_name: stringValue(location.country_name),
    city: stringValue(location.city),
    region_code: stringValue(location.region_code),
    region_name: stringValue(location.region_name),
    postal_code: stringValue(location.postal_code),
    latitude: stringValue(location.latitude),
    longitude: stringValue(location.longitude),
    time_zone: stringValue(location.time_zone),
  }
  return columns.map((column) => escapeCsv(values[column])).join(',')
}

export const handler = async () => {
  if (!tableName || !exportBucket) throw new Error('LOG_TABLE_NAME and EXPORT_BUCKET_NAME must be configured.')

  const timestamp = new Date().toISOString().replaceAll(':', '-').replaceAll('.', '-')
  const key = `login-exports/virginia_home_logins-${timestamp}-${randomUUID()}.csv`
  const csv = new PassThrough()
  const upload = new Upload({
    client: s3,
    params: {
      Bucket: exportBucket,
      Key: key,
      Body: csv,
      ContentType: 'text/csv; charset=utf-8',
      ServerSideEncryption: 'AES256',
    },
  })
  csv.write(`${columns.join(',')}\n`)
  let lastEvaluatedKey
  let count = 0
  console.info('Starting login export', { tableName })

  do {
    const response = await dynamodb.send(new ScanCommand({
      TableName: tableName,
      ExclusiveStartKey: lastEvaluatedKey,
    }))
    for (const item of response.Items || []) csv.write(`${toCsvRow(item)}\n`)
    count += response.Count || 0
    lastEvaluatedKey = response.LastEvaluatedKey
  } while (lastEvaluatedKey)

  csv.end()
  await upload.done()

  const downloadUrl = await getSignedUrl(s3, new GetObjectCommand({ Bucket: exportBucket, Key: key }), {
    expiresIn: downloadUrlTtlSeconds,
  })
  console.info('Login export created', { count, key })

  return {
    statusCode: 200,
    headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
    body: JSON.stringify({
      record_count: count,
      download_url: downloadUrl,
      expires_in_seconds: downloadUrlTtlSeconds,
    }),
  }
}
