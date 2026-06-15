# Partial backend configuration — sensitive values live in backend.hcl (gitignored).
#
# First-time setup sequence:
#   1. Copy backend.hcl.example → backend.hcl, fill in your account ID
#   2. terraform init -backend-config=backend.hcl
#
terraform {
  backend "s3" {}
}
