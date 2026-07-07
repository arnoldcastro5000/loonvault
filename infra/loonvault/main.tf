terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.region

  # Use regional STS endpoint — avoids us-east-1 SPOF (locked decision)
  endpoints {
    sts = "https://sts.ca-central-1.amazonaws.com"
  }

  default_tags {
    tags = local.tags
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_availability_zones" "available" { state = "available" }

locals {
  account_id  = data.aws_caller_identity.current.account_id
  region      = data.aws_region.current.name
  name_prefix = "loonvault"

  # Snapshots bucket lives in the always-on ../frontend stack. Its name is
  # deterministic, so the Transform Lambda references it without a remote-state
  # lookup (writes are identity-based, same account).
  snapshots_bucket = "${local.name_prefix}-snapshots"

  # ca-central-1 has AZs a, b, d — use first two for Lambda subnets
  az_a = data.aws_availability_zones.available.names[0]
  az_b = data.aws_availability_zones.available.names[1]

  tags = {
    Project     = "loonvault"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ── Shared KMS CMK (ADR-0005) ────────────────────────────────────────────────
# Single CMK for S3 raw zone, RDS, and Secrets Manager.
# S3 snapshots bucket uses SSE-S3 (public reads cannot decrypt SSE-KMS).
# Production upgrade: separate CMKs per service with independent key policies.
resource "aws_kms_key" "main" {
  description             = "LoonVault shared CMK — S3 raw zone, RDS, Secrets Manager"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RootFullAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${local.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        # CloudWatch Logs encrypts log groups directly — must be named in the key policy
        Sid       = "CloudWatchLogs"
        Effect    = "Allow"
        Principal = { Service = "logs.${local.region}.amazonaws.com" }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Describe*",
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${local.region}:${local.account_id}:log-group:*"
          }
        }
      },
      {
        # S3 event notifications write to the encrypted SQS transform queue
        Sid       = "S3ToEncryptedSQS"
        Effect    = "Allow"
        Principal = { Service = "s3.amazonaws.com" }
        Action    = ["kms:GenerateDataKey*", "kms:Decrypt"]
        Resource  = "*"
      },
      {
        # CloudWatch alarms publish to the encrypted SNS alerts topic
        Sid       = "CloudWatchAlarmsToSNS"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = ["kms:GenerateDataKey*", "kms:Decrypt"]
        Resource  = "*"
      },
      {
        # EventBridge detection rules publish to the encrypted SNS alerts topic (detection.tf)
        Sid       = "EventBridgeToSNS"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = ["kms:GenerateDataKey*", "kms:Decrypt"]
        Resource  = "*"
      },
    ]
  })
}

resource "aws_kms_alias" "main" {
  name          = "alias/${local.name_prefix}-main"
  target_key_id = aws_kms_key.main.key_id
}

# ── SNS topic for alerts ──────────────────────────────────────────────────────
resource "aws_sns_topic" "alerts" {
  name              = "${local.name_prefix}-alerts"
  kms_master_key_id = aws_kms_key.main.id
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# SNS resource policy: grants EventBridge permission to publish.
# Without this, EventBridge targets on the encrypted topic are silently dropped.
resource "aws_sns_topic_policy" "alerts" {
  arn = aws_sns_topic.alerts.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # SNS rejects "sns:*" in topic policies ("action out of service scope"):
        # the wildcard sweeps in account-level actions (CreateTopic, ListTopics)
        # that cannot apply to a topic. Enumerate the topic-scoped set instead —
        # the same list AWS's own __default_policy uses.
        Sid       = "AllowAccountManagement"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${local.account_id}:root" }
        Action = [
          "sns:AddPermission",
          "sns:DeleteTopic",
          "sns:GetTopicAttributes",
          "sns:ListSubscriptionsByTopic",
          "sns:Publish",
          "sns:RemovePermission",
          "sns:SetTopicAttributes",
          "sns:Subscribe",
          "sns:Receive",
        ]
        Resource = aws_sns_topic.alerts.arn
      },
      {
        Sid       = "AllowEventBridgePublish"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.alerts.arn
      },
    ]
  })
}
