# ── Lambda packages ───────────────────────────────────────────────────────────
data "archive_file" "authorizer" {
  type        = "zip"
  source_file = "${path.module}/../../lambdas/authorizer/handler.py"
  output_path = "${path.module}/../../lambdas/authorizer/handler.zip"
}

data "archive_file" "ingest" {
  type        = "zip"
  source_file = "${path.module}/../../lambdas/ingest/handler.py"
  output_path = "${path.module}/../../lambdas/ingest/handler.zip"
}

data "archive_file" "transform" {
  type        = "zip"
  source_file = "${path.module}/../../lambdas/transform/handler.py"
  output_path = "${path.module}/../../lambdas/transform/handler.zip"
}

data "archive_file" "read" {
  type        = "zip"
  source_file = "${path.module}/../../lambdas/read/handler.py"
  output_path = "${path.module}/../../lambdas/read/handler.zip"
}

# ── CloudWatch log groups (pre-created so retention is managed by Terraform) ──
resource "aws_cloudwatch_log_group" "authorizer" {
  #checkov:skip=CKV_AWS_338:30-day retention for portfolio POC
  name              = "/aws/lambda/${local.name_prefix}-authorizer"
  retention_in_days = 30
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_cloudwatch_log_group" "ingest" {
  #checkov:skip=CKV_AWS_338:30-day retention for portfolio POC
  name              = "/aws/lambda/${local.name_prefix}-ingest"
  retention_in_days = 30
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_cloudwatch_log_group" "transform" {
  #checkov:skip=CKV_AWS_338:30-day retention for portfolio POC
  name              = "/aws/lambda/${local.name_prefix}-transform"
  retention_in_days = 30
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_cloudwatch_log_group" "read" {
  #checkov:skip=CKV_AWS_338:30-day retention for portfolio POC
  name              = "/aws/lambda/${local.name_prefix}-read"
  retention_in_days = 30
  kms_key_id        = aws_kms_key.main.arn
}

# ── Authorizer Lambda ─────────────────────────────────────────────────────────
resource "aws_lambda_function" "authorizer" {
  #checkov:skip=CKV_AWS_272:Code signing out of scope for portfolio POC
  #checkov:skip=CKV_AWS_117:Authorizer intentionally not in VPC — must reach SSM via internet; no VPC endpoint for SSM provisioned
  #checkov:skip=CKV_AWS_116:Authorizer is synchronous (API GW); DLQ not applicable to sync invocations
  #checkov:skip=CKV_AWS_173:Env vars contain only config paths, not secrets; secrets live in SSM SecureString
  function_name = "${local.name_prefix}-authorizer"
  role          = aws_iam_role.authorizer.arn
  runtime       = "python3.13"
  handler       = "handler.handler"
  timeout       = 10
  memory_size   = 128

  # Reserved concurrency — no flood of auth checks (G-02)
  reserved_concurrent_executions = 10

  tracing_config {
    mode = "Active"
  }

  filename         = data.archive_file.authorizer.output_path
  source_code_hash = data.archive_file.authorizer.output_base64sha256

  environment {
    variables = {
      ORIGIN_SECRET_SSM_PATH = var.origin_secret_ssm_path
    }
  }

  depends_on = [aws_cloudwatch_log_group.authorizer]
}

# ── Ingest Lambda ─────────────────────────────────────────────────────────────
resource "aws_lambda_function" "ingest" {
  #checkov:skip=CKV_AWS_272:Code signing out of scope for portfolio POC
  #checkov:skip=CKV_AWS_117:Ingest intentionally not in VPC — must reach BoC Valet API on internet
  #checkov:skip=CKV_AWS_116:Ingest is scheduled (EventBridge); async failures surface via CloudWatch alarm on DLQ
  #checkov:skip=CKV_AWS_173:Env vars contain only bucket name and series codes, not secrets
  function_name = "${local.name_prefix}-ingest"
  role          = aws_iam_role.ingest.arn
  runtime       = "python3.13"
  handler       = "handler.handler"
  timeout       = 60
  memory_size   = 256

  reserved_concurrent_executions = 5

  tracing_config {
    mode = "Active"
  }

  filename         = data.archive_file.ingest.output_path
  source_code_hash = data.archive_file.ingest.output_base64sha256

  environment {
    variables = {
      RAW_BUCKET   = aws_s3_bucket.raw.id
      SERIES_CODES = "FXCADUSD"
    }
  }

  depends_on = [aws_cloudwatch_log_group.ingest]
}

