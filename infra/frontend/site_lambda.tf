# ── Origin-protected static-site Lambda (ADR-0013) ────────────────────────────
# Serves the PRIVATE site bucket through a Function URL behind Cloudflare. Cloudflare
# injects X-Origin-Secret; the handler validates it (cached from SSM), reads the object
# via IAM, and returns it with strict security headers. No CloudFront (Cloudflare is
# the only CDN). No third-party deps — zip the single handler.

data "archive_file" "site" {
  type        = "zip"
  source_file = "${path.module}/../../lambdas/site/handler.py"
  output_path = "${path.module}/../../lambdas/site/handler.zip"
}

data "aws_iam_policy_document" "site_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# AWS-managed SSM key (the dedicated site origin secret is a SecureString under it).
data "aws_kms_alias" "ssm" {
  name = "alias/aws/ssm"
}

resource "aws_iam_role" "site" {
  name               = "${local.name_prefix}-site"
  assume_role_policy = data.aws_iam_policy_document.site_assume.json
}

resource "aws_iam_role_policy" "site" {
  name = "site-policy"
  role = aws_iam_role.site.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.region}:${local.account_id}:log-group:/aws/lambda/${local.name_prefix}-site:*"
      },
      {
        Sid      = "ReadSiteBucket"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.site.arn}/*"
      },
      {
        Sid      = "ReadOriginSecret"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:${var.region}:${local.account_id}:parameter${var.origin_secret_ssm_path}"
      },
      {
        Sid      = "DecryptOriginSecret"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = data.aws_kms_alias.ssm.target_key_arn
        Condition = {
          StringEquals = { "kms:ViaService" = "ssm.${var.region}.amazonaws.com" }
        }
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "site" {
  #checkov:skip=CKV_AWS_338:30-day retention for portfolio POC
  #checkov:skip=CKV_AWS_158:No CMK — the always-on frontend must not depend on the ephemeral backend CMK (ADR-0007); site access logs hold no sensitive data
  name              = "/aws/lambda/${local.name_prefix}-site"
  retention_in_days = 30
}

resource "aws_iam_role_policy_attachment" "site_xray" {
  role       = aws_iam_role.site.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

resource "aws_lambda_function" "site" {
  #checkov:skip=CKV_AWS_272:Code signing out of scope for portfolio POC
  #checkov:skip=CKV_AWS_117:Not in VPC — must reach S3 + SSM via internet; no VPC endpoints provisioned in the always-on stack
  #checkov:skip=CKV_AWS_116:Invoked synchronously via Function URL; DLQ not applicable
  #checkov:skip=CKV_AWS_173:Env vars are config (bucket name, SSM path, CSP) — the secret stays in SSM SecureString
  #checkov:skip=CKV_AWS_115:Reserved concurrency not set — Cloudflare caches; low invocation volume for a portfolio POC
  function_name = "${local.name_prefix}-site"
  role          = aws_iam_role.site.arn
  runtime       = "python3.13"
  handler       = "handler.handler"
  timeout       = 10
  memory_size   = 128

  tracing_config {
    mode = "Active"
  }

  filename         = data.archive_file.site.output_path
  source_code_hash = data.archive_file.site.output_base64sha256

  environment {
    variables = {
      SITE_BUCKET            = aws_s3_bucket.site.id
      ORIGIN_SECRET_SSM_PATH = var.origin_secret_ssm_path
      # script-src carries a per-request nonce (handler substitutes __NONCE__); Cloudflare
      # parses it from the response header to allow its injected JS-detection/bot script.
      CSP = "default-src 'self'; script-src 'self' 'nonce-__NONCE__'; img-src 'self' data:; connect-src 'self' ${var.api_origin} ${var.snapshot_origin}; object-src 'none'; base-uri 'none'; frame-ancestors 'none'"
    }
  }

  depends_on = [aws_cloudwatch_log_group.site]
}

resource "aws_lambda_function_url" "site" {
  #checkov:skip=CKV_AWS_258:AuthType NONE is intentional — access is gated by the X-Origin-Secret header (validated in-handler) injected by Cloudflare; the bucket itself is private (ADR-0013)
  function_name      = aws_lambda_function.site.function_name
  authorization_type = "NONE"
}

# Public access for a NONE Function URL requires TWO resource-based statements:
#   1. lambda:InvokeFunctionUrl — auto-created by aws_lambda_function_url above
#      (statement "FunctionURLAllowPublicAccess"), so it is NOT declared here.
#   2. lambda:InvokeFunction (invoked-via-function-url) — REQUIRED for function URLs since
#      October 2025 (AWS docs: lambda/latest/dg/urls-auth). Without it the URL returns AWS's
#      403 "Forbidden" *before* the handler runs, even with AuthType=NONE. The pinned aws
#      provider (5.100) predates the `invoked_via_function_url` argument, so this statement
#      is created OUT OF BAND via the runbook — the same pattern as the SSM origin secret.
#      See docs/runbook.md and ADR-0013. (Public invoke is safe: the gate is the in-handler
#      X-Origin-Secret check, and a direct invoke with no header returns 403.)
