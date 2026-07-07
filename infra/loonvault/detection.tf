# Detection pipeline: 9 rules
#
# 5 EventBridge rules  → SNS           (regional services; near-real-time)
# 4 CW metric filters  → alarm → SNS   (rules 2/3/4: global-service events;
#                                       rule 6: rate-based AccessDenied spike)
#
# Why two transports (ADR-0014): EventBridge only sees global-service events
# (IAM, console sign-in) on the us-east-1 bus, and the region-lock SCP
# (ADR-0009) denies creating rules there. The multi-region member trail already
# delivers those same events into the ca-central-1 log group, so rules 2/3/4 use
# the CIS AWS Foundations metric-filter pattern instead — the same mechanism
# Security Hub's CloudWatch.1/.3/.4 controls check for verbatim. Trade-off:
# ~5-10 min alert latency vs seconds, documented in plan.md residuals.
#
# Infrastructure: a member-account CloudTrail trail delivering management events
# to CloudWatch Logs. This feeds all four metric filters and captures IAM/
# sign-in events from us-east-1 into the ca-central-1 log group via
# multi-region delivery. The organisation-wide trail in the management account is
# the durable, tamper-resistant record; this trail's purpose is CW Logs access.
# First trail per account per region: management events are free.
# See plan.md §Detection Pipeline and docs/threat-model.md §5.10.

# ── S3 bucket for trail log delivery ─────────────────────────────────────────

