# AWS deployment

The Terraform configuration in `terraform/` provisions a private S3 website bucket, CloudFront distribution, ACM certificate, Route 53 alias records, API Gateway HTTP API, Lambda visit logger, and the `virginia_home_logins` DynamoDB table.

The deployed hostname is `virginia-housing.marshall.mortgage`. The prior underscore form is not a valid DNS hostname.

## Required permission and input

Set the public Route 53 hosted-zone ID for `marshall.mortgage` before deployment:

```bash
export TF_VAR_hosted_zone_id=Z123EXAMPLE
```

The configured AWS identity needs permission to create and update Route 53 records in that zone, request and validate ACM certificates, create CloudFront, S3, API Gateway, Lambda, DynamoDB, IAM-role, and CloudWatch-log resources, and upload/invalidate the site.

## Deploy

```bash
./scripts/deploy-website.sh
```

The script builds the Vue application, packages the Lambda, applies Terraform, uploads `dist/` to the private S3 bucket, and invalidates CloudFront.
