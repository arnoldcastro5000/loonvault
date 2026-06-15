output "snapshots_bucket" {
  description = "S3 snapshots bucket name — public read, frontend fallback"
  value       = aws_s3_bucket.snapshots.id
}

output "snapshots_bucket_domain" {
  description = "S3 snapshots bucket regional domain name — for Cloudflare CNAME"
  value       = aws_s3_bucket.snapshots.bucket_regional_domain_name
}
