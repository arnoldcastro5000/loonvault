output "snapshots_bucket" {
  description = "S3 snapshots bucket name — public read, frontend fallback"
  value       = aws_s3_bucket.snapshots.id
}

output "snapshots_bucket_domain" {
  description = "S3 snapshots bucket regional domain name — for Cloudflare CNAME"
  value       = aws_s3_bucket.snapshots.bucket_regional_domain_name
}

output "site_bucket" {
  description = "Static site bucket name — public read, deploy target for `just deploy-frontend`"
  value       = aws_s3_bucket.site.id
}

output "site_website_endpoint" {
  description = "S3 static website endpoint — put Cloudflare in front of this"
  value       = aws_s3_bucket_website_configuration.site.website_endpoint
}
