output "website_url" { value = "https://${var.domain_name}" }
output "website_bucket_name" { value = aws_s3_bucket.website.bucket }
output "cloudfront_distribution_id" { value = aws_cloudfront_distribution.website.id }
output "visit_log_table_name" { value = aws_dynamodb_table.visit_logins.name }
output "login_export_endpoint" { value = "${aws_api_gateway_stage.login_export.invoke_url}/login-export" }
