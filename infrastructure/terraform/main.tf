data "aws_caller_identity" "current" {}

locals {
  resource_prefix    = "${var.project_name}-${data.aws_caller_identity.current.account_id}"
  lambda_zip         = "${path.module}/../../lambda/visit-logger/function.zip"
  login_exporter_zip = "${path.module}/../../lambda/login-exporter/function.zip"
  api_origin         = trimprefix(aws_apigatewayv2_api.visit_logger.api_endpoint, "https://")
}

resource "aws_dynamodb_table" "visit_logins" {
  name         = "virginia_home_logins"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "request_id"
  attribute {
    name = "request_id"
    type = "S"
  }
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }
  point_in_time_recovery { enabled = true }
}

resource "aws_iam_role" "visit_logger" {
  name               = "${var.project_name}-visit-logger"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }] })
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.visit_logger.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "visit_logger_dynamodb" {
  name   = "write-virginia-home-logins"
  role   = aws_iam_role.visit_logger.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["dynamodb:PutItem"], Resource = aws_dynamodb_table.visit_logins.arn }] })
}

resource "aws_lambda_function" "visit_logger" {
  function_name    = "${var.project_name}-visit-logger"
  role             = aws_iam_role.visit_logger.arn
  handler          = "index.handler"
  runtime          = "nodejs22.x"
  filename         = local.lambda_zip
  source_code_hash = filebase64sha256(local.lambda_zip)
  timeout          = 10
  environment { variables = { LOG_TABLE_NAME = aws_dynamodb_table.visit_logins.name, LOG_RETENTION_DAYS = var.log_retention_days } }
}

