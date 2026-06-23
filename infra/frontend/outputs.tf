output "snapshots_bucket" {
  description = "S3 snapshots bucket name — public read, frontend fallback"
  value       = aws_s3_bucket.snapshots.id
}

output "snapshots_bucket_domain" {
  description = "S3 snapshots bucket regional domain name — for Cloudflare CNAME"
  value       = aws_s3_bucket.snapshots.bucket_regional_domain_name
}

output "site_bucket" {
  description = "Private static site bucket name — deploy target for `just deploy-frontend`"
  value       = aws_s3_bucket.site.id
}

output "site_function_url" {
  description = "Origin-protected site Lambda Function URL — point Cloudflare at this (ADR-0013)"
  value       = aws_lambda_function_url.site.function_url
}
