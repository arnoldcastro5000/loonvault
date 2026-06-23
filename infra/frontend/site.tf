# ── Static site bucket (PRIVATE) ──────────────────────────────────────────────
# Always-on static frontend (the lean site in /frontend). PRIVATE — served via the
# origin-protected Lambda Function URL (site_lambda.tf), behind Cloudflare. Not
# public: only the site Lambda's role can read it. See ADR-0013 (and ADR-0012).
# SSE-S3 (not the backend CMK): the always-on frontend must not depend on the
# ephemeral backend's CMK, which is destroyed with the backend (ADR-0005/0007).
resource "aws_s3_bucket" "site" {
  #checkov:skip=CKV_AWS_144:Cross-region replication not required for ephemeral portfolio POC
  #checkov:skip=CKV2_AWS_62:No event notifications on the static site bucket
  #checkov:skip=CKV_AWS_18:S3 access logging adds storage cost; not required for portfolio POC
  #checkov:skip=CKV2_AWS_61:Lifecycle policy not required for a static site
  #checkov:skip=CKV_AWS_145:SSE-S3 by design — always-on frontend must not depend on the ephemeral backend CMK (ADR-0007)
  #checkov:skip=CKV_AWS_21:Static site assets are redeployed wholesale; versioning adds cost without benefit
  bucket = "${local.name_prefix}-site"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "site" {
  bucket = aws_s3_bucket.site.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
