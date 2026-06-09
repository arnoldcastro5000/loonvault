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

  endpoints {
    sts = "https://sts.ca-central-1.amazonaws.com"
  }
}

data "aws_organizations_organization" "this" {}

# Deny all non-global AWS actions outside ca-central-1.
# Global services (IAM, STS, Route53, CloudFront, etc.) are excluded via NotAction
# because their API endpoints are not region-scoped and would otherwise always match
# the deny condition.
resource "aws_organizations_policy" "region_lock" {
  #checkov:skip=CKV_AWS_363:SCP is intentionally attached to org root — single-account org with no sub-OUs
  name        = "loonvault-region-lock"
  description = "Deny all non-global AWS actions outside ca-central-1 (GR05 / OSFI B-13)"
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyOutsideCaCentral1"
        Effect = "Deny"
        NotAction = [
          "account:*",
          "billing:*",
          "budgets:*",
          "ce:*",
          "cloudfront:*",
          "cur:*",
          "freetier:*",
          "globalaccelerator:*",
          "health:*",
          "iam:*",
          "networkmanager:*",
          "organizations:*",
          "pricing:*",
          "route53:*",
          "route53domains:*",
          "route53resolver:*",
          "savingsplans:*",
          "shield:*",
          "sts:*",
          "support:*",
          "tax:*",
          "trustedadvisor:*",
          "waf:*"
        ]
        Resource = "*"
        Condition = {
          StringNotEquals = {
            "aws:RequestedRegion" = "ca-central-1"
          }
        }
      }
    ]
  })
}

resource "aws_organizations_policy_attachment" "region_lock_root" {
  policy_id = aws_organizations_policy.region_lock.id
  target_id = data.aws_organizations_organization.this.roots[0].id
}
