# Detection pipeline: 9 rules
#
# 8 EventBridge rules  → SNS  (single-occurrence, high-signal events)
# 1 CW metric filter   → alarm → SNS  (rate-based: AccessDenied spike)
#
# Infrastructure: a member-account CloudTrail trail delivering management events
# to CloudWatch Logs. This enables the AccessDenied metric filter (rule 6) and
# captures IAM/sign-in events from us-east-1 into the ca-central-1 log group via
# multi-region delivery. The organisation-wide trail in the management account is
# the durable, tamper-resistant record; this trail's purpose is CW Logs access.
# First trail per account per region: management events are free.
# See plan.md §Detection Pipeline and docs/threat-model.md §5.10.

# ── S3 bucket for trail log delivery ─────────────────────────────────────────

resource "aws_s3_bucket" "cloudtrail" {
  #checkov:skip=CKV_AWS_18:access logging on this bucket creates a circular dependency; org trail S3 bucket has logging
  #checkov:skip=CKV2_AWS_61:force_destroy required — bucket is ephemeral and destroyed with loonvault-destroy
  #checkov:skip=CKV_AWS_145:SSE-S3 (AES256) is sufficient for ephemeral trail logs; org trail bucket uses CMK
  bucket        = "${local.name_prefix}-cloudtrail-${local.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  bucket                  = aws_s3_bucket.cloudtrail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  rule {
    id     = "expire-logs"
    status = "Enabled"
    filter {}
    expiration { days = 731 }
  }
  depends_on = [aws_s3_bucket_versioning.cloudtrail]
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSCloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.cloudtrail.arn
        Condition = {
          StringEquals = {
            "aws:SourceArn" = "arn:aws:cloudtrail:${local.region}:${local.account_id}:trail/${local.name_prefix}"
          }
        }
      },
      {
        Sid       = "AWSCloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${local.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"  = "bucket-owner-full-control"
            "aws:SourceArn" = "arn:aws:cloudtrail:${local.region}:${local.account_id}:trail/${local.name_prefix}"
          }
        }
      },
      {
        Sid       = "DenyHTTP"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.cloudtrail.arn, "${aws_s3_bucket.cloudtrail.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })
  depends_on = [aws_s3_bucket_public_access_block.cloudtrail]
}

# ── CloudWatch Logs group for trail delivery ──────────────────────────────────
# 730-day retention meets the Protected B 2-year requirement (passes CKV_AWS_338).

resource "aws_cloudwatch_log_group" "cloudtrail" {
  name              = "/aws/cloudtrail/${local.name_prefix}"
  retention_in_days = 731
  kms_key_id        = aws_kms_key.main.arn
}

# ── IAM: CloudTrail → CloudWatch Logs delivery role ───────────────────────────

resource "aws_iam_role" "cloudtrail_cwl" {
  name = "${local.name_prefix}-cloudtrail-cwl"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudtrail.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "cloudtrail_cwl" {
  name = "${local.name_prefix}-cloudtrail-cwl"
  role = aws_iam_role.cloudtrail_cwl.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
    }]
  })
}

# ── Member-account CloudTrail trail ───────────────────────────────────────────

resource "aws_cloudtrail" "main" {
  name                          = local.name_prefix
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true
  cloud_watch_logs_group_arn    = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
  cloud_watch_logs_role_arn     = aws_iam_role.cloudtrail_cwl.arn

  event_selector {
    read_write_type           = "All"
    include_management_events = true
  }

  depends_on = [aws_s3_bucket_policy.cloudtrail]
}

# ── Ops alarm (G-03) ─────────────────────────────────────────────────────────
# Fires when any message lands in the transform DLQ — signals a failed ingest.

resource "aws_cloudwatch_metric_alarm" "transform_dlq_depth" {
  alarm_name          = "${local.name_prefix}-transform-dlq-depth"
  alarm_description   = "Messages in transform DLQ - ingest pipeline failed (G-03)"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.transform_dlq.name }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# ── EventBridge rules 1–5, 7–9 → SNS ────────────────────────────────────────
# EventBridge publishes to SNS via the SNS resource policy (aws_sns_topic_policy
# in main.tf). No IAM role_arn is needed on SNS targets.

