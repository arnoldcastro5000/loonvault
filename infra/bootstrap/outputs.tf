output "state_bucket_name" {
  description = "S3 bucket name — use this in the backend block after migration"
  value       = aws_s3_bucket.tfstate.id
}

output "state_bucket_arn" {
  description = "S3 bucket ARN for Terraform remote state"
  value       = aws_s3_bucket.tfstate.arn
}

output "lock_table_name" {
  description = "DynamoDB table name — use this in the backend block after migration"
  value       = aws_dynamodb_table.tfstate_lock.name
}

output "tfstate_kms_key_arn" {
  description = "KMS CMK ARN for the state bucket — use this in the backend block after migration"
  value       = aws_kms_key.tfstate.arn
}
