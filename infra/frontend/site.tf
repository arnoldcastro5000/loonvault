# ── Static site bucket ────────────────────────────────────────────────────────
# Always-on, public-read static frontend (the lean hand-written site in /frontend),
# served via Cloudflare in front of the S3 website endpoint. Public by design — the
# frontend is the project's public face. SSE-S3 (not CMK): public HTTP reads have no
# IAM identity to decrypt SSE-KMS. Deployed with `just deploy-frontend`.
#
# NOTE: the OPA storage policy would (correctly, by its rules) deny a public bucket;
# infra/frontend is intentionally excluded from the OPA plan-gate for exactly this
# reason (see policies/README.md "Scope").
resource "aws_s3_bucket" "site" {
  #checkov:skip=CKV_AWS_144:Cross-region replication not required for ephemeral portfolio POC
  #checkov:skip=CKV2_AWS_62:No event notifications on the static site bucket
  #checkov:skip=CKV_AWS_18:S3 access logging adds storage cost; not required for portfolio POC
  #checkov:skip=CKV2_AWS_61:Lifecycle policy not required for a static site
  #checkov:skip=CKV_AWS_145:Static site uses SSE-S3 intentionally — public reads cannot decrypt SSE-KMS
  #checkov:skip=CKV_AWS_21:Static site assets are redeployed wholesale; versioning adds cost without benefit
  #checkov:skip=CKV2_AWS_6:Partial public access block is intentional — the site bucket serves public reads
  bucket = "${local.name_prefix}-site-${local.account_id}"
}

resource "aws_s3_bucket_website_configuration" "site" {
  bucket = aws_s3_bucket.site.id
  index_document {
    suffix = "index.html"
  }
  error_document {
    key = "index.html"
  }
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
  #checkov:skip=CKV_AWS_54:block_public_policy intentionally false — the site is public by design
  #checkov:skip=CKV_AWS_56:restrict_public_buckets intentionally false — the site is public by design
  #checkov:skip=CKV2_AWS_6:Partial public access block is intentional — the site bucket serves public reads
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = true
  block_public_policy     = false
  ignore_public_acls      = true
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "site_public_read" {
  #checkov:skip=CKV_AWS_70:Principal * is intentional — the static site is public by design
  bucket = aws_s3_bucket.site.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicGetObject"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.site.arn}/*"
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.site]
}
