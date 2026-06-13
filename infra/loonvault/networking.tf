# ── VPC ───────────────────────────────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.name_prefix}-vpc" }
}

# ── Subnets ───────────────────────────────────────────────────────────────────
# Lambda private subnets — two AZs for resilience
resource "aws_subnet" "lambda_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = local.az_a

  tags = { Name = "${local.name_prefix}-lambda-${local.az_a}" }
}

resource "aws_subnet" "lambda_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = local.az_b

  tags = { Name = "${local.name_prefix}-lambda-${local.az_b}" }
}

# RDS subnet group requires subnets in ≥2 AZs even for single-AZ instance (T-028)
resource "aws_subnet" "rds_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.10.0/24"
  availability_zone = local.az_a

  tags = { Name = "${local.name_prefix}-rds-${local.az_a}" }
}

resource "aws_subnet" "rds_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.11.0/24"
  availability_zone = local.az_b

  tags = { Name = "${local.name_prefix}-rds-${local.az_b}" }
}

# ── Route tables (private — no IGW route) ─────────────────────────────────────
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name_prefix}-private" }
}

resource "aws_route_table_association" "lambda_a" {
  subnet_id      = aws_subnet.lambda_a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "lambda_b" {
  subnet_id      = aws_subnet.lambda_b.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "rds_a" {
  subnet_id      = aws_subnet.rds_a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "rds_b" {
  subnet_id      = aws_subnet.rds_b.id
  route_table_id = aws_route_table.private.id
}

# Lock down the default VPC security group — no ingress or egress (CKV2_AWS_12)
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id
}

# ── Security groups ───────────────────────────────────────────────────────────
# VPC endpoints SG — accepts HTTPS from Lambda SG
resource "aws_security_group" "vpc_endpoints" {
  name        = "${local.name_prefix}-vpc-endpoints"
  description = "Allow HTTPS from Lambda SG to interface VPC endpoints"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name_prefix}-vpc-endpoints" }
}

# Lambda SG — egress to RDS and VPC endpoints; no ingress
resource "aws_security_group" "lambda" {
  name        = "${local.name_prefix}-lambda"
  description = "LoonVault in-VPC Lambda functions"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name_prefix}-lambda" }
}

# RDS SG — SG-to-SG ingress only (OPA invariant: no CIDR blocks)
resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-rds"
  description = "LoonVault RDS Postgres — ingress from Lambda SG only"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name_prefix}-rds" }
}

# Rules defined as standalone resources to avoid cycles and satisfy OPA SG-to-SG policy
resource "aws_security_group_rule" "lambda_to_rds" {
  type                     = "egress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.lambda.id
  source_security_group_id = aws_security_group.rds.id
  description              = "Lambda to RDS Postgres"
}

resource "aws_security_group_rule" "lambda_to_endpoints" {
  type                     = "egress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.lambda.id
  source_security_group_id = aws_security_group.vpc_endpoints.id
  description              = "Lambda to VPC interface endpoints (Secrets Manager)"
}

resource "aws_security_group_rule" "rds_from_lambda" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds.id
  source_security_group_id = aws_security_group.lambda.id
  description              = "RDS ingress from Lambda SG only. SG-to-SG, no CIDR blocks (OPA enforced)"
}

resource "aws_security_group_rule" "endpoints_from_lambda" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.vpc_endpoints.id
  source_security_group_id = aws_security_group.lambda.id
  description              = "Interface endpoints ingress from Lambda SG"
}

# ── VPC endpoints ─────────────────────────────────────────────────────────────
# S3 gateway endpoint — free; allows Transform Lambda to reach S3 without internet
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${local.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "${local.name_prefix}-s3-gateway" }
}

# Secrets Manager interface endpoint — in-VPC Lambdas cannot reach Secrets Manager
# without NAT or this endpoint; ephemeral cost (~$0.01/AZ/hr, destroyed with stack)
resource "aws_vpc_endpoint" "secretsmanager" {
  #checkov:skip=CKV_AWS_123:Policy attached at IAM role level; endpoint policy would be redundant
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${local.region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = [aws_subnet.lambda_a.id, aws_subnet.lambda_b.id]
  security_group_ids  = [aws_security_group.vpc_endpoints.id]

  tags = { Name = "${local.name_prefix}-secretsmanager" }
}

# ── VPC Flow Logs ─────────────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "flow_logs" {
  #checkov:skip=CKV_AWS_338:30-day retention is sufficient for a portfolio POC; production would use 1 year
  name              = "/loonvault/vpc-flow-logs"
  retention_in_days = 30
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_iam_role" "flow_logs" {
  name = "${local.name_prefix}-flow-logs"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "flow_logs" {
  name = "flow-logs-delivery"
  role = aws_iam_role.flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
      ]
      Resource = "${aws_cloudwatch_log_group.flow_logs.arn}:*"
    }]
  })
}

resource "aws_flow_log" "main" {
  vpc_id          = aws_vpc.main.id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.flow_logs.arn
  log_destination = aws_cloudwatch_log_group.flow_logs.arn
}
