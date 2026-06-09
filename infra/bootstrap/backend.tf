# Partial backend configuration — sensitive values (bucket name containing account ID)
# live in backend.hcl which is gitignored.
#
# First-time bootstrap sequence:
#   1. terraform init -backend=false && terraform apply   (creates S3 bucket + DynamoDB)
#   2. Copy backend.hcl.example → backend.hcl, fill in your account ID
#   3. terraform init -migrate-state -backend-config=backend.hcl
#
terraform {
  backend "s3" {}
}
