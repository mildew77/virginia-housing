variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "virginia-home"
}

variable "domain_name" {
  description = "CloudFront alternate domain name. DNS host labels may use letters, numbers, and hyphens only."
  type        = string
  default     = "virginia-housing.marshall.mortgage"
  validation {
    condition     = can(regex("^[a-z0-9-]+(\\.[a-z0-9-]+)+$", var.domain_name))
    error_message = "domain_name must be a valid DNS hostname with no underscores."
  }
}

variable "hosted_zone_id" {
  description = "Route 53 public hosted-zone ID for marshall.mortgage."
  type        = string
  sensitive   = true
}

variable "log_retention_days" {
  type    = number
  default = 90
}

variable "login_export_allowed_ip_cidr" {
  description = "Public IPv4 CIDR allowed to request login-table CSV exports, for example 203.0.113.10/32."
  type        = string
  sensitive   = true
  validation {
    condition     = can(cidrhost(var.login_export_allowed_ip_cidr, 0))
    error_message = "login_export_allowed_ip_cidr must be a valid IPv4 or IPv6 CIDR."
  }
}

variable "login_export_download_url_ttl_seconds" {
  description = "How long an issued private S3 download URL remains valid."
  type        = number
  default     = 300
  validation {
    condition     = var.login_export_download_url_ttl_seconds >= 60 && var.login_export_download_url_ttl_seconds <= 900
    error_message = "login_export_download_url_ttl_seconds must be between 60 and 900 seconds."
  }
}