resource "aws_s3_bucket" "cloudtrail" {
  #checkov:skip=CKV_AWS_18:access logging on this bucket creates a circular dependency; org trail S3 bucket has logging
  #checkov:skip=CKV2_AWS_61:force_destroy required — bucket is ephemeral and destroyed with loonvault-destroy
  #checkov:skip=CKV_AWS_145:SSE-S3 (AES256) is sufficient for ephemeral trail logs; org trail bucket uses CMK
  #checkov:skip=CKV_AWS_144:Cross-region replication not required for ephemeral portfolio POC
  #checkov:skip=CKV2_AWS_62:No event notifications on the trail log bucket
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
    # 30 days: live feed, not a retention store (force_destroy bucket). Protected B's
    # 2-year requirement is documented as a cost residual in plan.md; org trail is durable.
    expiration { days = 30 }
    # Reclaim storage from failed CloudTrail multipart deliveries (CKV_AWS_300)
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
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
# 30-day retention: this is the live feed rule 6's metric filter reads, NOT a retention
# system of record. The member trail's bucket is force_destroyed on every teardown, so
# long retention here is cosmetic, and the metric filter alarms on ingestion, not on
# stored history. The persistent org trail is the durable audit record. Protected B's
# actual requirement is 2-year retention; deliberately under-retained to minimize cost for
# this PoC (see plan.md "Honest Residual Risks"). Production: >= 2 years.

resource "aws_cloudwatch_log_group" "cloudtrail" {
  #checkov:skip=CKV_AWS_338:30-day retention for portfolio POC; Protected B 2-year requirement documented as a cost residual in plan.md
  name              = "/aws/cloudtrail/${local.name_prefix}"
  retention_in_days = 30
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
  #checkov:skip=CKV_AWS_35:Log files are SSE-S3 encrypted at the bucket; the durable org trail uses a dedicated CMK — a CMK here would add cloudtrail grants to the shared key for an ephemeral trail
  #checkov:skip=CKV_AWS_252:No per-log-file SNS delivery notifications — alerting flows through the EventBridge rules and the metric-filter alarms on this trail's events
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

# ── EventBridge rules 1, 5, 7, 9 → SNS (regional services) ──────────────────
# EventBridge publishes to SNS via the SNS resource policy (aws_sns_topic_policy
# in main.tf). No IAM role_arn is needed on SNS targets.
# Rules 2/3/4 are NOT here: their events are global-service (us-east-1 bus only)
# and live as CIS metric-filter alarms further down (ADR-0014).

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
# Zero-standing-baseline signal: no automated, always-on principal holds
# secretsmanager:GetSecretValue (no Lambda role has it; the only secret is the
# RDS-managed master password). Every GetSecretValue event therefore resolves to one
# of: (a) RDS-managed rotation (rds.amazonaws.com), (b) a deliberate operator
# maintenance action -- db-init on every bring-up (ADR-0008) or the cloud-exit export,
# both run with the operator's own credentials -- or (c) a compromise. The rule fires
# on all three (expected-but-logged); see runbook section "Expected alerts on first apply".
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
# Watches suppression-class operations only, across BOTH detection transports:
# EventBridge rules (DeleteRule/DisableRule/RemoveTargets) and the CIS metric-filter
# alarms (DeleteMetricFilter/DeleteAlarms/DisableAlarmActions — rules 2/3/4/6 live
# there, ADR-0014). PutRule/PutMetricFilter are excluded: every loonvault-apply fires
# them on managed resources, producing false positives. No source filter: matching on
# eventSource alone avoids guessing each service's EventBridge source name. Residual:
# rule 9 cannot detect its own deletion (self-referential problem — see T-038).
resource "aws_cloudwatch_event_rule" "detection_tampering" {
  name        = "${local.name_prefix}-detection-tampering"
  description = "Rule 9: detection rule, metric filter, or alarm deleted or disabled (G-05)"
  event_pattern = jsonencode({
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["events.amazonaws.com", "logs.amazonaws.com", "monitoring.amazonaws.com"]
      eventName = [
        "DeleteRule", "DisableRule", "RemoveTargets",
        "DeleteMetricFilter", "DeleteAlarms", "DisableAlarmActions",
      ]
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

# ── Rules 2–4: global-service detections as CIS metric-filter alarms ─────────
# These events (console sign-in, IAM, root) are global-service: EventBridge only
# delivers them to the us-east-1 bus, which the region-lock SCP (ADR-0009) puts
# off-limits. The multi-region trail already lands them in this log group, so
# they use the CIS AWS Foundations Benchmark metric-filter patterns VERBATIM —
# Security Hub's CloudWatch.1/.3/.4 controls fail if any term is added or
# removed, so do not "improve" the patterns. Alert latency ~5-10 min (trail →
# CW Logs delivery + alarm evaluation); accepted trade-off per ADR-0014.

# Rule 2: Console sign-in without MFA (B-13: Identity & access management)
# CIS 4.2 / Security Hub CloudWatch.3. EXPECTED ALERT: IAM Identity Center
# sign-ins record MFAUsed="No" on the ConsoleLogin event (MFA happens at the
# IdP, invisible here), so every SSO console login fires this — same
# expected-but-logged posture as rule 8. See runbook "Expected alerts".
resource "aws_cloudwatch_log_metric_filter" "no_mfa_signin" {
  name           = "${local.name_prefix}-no-mfa-signin"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name
  pattern        = "{($.eventName=\"ConsoleLogin\") && ($.additionalEventData.MFAUsed !=\"Yes\")}"

  metric_transformation {
    name          = "NoMfaSigninCount"
    namespace     = "LoonVault/Security"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "no_mfa_signin" {
  alarm_name          = "${local.name_prefix}-no-mfa-signin"
  alarm_description   = "Rule 2: Console sign-in without MFA (CIS 4.2; SSO logins expected — see runbook)"
  namespace           = "LoonVault/Security"
  metric_name         = "NoMfaSigninCount"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# Rule 3: Root account used (B-13: Identity & access management)
# CIS 4.3 / Security Hub CloudWatch.1. Better than the old EventBridge pattern:
# invokedBy/AwsServiceEvent exclusions suppress AWS-service-initiated root noise.
resource "aws_cloudwatch_log_metric_filter" "root_usage" {
  name           = "${local.name_prefix}-root-usage"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name
  pattern        = "{$.userIdentity.type=\"Root\" && $.userIdentity.invokedBy NOT EXISTS && $.eventType !=\"AwsServiceEvent\"}"

  metric_transformation {
    name          = "RootUsageCount"
    namespace     = "LoonVault/Security"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "root_usage" {
  alarm_name          = "${local.name_prefix}-root-usage"
  alarm_description   = "Rule 3: Root account activity — root should never be used day-to-day (CIS 4.3)"
  namespace           = "LoonVault/Security"
  metric_name         = "RootUsageCount"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# Rule 4: IAM policy changed (B-13: Identity & access management)
# CIS 4.4 / Security Hub CloudWatch.4 — the full 16-event CIS list (the old
# EventBridge rule was missing DeletePolicy and DeletePolicyVersion).
resource "aws_cloudwatch_log_metric_filter" "iam_policy_change" {
  name           = "${local.name_prefix}-iam-policy-change"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name
  pattern        = "{($.eventName=DeleteGroupPolicy)||($.eventName=DeleteRolePolicy)||($.eventName=DeleteUserPolicy)||($.eventName=PutGroupPolicy)||($.eventName=PutRolePolicy)||($.eventName=PutUserPolicy)||($.eventName=CreatePolicy)||($.eventName=DeletePolicy)||($.eventName=CreatePolicyVersion)||($.eventName=DeletePolicyVersion)||($.eventName=AttachRolePolicy)||($.eventName=DetachRolePolicy)||($.eventName=AttachUserPolicy)||($.eventName=DetachUserPolicy)||($.eventName=AttachGroupPolicy)||($.eventName=DetachGroupPolicy)}"

  metric_transformation {
    name          = "IamPolicyChangeCount"
    namespace     = "LoonVault/Security"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "iam_policy_change" {
  alarm_name          = "${local.name_prefix}-iam-policy-change"
  alarm_description   = "Rule 4: IAM policy created, changed, attached, or deleted (CIS 4.4)"
  namespace           = "LoonVault/Security"
  metric_name         = "IamPolicyChangeCount"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}
