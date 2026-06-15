# ── S3 snapshots bucket ───────────────────────────────────────────────────────
# Public read for Cloudflare fallback (ADR-0004). SSE-S3 — not CMK — because
# public HTTP requests have no IAM identity to decrypt SSE-KMS objects.
#
# Written by the Transform Lambda in the ../loonvault stack (identity-based
# s3:PutObject; same account, so no bucket-policy grant is needed for writes).
# The bucket name is deterministic so the backend stack can reference it without
# a remote-state lookup.
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
