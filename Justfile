set shell := ["bash", "-euo", "pipefail", "-c"]

_default:
    @just --list

# First-time setup: create S3 state bucket + DynamoDB lock (run once, outside devcontainer)
# Temporarily moves backend.tf aside so terraform apply uses local state (S3 bucket doesn't exist yet).
# bootstrap-migrate then moves that local state into S3 and restores the remote backend.
bootstrap:
    #!/usr/bin/env bash
    set -euo pipefail
    cd infra/bootstrap
    rm -rf .terraform
    mv backend.tf backend.tf.disabled
    trap 'mv -f backend.tf.disabled backend.tf 2>/dev/null || true' EXIT
    terraform init
    terraform apply

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

# Regenerate hash-pinned lockfiles (requirements.lock) for the three Lambdas.
# Run on the host (needs PyPI access + pip-tools); commit the generated .lock files.
# Re-run whenever a requirements.txt changes. Use Python 3.13 to match the Lambda runtime.
lock-deps:
    #!/usr/bin/env bash
    set -euo pipefail
    command -v pip-compile >/dev/null 2>&1 || { echo "pip-compile not found — run 'pip install pip-tools'"; exit 1; }
    for fn in ingest transform read; do
      echo "Locking $fn..."
      pip-compile --generate-hashes --allow-unsafe --quiet \
        --output-file "lambdas/$fn/requirements.lock" \
        "lambdas/$fn/requirements.txt"
    done
    echo "Generated lambdas/*/requirements.lock — review and commit them."

# Build Lambda deployment packages + RDS CA layer (run before loonvault-plan/apply)
# Bundles deps into per-Lambda package/ dirs using Lambda-compatible (manylinux x86_64) wheels.
loonvault-build:
    #!/usr/bin/env bash
    set -euo pipefail
    for fn in ingest transform read; do
      echo "Building $fn..."
      rm -rf "lambdas/$fn/package"
      mkdir -p "lambdas/$fn/package"
      lock="lambdas/$fn/requirements.lock"
      [ -f "$lock" ] || { echo "Missing $lock — run 'just lock-deps' first (needs PyPI access)"; exit 1; }
      pip install --require-hashes -r "$lock" -t "lambdas/$fn/package" \
        --platform manylinux2014_x86_64 --python-version 3.13 --only-binary=:all:
      cp "lambdas/$fn/handler.py" "lambdas/$fn/package/"
    done
    echo "Downloading RDS ca-central-1 CA bundle..."
    mkdir -p lambdas/layers/rds-ca
    curl -fsSL https://truststore.pki.rds.amazonaws.com/ca-central-1/ca-central-1-bundle.pem \
      -o lambdas/layers/rds-ca/rds-ca-bundle.pem

# Plan loonvault stack — outside devcontainer
loonvault-plan:
    terraform fmt -recursive -check infra/
    cd infra/loonvault && terraform validate && terraform plan -var-file=terraform.tfvars

# Apply loonvault stack — outside devcontainer (ephemeral: apply before interviews, destroy after)
# Post-apply steps (origin secret + db-init) are required — see docs/runbook.md
loonvault-apply:
    terraform fmt -recursive -check infra/
    cd infra/loonvault && terraform validate && terraform apply -var-file=terraform.tfvars

# Destroy loonvault stack — keeps bootstrap + frontend resources (outside devcontainer)
loonvault-destroy:
    cd infra/loonvault && terraform destroy -var-file=terraform.tfvars

# ── Frontend stack (ALWAYS-ON — snapshots bucket, survives loonvault-destroy) ──
# Requires infra/frontend/backend.hcl — copy from backend.hcl.example and fill in account ID
frontend-init:
    cd infra/frontend && terraform init -backend-config=backend.hcl

frontend-plan:
    terraform fmt -recursive -check infra/
    cd infra/frontend && terraform validate && terraform plan

frontend-apply:
    terraform fmt -recursive -check infra/
    cd infra/frontend && terraform validate && terraform apply

# Initialise loonvault Postgres schema (run once after loonvault-apply)
# Requires RDS connectivity — run from a host with VPC access or via bastion
loonvault-db-init RDS_ENDPOINT DB_NAME="loonvault" DB_USER="loonvault_admin":
    psql "host={{ RDS_ENDPOINT }} dbname={{ DB_NAME }} user={{ DB_USER }} sslmode=verify-full" \
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
