variable "region" {
  description = "AWS region — locked to ca-central-1 for data residency (GR05 / OSFI B-13)"
  type        = string
  default     = "ca-central-1"

  validation {
    condition     = var.region == "ca-central-1"
    error_message = "LoonVault must deploy to ca-central-1 only (data residency requirement)."
  }
}