# Daily ingest schedule — 06:00 UTC (after BoC publishes previous-day data)
resource "aws_cloudwatch_event_rule" "ingest_daily" {
  name                = "${local.name_prefix}-ingest-daily"
  schedule_expression = "cron(0 6 * * ? *)"
}

resource "aws_cloudwatch_event_target" "ingest_daily" {
  rule = aws_cloudwatch_event_rule.ingest_daily.name
  arn  = aws_lambda_function.ingest.arn
}

resource "aws_lambda_permission" "ingest_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ingest.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.ingest_daily.arn
}

# ── Transform Lambda ──────────────────────────────────────────────────────────
resource "aws_lambda_function" "transform" {
  #checkov:skip=CKV_AWS_272:Code signing out of scope for portfolio POC
  #checkov:skip=CKV_AWS_116:Transform uses SQS with DLQ (aws_sqs_queue.transform_dlq) — Lambda DLQ is redundant
  #checkov:skip=CKV_AWS_173:Env vars contain only DB host/name and secret ARN, not secret values
  function_name = "${local.name_prefix}-transform"
  role          = aws_iam_role.transform.arn
  runtime       = "python3.13"
  handler       = "handler.handler"
  timeout       = 300
  memory_size   = 512

  reserved_concurrent_executions = 5

  tracing_config {
    mode = "Active"
  }

  filename         = data.archive_file.transform.output_path
  source_code_hash = data.archive_file.transform.output_base64sha256

  vpc_config {
    subnet_ids         = [aws_subnet.lambda_a.id, aws_subnet.lambda_b.id]
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      DB_HOST            = aws_db_instance.main.address
      DB_NAME            = var.db_name
      DB_CREDENTIALS_ARN = aws_secretsmanager_secret.db_credentials.arn
      SNAPSHOTS_BUCKET   = aws_s3_bucket.snapshots.id
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.transform,
    aws_iam_role_policy_attachment.transform_vpc,
  ]
}

# SQS event source mapping — Lambda service polls SQS; no NAT required
resource "aws_lambda_event_source_mapping" "transform_sqs" {
  event_source_arn = aws_sqs_queue.transform.arn
  function_name    = aws_lambda_function.transform.arn
  batch_size       = 1
  enabled          = true

  function_response_types = ["ReportBatchItemFailures"]
}

# ── Read Lambda ───────────────────────────────────────────────────────────────
resource "aws_lambda_function" "read" {
  #checkov:skip=CKV_AWS_272:Code signing out of scope for portfolio POC
  #checkov:skip=CKV_AWS_116:Read is synchronous (API GW); DLQ not applicable to sync invocations
  #checkov:skip=CKV_AWS_173:Env vars contain only DB host/name and secret ARN, not secret values
  function_name = "${local.name_prefix}-read"
  role          = aws_iam_role.read.arn
  runtime       = "python3.13"
  handler       = "handler.handler"
  timeout       = 30
  memory_size   = 256

  reserved_concurrent_executions = 20

  tracing_config {
    mode = "Active"
  }

  filename         = data.archive_file.read.output_path
  source_code_hash = data.archive_file.read.output_base64sha256

  vpc_config {
    subnet_ids         = [aws_subnet.lambda_a.id, aws_subnet.lambda_b.id]
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      DB_HOST            = aws_db_instance.main.address
      DB_NAME            = var.db_name
      DB_CREDENTIALS_ARN = aws_secretsmanager_secret.db_credentials.arn
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.read,
    aws_iam_role_policy_attachment.read_vpc,
  ]
}
