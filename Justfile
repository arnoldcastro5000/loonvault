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

# Apply the full infrastructure stack (outside devcontainer)
apply:
    terraform fmt -recursive -check infra/
    cd infra/main && terraform validate && terraform apply

# Destroy backend infrastructure — keeps bootstrap resources (outside devcontainer)
destroy:
    cd infra/main && terraform destroy

# Format all Terraform files in-place
fmt:
    terraform fmt -recursive infra/

# Run all static scans
scan:
    checkov -d infra/ --framework terraform
    semgrep --config p/python --config p/owasp-top-ten .

# Deploy frontend static site to S3 (outside devcontainer)
deploy-frontend:
    cd frontend && npm run build && aws s3 sync out/ s3://loonvault-frontend/
