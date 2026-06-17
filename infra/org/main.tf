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
# the deny condition. A small set of global-scoped S3 actions (account/bucket metadata,
# e.g. `aws s3 ls`) are also exempted: they resolve to us-east-1 and would otherwise be
# denied during normal operation. We intentionally do NOT exempt kms:*/config:* (unlike
# the AWS Control Tower baseline) so the region guardrail stays strict for our data-at-rest
# and config services, which live only in ca-central-1. See ADR-0009.
resource "aws_organizations_policy" "region_lock" {
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
          "s3:GetAccountPublicAccessBlock",
          "s3:GetBucketLocation",
          "s3:ListAllMyBuckets",
          "s3:PutAccountPublicAccessBlock",
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

# Workloads OU — holds the member account(s) that run LoonVault infrastructure.
# Function-based OU per AWS best practice (apply guardrails at the OU level, not root or
# account). The management account stays directly under root and is exempt from SCPs by
# design (it should remain near-empty). See ADR-0009.
resource "aws_organizations_organizational_unit" "workloads" {
  name      = "Workloads"
  parent_id = data.aws_organizations_organization.this.roots[0].id
}

# Attach the region-lock guardrail at the Workloads OU, not the org root: it scopes the
# control to the accounts that actually run workloads and follows the OU-level attachment
# best practice. The member account is moved into this OU out-of-band
# (`aws organizations move-account`) — see ADR-0009 and the runbook.
resource "aws_organizations_policy_attachment" "region_lock_workloads" {
  policy_id = aws_organizations_policy.region_lock.id
  target_id = aws_organizations_organizational_unit.workloads.id
}

output "root_id" {
  description = "Org root ID — source parent for `aws organizations move-account`."
  value       = data.aws_organizations_organization.this.roots[0].id
}

output "workloads_ou_id" {
  description = "Workloads OU ID — destination parent for `aws organizations move-account`."
  value       = aws_organizations_organizational_unit.workloads.id
}
