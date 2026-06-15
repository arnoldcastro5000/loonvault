# LoonVault frontend stack — ALWAYS-ON.
#
# This stack holds the resources that stay up 24×7 and survive a backend
# `terraform destroy`: the public S3 snapshots bucket (and, later, the static
# site bucket + Cloudflare). The ephemeral backend (RDS, Lambdas, API, VPC)
# lives in ../loonvault and is applied before interviews and destroyed after.
# See ADR-0004 (snapshots for frontend resilience) and the deploy runbook.
terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}

data "aws_caller_identity" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  name_prefix = "loonvault"

  tags = {
    Project     = "loonvault"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