# Rule 1: CloudTrail disabled (B-13: Security monitoring & response)
resource "aws_cloudwatch_event_rule" "cloudtrail_disabled" {
  name        = "${local.name_prefix}-cloudtrail-disabled"
  description = "Rule 1: CloudTrail stopped or deleted — audit trail integrity at risk"
  event_pattern = jsonencode({
    source      = ["aws.cloudtrail"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["cloudtrail.amazonaws.com"]
      eventName   = ["StopLogging", "DeleteTrail", "UpdateTrail"]
    }
  })
}

resource "aws_cloudwatch_event_target" "cloudtrail_disabled" {
  rule      = aws_cloudwatch_event_rule.cloudtrail_disabled.name
  target_id = "alerts"
  arn       = aws_sns_topic.alerts.arn
}

# Rule 2: Console sign-in without MFA (B-13: Identity & access management)
resource "aws_cloudwatch_event_rule" "no_mfa_signin" {
  name        = "${local.name_prefix}-no-mfa-signin"
  description = "Rule 2: Console sign-in succeeded without MFA"
  event_pattern = jsonencode({
    source      = ["aws.signin"]
    detail-type = ["AWS Console Sign In via CloudTrail"]
    detail = {
      eventName = ["ConsoleLogin"]
      additionalEventData = {
        MFAUsed = ["No"]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "no_mfa_signin" {
  rule      = aws_cloudwatch_event_rule.no_mfa_signin.name
  target_id = "alerts"
  arn       = aws_sns_topic.alerts.arn
}

# Rule 3: Root account used (B-13: Identity & access management)
# No source filter: root can call any service. Matches both API calls and sign-ins.
resource "aws_cloudwatch_event_rule" "root_usage" {
  name        = "${local.name_prefix}-root-usage"
  description = "Rule 3: Any action by the root account"
  event_pattern = jsonencode({
    detail-type = ["AWS API Call via CloudTrail", "AWS Console Sign In via CloudTrail"]
    detail = {
      userIdentity = {
        type = ["Root"]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "root_usage" {
  rule      = aws_cloudwatch_event_rule.root_usage.name
  target_id = "alerts"
  arn       = aws_sns_topic.alerts.arn
}

# Rule 4: IAM policy changed (B-13: Identity & access management)
resource "aws_cloudwatch_event_rule" "iam_policy_change" {
  name        = "${local.name_prefix}-iam-policy-change"
  description = "Rule 4: IAM policy attached, created, or modified"
  event_pattern = jsonencode({
    source      = ["aws.iam"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["iam.amazonaws.com"]
      eventName = [
        "AttachRolePolicy", "AttachUserPolicy", "AttachGroupPolicy",
        "CreatePolicy", "CreatePolicyVersion",
        "PutRolePolicy", "PutUserPolicy", "PutGroupPolicy",
        "DetachRolePolicy", "DetachUserPolicy", "DetachGroupPolicy",
        "DeleteUserPolicy", "DeleteRolePolicy",
      ]
    }
  })
}

resource "aws_cloudwatch_event_target" "iam_policy_change" {
  rule      = aws_cloudwatch_event_rule.iam_policy_change.name
  target_id = "alerts"
  arn       = aws_sns_topic.alerts.arn
}

# Rule 5: Security group rule changed (B-13: Infrastructure security)
resource "aws_cloudwatch_event_rule" "sg_change" {
  name        = "${local.name_prefix}-sg-change"
  description = "Rule 5: Security group ingress or egress rule added or removed"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["ec2.amazonaws.com"]
      eventName = [
        "AuthorizeSecurityGroupIngress", "RevokeSecurityGroupIngress",
        "AuthorizeSecurityGroupEgress", "RevokeSecurityGroupEgress",
      ]
    }
  })
}

resource "aws_cloudwatch_event_target" "sg_change" {
  rule      = aws_cloudwatch_event_rule.sg_change.name
  target_id = "alerts"
  arn       = aws_sns_topic.alerts.arn
}

# Rule 7: KMS CMK disabled or deletion scheduled (B-13: Data security at rest, G-04)
# CancelKeyDeletion is included: a cancelled deletion implies a prior ScheduleKeyDeletion
# that must be investigated even if reversed.
# No keyId scoping: any KMS lifecycle event in this account is anomalous at LoonVault's
# scale (one CMK), and ARN-scoping silently breaks after every destroy/apply.
resource "aws_cloudwatch_event_rule" "kms_key_lifecycle" {
  name        = "${local.name_prefix}-kms-key-lifecycle"
  description = "Rule 7: KMS CMK disabled or scheduled for deletion — all encrypted data at risk (G-04)"
  event_pattern = jsonencode({
    source      = ["aws.kms"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["kms.amazonaws.com"]
      eventName   = ["DisableKey", "ScheduleKeyDeletion", "CancelKeyDeletion"]
    }
  })
}

resource "aws_cloudwatch_event_target" "kms_key_lifecycle" {
  rule      = aws_cloudwatch_event_rule.kms_key_lifecycle.name
  target_id = "alerts"
  arn       = aws_sns_topic.alerts.arn
}

# Rule 8: Anomalous GetSecretValue (B-13: Identity & access management, G-12)
# Zero-baseline signal: no Lambda execution role holds secretsmanager:GetSecretValue.
# The only secret is the RDS-managed master password; RDS handles rotation internally
# as the rds.amazonaws.com service principal. Any other caller is a compromise indicator.
# Known false positive: RDS rotation — see runbook §Expected alerts on first apply.
resource "aws_cloudwatch_event_rule" "secrets_access" {
  name        = "${local.name_prefix}-secrets-access"
  description = "Rule 8: GetSecretValue called — no Lambda holds this permission (G-12)"
  event_pattern = jsonencode({
    source      = ["aws.secretsmanager"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["secretsmanager.amazonaws.com"]
      eventName   = ["GetSecretValue"]
    }
  })
}

resource "aws_cloudwatch_event_target" "secrets_access" {
  rule      = aws_cloudwatch_event_rule.secrets_access.name
  target_id = "alerts"
  arn       = aws_sns_topic.alerts.arn
}

# Rule 9: Detection rule tampered (B-13: Security monitoring & response, G-05)
# Watches suppression-class operations only. PutRule is excluded: every loonvault-apply
# fires it on managed rules, producing false positives. Residual: rule 9 cannot detect
# its own deletion (self-referential problem — see T-038 in threat model).
resource "aws_cloudwatch_event_rule" "detection_tampering" {
  name        = "${local.name_prefix}-detection-tampering"
  description = "Rule 9: EventBridge rule deleted, disabled, or detargeted (G-05)"
  event_pattern = jsonencode({
    source      = ["aws.events"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["events.amazonaws.com"]
      eventName   = ["DeleteRule", "DisableRule", "RemoveTargets"]
    }
  })
}

resource "aws_cloudwatch_event_target" "detection_tampering" {
  rule      = aws_cloudwatch_event_rule.detection_tampering.name
  target_id = "alerts"
  arn       = aws_sns_topic.alerts.arn
}

# ── Rule 6: AccessDenied spike (B-13: Security monitoring & response) ─────────
# Rate-based: EventBridge has no memory across events; counting requires a metric
# filter over a time window. CIS filter pattern (Security Hub enforces verbatim):
# matches AccessDenied and *UnauthorizedOperation. Fingerprints credential
# enumeration (Pacu, ScoutSuite): one denial is noise; 5+ in 5 min is a signal.

resource "aws_cloudwatch_log_metric_filter" "access_denied" {
  name           = "${local.name_prefix}-access-denied"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name
  pattern        = "{($.errorCode=\"AccessDenied\") || ($.errorCode=\"*UnauthorizedOperation\")}"

  metric_transformation {
    name          = "AccessDeniedCount"
    namespace     = "LoonVault/Security"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "access_denied_spike" {
  alarm_name          = "${local.name_prefix}-access-denied-spike"
  alarm_description   = "Rule 6: >5 AccessDenied errors in 5 min — possible credential enumeration (Pacu/ScoutSuite)"
  namespace           = "LoonVault/Security"
  metric_name         = "AccessDeniedCount"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}
