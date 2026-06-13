set shell := ["bash", "-euo", "pipefail", "-c"]

_default:
    @just --list

# First-time setup: create S3 state bucket + DynamoDB lock (run once, outside devcontainer)
bootstrap:
    cd infra/bootstrap && terraform init -backend=false && terraform apply

# Migrate bootstrap local state into S3 (run once, after bootstrap)
# Requires infra/bootstrap/backend.hcl — copy from backend.hcl.example and fill in account ID
bootstrap-migrate:
    cd infra/bootstrap && terraform init -migrate-state -backend-config=backend.hcl

# Init org module with backend config (outside devcontainer, run once)
# Requires infra/org/backend.hcl — copy from backend.hcl.example and fill in account ID
org-init:
    cd infra/org && terraform init -backend-config=backend.hcl

# Plan org-level controls (SCP, etc.) — outside devcontainer
org-plan:
    terraform fmt -recursive -check infra/
    cd infra/org && terraform validate && terraform plan

# Apply org-level controls (SCP, etc.) — outside devcontainer
org-apply:
    terraform fmt -recursive -check infra/
    cd infra/org && terraform validate && terraform apply

# Init loonvault module with backend config (outside devcontainer, run once)
# Requires infra/loonvault/backend.hcl — copy from backend.hcl.example and fill in account ID
loonvault-init:
    cd infra/loonvault && terraform init -backend-config=backend.hcl

# Plan loonvault stack — outside devcontainer
loonvault-plan:
    terraform fmt -recursive -check infra/
    cd infra/loonvault && terraform validate && terraform plan -var-file=terraform.tfvars

# Apply loonvault stack — outside devcontainer (ephemeral: apply before interviews, destroy after)
loonvault-apply:
    terraform fmt -recursive -check infra/
    cd infra/loonvault && terraform validate && terraform apply -var-file=terraform.tfvars

# Destroy loonvault stack — keeps bootstrap resources (outside devcontainer)
loonvault-destroy:
    cd infra/loonvault && terraform destroy -var-file=terraform.tfvars

# Initialise loonvault Postgres schema (run once after loonvault-apply)
# Requires RDS connectivity — run from a host with VPC access or via bastion
loonvault-db-init RDS_ENDPOINT DB_NAME="loonvault" DB_USER="loonvault_admin":
    psql "host={{RDS_ENDPOINT}} dbname={{DB_NAME}} user={{DB_USER}} sslmode=verify-full" \
         -f scripts/db-init.sql

# Format all Terraform files in-place
fmt:
    terraform fmt -recursive infra/

# Run all static scans
scan:
    checkov -d infra/ --framework terraform
    semgrep --config p/python --config p/owasp-top-ten .

# Verify docs match built assets (runs locally and in CI)
verify-docs:
    bash scripts/verify-docs.sh

# Deploy frontend static site to S3 (outside devcontainer)
deploy-frontend:
    cd frontend && npm run build && aws s3 sync out/ s3://loonvault-frontend/