resource "aws_apigatewayv2_api" "visit_logger" {
  name          = "${var.project_name}-visit-logger"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "visit_logger" {
  api_id                 = aws_apigatewayv2_api.visit_logger.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.visit_logger.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "visit_logger" {
  api_id    = aws_apigatewayv2_api.visit_logger.id
  route_key = "POST /api/visit"
  target    = "integrations/${aws_apigatewayv2_integration.visit_logger.id}"
}

resource "aws_apigatewayv2_stage" "visit_logger" {
  api_id      = aws_apigatewayv2_api.visit_logger.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.visit_logger.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.visit_logger.execution_arn}/*/*"
}

resource "aws_s3_bucket" "website" { bucket = "${local.resource_prefix}-website" }

resource "aws_s3_bucket_public_access_block" "website" {
  bucket                  = aws_s3_bucket.website.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "website" {
  name                              = "${var.project_name}-website"
  description                       = "CloudFront access to the private Virginia home website bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_cache_policy" "api_no_cache" {
  name        = "${var.project_name}-api-no-cache"
  default_ttl = 0
  max_ttl     = 0
  min_ttl     = 0
  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config { cookie_behavior = "none" }
    headers_config { header_behavior = "none" }
    query_strings_config { query_string_behavior = "none" }
  }
}

resource "aws_cloudfront_origin_request_policy" "viewer_location" {
  name = "${var.project_name}-viewer-location"
  cookies_config { cookie_behavior = "none" }
  query_strings_config { query_string_behavior = "none" }
  headers_config {
    header_behavior = "whitelist"
    headers { items = ["CloudFront-Viewer-Address", "CloudFront-Viewer-City", "CloudFront-Viewer-Country", "CloudFront-Viewer-Latitude", "CloudFront-Viewer-Longitude", "CloudFront-Viewer-Postal-Code", "CloudFront-Viewer-Region", "CloudFront-Viewer-Region-Name", "CloudFront-Viewer-Time-Zone", "User-Agent"] }
  }
}

resource "aws_acm_certificate" "site" {
  provider          = aws.us_east_1
  domain_name       = var.domain_name
  validation_method = "DNS"
}

resource "aws_route53_record" "certificate_validation" {
  for_each        = { for option in aws_acm_certificate.site.domain_validation_options : option.domain_name => { name = option.resource_record_name, record = option.resource_record_value, type = option.resource_record_type } }
  zone_id         = var.hosted_zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "site" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.site.arn
  validation_record_fqdns = [for record in aws_route53_record.certificate_validation : record.fqdn]
}

resource "aws_cloudfront_distribution" "website" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  aliases             = [var.domain_name]
  price_class         = "PriceClass_100"
  origin {
    domain_name              = aws_s3_bucket.website.bucket_regional_domain_name
    origin_id                = "website-s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.website.id
  }
  origin {
    domain_name = local.api_origin
    origin_id   = "visit-logger-api"
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }
  default_cache_behavior {
    target_origin_id       = "website-s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }
  ordered_cache_behavior {
    path_pattern             = "/api/*"
    target_origin_id         = "visit-logger-api"
    viewer_protocol_policy   = "https-only"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "POST", "PUT", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = aws_cloudfront_cache_policy.api_no_cache.id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.viewer_location.id
  }
  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }
  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.site.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

resource "aws_s3_bucket_policy" "website" {
  bucket = aws_s3_bucket.website.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Sid = "AllowCloudFrontRead", Effect = "Allow", Principal = { Service = "cloudfront.amazonaws.com" }, Action = "s3:GetObject", Resource = "${aws_s3_bucket.website.arn}/*", Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.website.arn } } }] })
}

resource "aws_s3_bucket" "login_exports" {
  bucket = "${local.resource_prefix}-login-exports"
}

resource "aws_s3_bucket_public_access_block" "login_exports" {
  bucket                  = aws_s3_bucket.login_exports.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "login_exports" {
  bucket = aws_s3_bucket.login_exports.id
  rule {
    id     = "expire-login-exports"
    status = "Enabled"
    filter {}
    expiration { days = 1 }
  }
}

resource "aws_iam_role" "login_exporter" {
  name               = "${var.project_name}-login-exporter"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }] })
}

resource "aws_iam_role_policy_attachment" "login_exporter_logs" {
  role       = aws_iam_role.login_exporter.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "login_exporter_data" {
  name = "export-virginia-home-logins"
  role = aws_iam_role.login_exporter.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["dynamodb:Scan"], Resource = aws_dynamodb_table.visit_logins.arn },
      { Effect = "Allow", Action = ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"], Resource = "${aws_s3_bucket.login_exports.arn}/login-exports/*" }
    ]
  })
}

resource "aws_lambda_function" "login_exporter" {
  function_name    = "${var.project_name}-login-exporter"
  role             = aws_iam_role.login_exporter.arn
  handler          = "index.handler"
  runtime          = "nodejs22.x"
  filename         = local.login_exporter_zip
  source_code_hash = filebase64sha256(local.login_exporter_zip)
  timeout          = 120
  memory_size      = 512
  environment {
    variables = {
      LOG_TABLE_NAME           = aws_dynamodb_table.visit_logins.name
      EXPORT_BUCKET_NAME       = aws_s3_bucket.login_exports.bucket
      DOWNLOAD_URL_TTL_SECONDS = var.login_export_download_url_ttl_seconds
    }
  }
}

# API Gateway resource policy enforces a network-level allowlist before the
# exporter Lambda can run. The endpoint is intentionally separate from the
# public visit logger and is never added to the CloudFront distribution.
resource "aws_api_gateway_rest_api" "login_export" {
  name = "${var.project_name}-login-export"
  endpoint_configuration { types = ["REGIONAL"] }
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Principal = "*", Action = "execute-api:Invoke", Resource = "execute-api:/*" },
      { Effect = "Deny", Principal = "*", Action = "execute-api:Invoke", Resource = "execute-api:/*", Condition = { NotIpAddress = { "aws:SourceIp" = var.login_export_allowed_ip_cidr } } }
    ]
  })
}

resource "aws_api_gateway_resource" "login_export" {
  rest_api_id = aws_api_gateway_rest_api.login_export.id
  parent_id   = aws_api_gateway_rest_api.login_export.root_resource_id
  path_part   = "login-export"
}

resource "aws_api_gateway_method" "login_export" {
  rest_api_id   = aws_api_gateway_rest_api.login_export.id
  resource_id   = aws_api_gateway_resource.login_export.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "login_export" {
  rest_api_id             = aws_api_gateway_rest_api.login_export.id
  resource_id             = aws_api_gateway_resource.login_export.id
  http_method             = aws_api_gateway_method.login_export.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.login_exporter.invoke_arn
}

resource "aws_lambda_permission" "login_export_api_gateway" {
  statement_id  = "AllowLoginExportApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.login_exporter.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.login_export.execution_arn}/*/POST/login-export"
}

resource "aws_api_gateway_deployment" "login_export" {
  rest_api_id = aws_api_gateway_rest_api.login_export.id
  depends_on  = [aws_api_gateway_integration.login_export]
  triggers = {
    redeployment = sha1(jsonencode([aws_api_gateway_resource.login_export.id, aws_api_gateway_method.login_export.id, aws_api_gateway_integration.login_export.id]))
  }
}

resource "aws_api_gateway_stage" "login_export" {
  rest_api_id   = aws_api_gateway_rest_api.login_export.id
  deployment_id = aws_api_gateway_deployment.login_export.id
  stage_name    = "v1"
}

resource "aws_route53_record" "site" {
  zone_id = var.hosted_zone_id
  name    = var.domain_name
  type    = "A"
  alias {
    name                   = aws_cloudfront_distribution.website.domain_name
    zone_id                = aws_cloudfront_distribution.website.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "site_ipv6" {
  zone_id = var.hosted_zone_id
  name    = var.domain_name
  type    = "AAAA"
  alias {
    name                   = aws_cloudfront_distribution.website.domain_name
    zone_id                = aws_cloudfront_distribution.website.hosted_zone_id
    evaluate_target_health = false
  }
}
