# ── Shared assume-role policy helper ─────────────────────────────────────────
locals {
  lambda_assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# ── Authorizer Lambda ─────────────────────────────────────────────────────────
# Not in VPC — reads SSM only; does not touch RDS or Secrets Manager
resource "aws_iam_role" "authorizer" {
  name               = "${local.name_prefix}-authorizer"
  assume_role_policy = local.lambda_assume_role_policy
}

resource "aws_iam_role_policy" "authorizer" {
  name = "authorizer-policy"
  role = aws_iam_role.authorizer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Logs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${local.name_prefix}-authorizer:*"
      },
      {
        Sid      = "ReadOriginSecret"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:${local.region}:${local.account_id}:parameter${var.origin_secret_ssm_path}"
      },
      {
        Sid      = "DecryptOriginSecret"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = aws_kms_key.main.arn
        Condition = {
          StringEquals = { "kms:ViaService" = "ssm.${local.region}.amazonaws.com" }
        }
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "authorizer_xray" {
  role       = aws_iam_role.authorizer.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

# ── Ingest Lambda ─────────────────────────────────────────────────────────────
# Not in VPC — reaches BoC Valet API (internet) and S3 (public endpoint)
resource "aws_iam_role" "ingest" {
  name               = "${local.name_prefix}-ingest"
  assume_role_policy = local.lambda_assume_role_policy
}

resource "aws_iam_role_policy" "ingest" {
  name = "ingest-policy"
  role = aws_iam_role.ingest.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Logs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${local.name_prefix}-ingest:*"
      },
      {
        Sid      = "WriteRawZone"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.raw.arn}/raw/*"
      },
      {
        Sid      = "EncryptRawObjects"
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = aws_kms_key.main.arn
        Condition = {
          StringEquals = { "kms:ViaService" = "s3.${local.region}.amazonaws.com" }
        }
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ingest_xray" {
  role       = aws_iam_role.ingest.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

# ── Transform Lambda ──────────────────────────────────────────────────────────
# In VPC — reads S3 raw zone, writes RDS, writes S3 snapshots (SSE-S3, no CMK needed)
resource "aws_iam_role" "transform" {
  name               = "${local.name_prefix}-transform"
  assume_role_policy = local.lambda_assume_role_policy
}

resource "aws_iam_role_policy_attachment" "transform_xray" {
  role       = aws_iam_role.transform.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

resource "aws_iam_role_policy_attachment" "transform_vpc" {
  role       = aws_iam_role.transform.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "transform" {
  name = "transform-policy"
  role = aws_iam_role.transform.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Logs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${local.name_prefix}-transform:*"
      },
      {
        Sid      = "ReadRawZone"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.raw.arn}/raw/*"
      },
      {
        Sid      = "DecryptRawObjects"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.main.arn
        Condition = {
          StringEquals = { "kms:ViaService" = "s3.${local.region}.amazonaws.com" }
        }
      },
      {
        Sid      = "WriteSnapshots"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.snapshots.arn}/snapshots/*"
      },
      {
        # IAM database authentication — connect as lv_writer; token signed locally (ADR-0006)
        Sid      = "ConnectAsWriter"
        Effect   = "Allow"
        Action   = ["rds-db:connect"]
        Resource = "arn:aws:rds-db:${local.region}:${local.account_id}:dbuser:${aws_db_instance.main.resource_id}/lv_writer"
      },
      {
        Sid    = "ConsumeSQS"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
        ]
        Resource = aws_sqs_queue.transform.arn
      },
      {
        Sid      = "DecryptSQS"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.main.arn
        Condition = {
          StringEquals = { "kms:ViaService" = "sqs.${local.region}.amazonaws.com" }
        }
      },
    ]
  })
}

# ── Read Lambda ───────────────────────────────────────────────────────────────
# In VPC — queries RDS only
resource "aws_iam_role" "read" {
  name               = "${local.name_prefix}-read"
  assume_role_policy = local.lambda_assume_role_policy
}

resource "aws_iam_role_policy_attachment" "read_xray" {
  role       = aws_iam_role.read.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

resource "aws_iam_role_policy_attachment" "read_vpc" {
  role       = aws_iam_role.read.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "read" {
  name = "read-policy"
  role = aws_iam_role.read.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Logs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${local.name_prefix}-read:*"
      },
      {
        # IAM database authentication — connect as lv_reader; token signed locally (ADR-0006)
        Sid      = "ConnectAsReader"
        Effect   = "Allow"
        Action   = ["rds-db:connect"]
        Resource = "arn:aws:rds-db:${local.region}:${local.account_id}:dbuser:${aws_db_instance.main.resource_id}/lv_reader"
      },
    ]
  })
}
