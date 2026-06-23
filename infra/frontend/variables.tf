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

# Dedicated site origin secret — an SSM SecureString you create OUT OF BAND so the
# value never enters Terraform state (ADR-0013). Cloudflare injects this value as the
# X-Origin-Secret header; the site Lambda validates it.
variable "origin_secret_ssm_path" {
  description = "SSM Parameter Store path of the site's X-Origin-Secret (SecureString)"
  type        = string
  default     = "/loonvault/frontend/origin-secret"
}

# Cross-origin endpoints the site's live-data panel calls — folded into the CSP
# connect-src so the strict policy still permits the API + snapshots fetches.
variable "api_origin" {
  description = "Public API origin allowed in the site CSP connect-src"
  type        = string
  default     = "https://api-loonvault.cloudsecuritypractice.com"
}

variable "snapshot_origin" {
  description = "Public snapshots origin allowed in the site CSP connect-src"
  type        = string
  default     = "https://snapshots-loonvault.cloudsecuritypractice.com"
}
