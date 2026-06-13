# ── S3 raw zone ───────────────────────────────────────────────────────────────
resource "aws_s3_bucket" "raw" {
  #checkov:skip=CKV_AWS_144:Cross-region replication not required for ephemeral portfolio POC
  #checkov:skip=CKV2_AWS_62:S3 event notifications handled via SQS below, not EventBridge
  #checkov:skip=CKV_AWS_18:S3 access logging adds storage cost; not required for ephemeral portfolio POC
  #checkov:skip=CKV2_AWS_61:Lifecycle policy not required for ephemeral portfolio POC
  bucket = "${local.name_prefix}-raw-${local.account_id}"
}

resource "aws_s3_bucket_versioning" "raw" {
  bucket = aws_s3_bucket.raw.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "raw" {
  bucket = aws_s3_bucket.raw.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.main.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "raw" {
  bucket                  = aws_s3_bucket.raw.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_notification" "raw" {
  bucket = aws_s3_bucket.raw.id

  queue {
    queue_arn     = aws_sqs_queue.transform.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "raw/"
    filter_suffix = ".json"
  }

  depends_on = [aws_sqs_queue_policy.transform]
}

# ── S3 snapshots bucket ───────────────────────────────────────────────────────
# Public read for Cloudflare fallback (ADR-0004). SSE-S3 — not CMK — because
# public HTTP requests have no IAM identity to decrypt SSE-KMS objects.
resource "aws_s3_bucket" "snapshots" {
  #checkov:skip=CKV_AWS_144:Cross-region replication not required for ephemeral portfolio POC
  #checkov:skip=CKV2_AWS_62:No event notifications on snapshots bucket
  #checkov:skip=CKV_AWS_18:S3 access logging adds storage cost; not required for ephemeral portfolio POC
  #checkov:skip=CKV2_AWS_61:Lifecycle policy not required for ephemeral portfolio POC
  #checkov:skip=CKV_AWS_145:Snapshots bucket uses SSE-S3 intentionally — public reads cannot decrypt SSE-KMS (ADR-0005)
  #checkov:skip=CKV_AWS_21:Snapshots are regenerated on every ingest; versioning adds cost without benefit
  #checkov:skip=CKV2_AWS_6:Partial public access block is intentional — snapshots bucket serves public reads (ADR-0004)
  bucket = "${local.name_prefix}-snapshots-${local.account_id}"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "snapshots" {
  bucket = aws_s3_bucket.snapshots.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "snapshots" {
  #checkov:skip=CKV_AWS_54:block_public_policy intentionally false — snapshots are public by design (ADR-0004)
  #checkov:skip=CKV_AWS_56:restrict_public_buckets intentionally false — snapshots are public by design (ADR-0004)
  #checkov:skip=CKV2_AWS_6:Partial public access block is intentional — snapshots bucket serves public reads (ADR-0004)
  bucket                  = aws_s3_bucket.snapshots.id
  block_public_acls       = true
  block_public_policy     = false
  ignore_public_acls      = true
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "snapshots_public_read" {
  #checkov:skip=CKV_AWS_70:Principal * is intentional — snapshots bucket is public by design (ADR-0004)
  bucket = aws_s3_bucket.snapshots.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicGetObject"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.snapshots.arn}/snapshots/*"
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.snapshots]
}

# ── SQS transform queue + DLQ ─────────────────────────────────────────────────
resource "aws_sqs_queue" "transform_dlq" {
  name              = "${local.name_prefix}-transform-dlq"
  kms_master_key_id = aws_kms_key.main.id

  tags = { Name = "${local.name_prefix}-transform-dlq" }
}

resource "aws_sqs_queue" "transform" {
  name                       = "${local.name_prefix}-transform"
  kms_master_key_id          = aws_kms_key.main.id
  visibility_timeout_seconds = 300

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.transform_dlq.arn
    maxReceiveCount     = 3
  })

  tags = { Name = "${local.name_prefix}-transform" }
}

# Allow S3 to publish notifications to SQS
resource "aws_sqs_queue_policy" "transform" {
  queue_url = aws_sqs_queue.transform.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowS3Publish"
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.transform.arn
      Condition = {
        ArnLike = { "aws:SourceArn" = aws_s3_bucket.raw.arn }
      }
    }]
  })
}

# ── RDS PostgreSQL ────────────────────────────────────────────────────────────
resource "aws_db_subnet_group" "main" {
  name       = "${local.name_prefix}-rds"
  subnet_ids = [aws_subnet.rds_a.id, aws_subnet.rds_b.id]
}

resource "aws_db_parameter_group" "postgres" {
  name        = "${local.name_prefix}-pg17"
  family      = "postgres17"
  description = "LoonVault — pgaudit enabled (G-07)"

  parameter {
    name         = "shared_preload_libraries"
    value        = "pgaudit"
    apply_method = "pending-reboot" # static parameter — requires reboot to take effect
  }

  parameter {
    name  = "pgaudit.log"
    value = "ddl,role,write"
  }

  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }
}

resource "aws_db_instance" "main" {
  #checkov:skip=CKV_AWS_157:Multi-AZ not required for ephemeral portfolio POC; single-AZ is intentional
  #checkov:skip=CKV_AWS_118:Enhanced monitoring adds cost; not required for ephemeral portfolio POC
  #checkov:skip=CKV_AWS_293:Deletion protection intentionally disabled — stack is ephemeral (terraform destroy after interviews)
  #checkov:skip=CKV_AWS_353:Performance Insights adds cost; not required for ephemeral portfolio POC
  identifier     = local.name_prefix
  engine         = "postgres"
  engine_version = "17"
  instance_class = "db.t4g.micro"
  db_name        = var.db_name
  username       = var.db_master_username

  # RDS manages the master password — Terraform never sees the plaintext value
  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.main.arn

  # Application users (lv_reader/lv_writer) authenticate with short-lived IAM tokens —
  # no stored DB credential, no Secrets Manager call on the data path (ADR-0006)
  iam_database_authentication_enabled = true

  # Storage
  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true
  kms_key_id        = aws_kms_key.main.arn

  # Networking
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  # Parameter group with pgaudit (G-07)
  parameter_group_name = aws_db_parameter_group.postgres.name

  # Backups
  backup_retention_period    = 7
  backup_window              = "04:00-05:00"
  maintenance_window         = "Mon:05:00-Mon:06:00"
  deletion_protection        = false
  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true

  # Monitoring
  enabled_cloudwatch_logs_exports = ["postgresql"]

  skip_final_snapshot = true

  tags = { Name = "${local.name_prefix}-rds" }
}

# Application DB users authenticate via RDS IAM auth (ADR-0006) — there is no stored
# application DB credential. The only Secrets Manager secret in the stack is the RDS
# master password, auto-created and managed by RDS (manage_master_user_password above)
# and never read by the Lambdas.

# ── SSM SecureString — X-Origin-Secret (G-01) ─────────────────────────────────
# Lambda authorizer reads this to validate the Cloudflare origin token.
# Value must be set by the operator (not stored in Terraform or state).
resource "aws_ssm_parameter" "origin_secret" {
  #checkov:skip=CKV_AWS_337:KMS key is the shared CMK (ADR-0005); documented tradeoff
  name   = var.origin_secret_ssm_path
  type   = "SecureString"
  value  = "PLACEHOLDER_SET_BY_OPERATOR"
  key_id = aws_kms_key.main.arn

  lifecycle {
    ignore_changes = [value]
  }
}
