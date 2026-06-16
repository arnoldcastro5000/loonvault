# ── Admin access path for db-init (EICE + minimal bastion) ────────────────────
# The VPC is fully private (no IGW/NAT) and RDS is not publicly accessible, so the
# operator's laptop has no direct path to Postgres. db-init.sql must run as the RDS
# *master* user (to create the lv_reader/lv_writer roles + grant rds_iam), so we stand
# up an EC2 Instance Connect Endpoint (EICE) plus a minimal throwaway EC2. The operator
# opens an IAM-authenticated, CloudTrail-logged SSH tunnel through EICE and SSH-forwards
# localhost:5432 to RDS — the database never becomes publicly accessible. All of this is
# ephemeral: created with the backend, destroyed by `just loonvault-destroy`. See ADR-0008.

# Latest Amazon Linux 2023 (arm64, for t4g) — resolved via EC2 DescribeImages.
# (Avoids the /aws/ public SSM parameter namespace, which is access-restricted here.)
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-arm64"]
  }
  filter {
    name   = "architecture"
    values = ["arm64"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

# SG for the EICE — egress to the bastion's SSH only.
resource "aws_security_group" "eice" {
  name        = "${local.name_prefix}-eice"
  description = "EC2 Instance Connect Endpoint - egress to admin bastion SSH only"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name_prefix}-eice" }
}

resource "aws_security_group_rule" "eice_to_bastion" {
  type                     = "egress"
  from_port                = 22
  to_port                  = 22
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eice.id
  source_security_group_id = aws_security_group.admin.id
  description              = "EICE to admin bastion SSH"
}

# SG for the bastion — SSH in from EICE only, Postgres out to RDS only. No internet egress.
resource "aws_security_group" "admin" {
  name        = "${local.name_prefix}-admin"
  description = "db-init bastion - SSH in from EICE, Postgres out to RDS"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name_prefix}-admin" }
}

resource "aws_security_group_rule" "admin_ssh_from_eice" {
  type                     = "ingress"
  from_port                = 22
  to_port                  = 22
  protocol                 = "tcp"
  security_group_id        = aws_security_group.admin.id
  source_security_group_id = aws_security_group.eice.id
  description              = "SSH from EICE only"
}

resource "aws_security_group_rule" "admin_to_rds" {
  type                     = "egress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.admin.id
  source_security_group_id = aws_security_group.rds.id
  description              = "Admin bastion to RDS Postgres"
}

# RDS ingress for the bastion (SG-to-SG, OPA-compliant — no CIDR).
resource "aws_security_group_rule" "rds_from_admin" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds.id
  source_security_group_id = aws_security_group.admin.id
  description              = "RDS ingress from admin bastion SG (db-init). SG-to-SG, no CIDR (OPA enforced)"
}

resource "aws_ec2_instance_connect_endpoint" "main" {
  subnet_id          = aws_subnet.lambda_a.id
  security_group_ids = [aws_security_group.eice.id]
  tags               = { Name = "${local.name_prefix}-eice" }
}

# Minimal throwaway bastion — a pure TCP relay for the SSH tunnel. No instance profile:
# it makes no AWS API calls (EICE auth is on the caller side), so it needs no IAM role.
resource "aws_instance" "admin" {
  #checkov:skip=CKV2_AWS_41:No instance profile — bastion is a TCP relay and makes no AWS API calls
  #checkov:skip=CKV_AWS_126:Detailed monitoring not needed for a throwaway db-init bastion
  #checkov:skip=CKV_AWS_135:EBS optimization not relevant for a t4g.nano relay
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t4g.nano"
  subnet_id                   = aws_subnet.lambda_a.id
  vpc_security_group_ids      = [aws_security_group.admin.id]
  associate_public_ip_address = false

  # IMDSv2 only
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = 8
  }

  tags = { Name = "${local.name_prefix}-admin" }
}
