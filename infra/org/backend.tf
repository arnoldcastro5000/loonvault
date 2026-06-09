# Partial backend configuration — sensitive values live in backend.hcl which is gitignored.
# Initialise with: terraform init -backend-config=backend.hcl
terraform {
  backend "s3" {}
}
