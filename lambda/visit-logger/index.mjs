import { DynamoDBClient, PutItemCommand } from '@aws-sdk/client-dynamodb'
import { randomUUID } from 'node:crypto'

const client = new DynamoDBClient({})
const tableName = process.env.LOG_TABLE_NAME
const retentionDays = Number(process.env.LOG_RETENTION_DAYS || 90)
const header = (headers, name) => headers[name] || headers[name.toLowerCase()] || null
const requestBody = (event) => {
  try {
    return event.body ? JSON.parse(event.body) : {}
  } catch {
    return {}
  }
}

export const handler = async (event) => {
  const headers = event.headers || {}
  const buttonClick = requestBody(event).button_click === true
  const accessedAt = new Date()
  const requestId = event.requestContext?.requestId || randomUUID()
  const expiresAt = Math.floor(accessedAt.getTime() / 1000) + (retentionDays * 24 * 60 * 60)
  const viewerAddress = header(headers, 'cloudfront-viewer-address')
  const sourceIp = viewerAddress
    ? viewerAddress.replace(/^\[([^\]]+)\]:\d+$/, '$1').replace(/^(.+):\d+$/, '$1')
    : event.requestContext?.http?.sourceIp || null
  const location = {
    country_code: header(headers, 'cloudfront-viewer-country'), country_name: header(headers, 'cloudfront-viewer-country-name'), city: header(headers, 'cloudfront-viewer-city'), region_code: header(headers, 'cloudfront-viewer-region'), region_name: header(headers, 'cloudfront-viewer-region-name'), postal_code: header(headers, 'cloudfront-viewer-postal-code'), latitude: header(headers, 'cloudfront-viewer-latitude'), longitude: header(headers, 'cloudfront-viewer-longitude'), time_zone: header(headers, 'cloudfront-viewer-time-zone'),
  }

  console.info('Visit logger invoked', { requestId, buttonClick, hasViewerAddress: Boolean(viewerAddress), countryCode: location.country_code })
  try {
    await client.send(new PutItemCommand({
      TableName: tableName,
      Item: {
        request_id: { S: requestId }, accessed_at: { S: accessedAt.toISOString() }, expires_at: { N: String(expiresAt) },
        ip_address: sourceIp ? { S: sourceIp } : { NULL: true },
        user_agent: header(headers, 'user-agent') ? { S: header(headers, 'user-agent') } : { NULL: true },
        button_click: { BOOL: buttonClick },
        location: { M: Object.fromEntries(Object.entries(location).map(([key, value]) => [key, value ? { S: value } : { NULL: true }])) },
      },
    }))
    console.info('Visit logged', { requestId, buttonClick, tableName })
    return { statusCode: 204, headers: { 'cache-control': 'no-store' }, body: '' }
  } catch (error) {
    console.error('Visit logging failed', { requestId, name: error?.name, message: error?.message })
    throw error
  }
}
