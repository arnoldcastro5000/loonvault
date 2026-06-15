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
