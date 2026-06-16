output "api_endpoint" {
  description = "API Gateway v2 base URL — used by Cloudflare Worker"
  value       = aws_apigatewayv2_api.main.api_endpoint
}

output "raw_bucket" {
  description = "S3 raw zone bucket name"
  value       = aws_s3_bucket.raw.id
}

output "rds_endpoint" {
  description = "RDS Postgres endpoint — used in db-init.sql connection string"
  value       = aws_db_instance.main.address
  sensitive   = true
}

output "kms_key_arn" {
  description = "Shared CMK ARN (ADR-0005)"
  value       = aws_kms_key.main.arn
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "admin_instance_id" {
  description = "db-init bastion instance ID — target for the EICE SSH tunnel (see `just db-tunnel`)"
  value       = aws_instance.admin.id
}

output "master_secret_arn" {
  description = "ARN of the RDS-managed master user secret — fetched by db-init over the EICE tunnel"
  value       = aws_db_instance.main.master_user_secret[0].secret_arn
}
