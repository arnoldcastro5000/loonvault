variable "region" {
  description = "AWS region — locked to ca-central-1 for data residency (GR05 / OSFI B-13)"
  type        = string
  default     = "ca-central-1"

  validation {
    condition     = var.region == "ca-central-1"
    error_message = "LoonVault must deploy to ca-central-1 only (data residency requirement)."
  }
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be dev or prod."
  }
}

variable "db_name" {
  description = "Postgres database name"
  type        = string
  default     = "loonvault"
}

variable "db_master_username" {
  description = "Postgres master username"
  type        = string
  default     = "loonvault_admin"
}

variable "alert_email" {
  description = "Email address for CloudWatch SNS alerts"
  type        = string
}

variable "origin_secret_ssm_path" {
  description = "SSM Parameter Store path for the X-Origin-Secret token (G-01: must be SecureString)"
  type        = string
  default     = "/loonvault/origin-secret"
}

variable "site_origin" {
  description = "Frontend origin allowed by the API's CORS policy (browser calls the live API from this site)"
  type        = string
  default     = "https://loonvault.cloudsecuritypractice.com"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "reserved_concurrency_enabled" {
  description = "Set per-function Lambda reserved concurrency (G-02 flood protection). Requires the account Lambda concurrency quota above the default 10 — new accounts start at 10, leaving nothing to reserve. Raise Service Quotas L-B99A9384 (Lambda 'Concurrent executions') to 1000, then set this true."
  type        = bool
  default     = false
}
