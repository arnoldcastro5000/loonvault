# LoonVault deploy runbook

The backend is **ephemeral**: `apply` before an interview, `destroy` after. This is the full
lifecycle. All commands run from the developer's host terminal (never the devcontainer — it
holds no AWS credentials) with an active IAM Identity Center session.

## Prerequisites (one-time)

1. **State backend exists.** If you have never run it:
   ```bash
   just bootstrap          # creates the S3 state bucket + DynamoDB lock table
   just bootstrap-migrate   # moves bootstrap state into S3
   ```
2. **Backend config.** Copy and fill in your account ID:
   ```bash
   cp infra/loonvault/backend.hcl.example infra/loonvault/backend.hcl
   # edit: set bucket = loonvault-tfstate-<YOUR_ACCOUNT_ID>
   ```
3. **Variables.** Create `infra/loonvault/terraform.tfvars` with the one required variable:
   ```hcl
   alert_email = "you@example.com"
   ```
4. **Frontend stack (always-on).** Apply once and leave up — it holds the public snapshots
   bucket and survives every backend `destroy`:
   ```bash
   cp infra/frontend/backend.hcl.example infra/frontend/backend.hcl
   # edit: set bucket = loonvault-tfstate-<YOUR_ACCOUNT_ID>
   just frontend-init
   just frontend-apply
   ```

## Org guardrails — region-lock SCP (one-time, management account)

Run from the **management account** (`loonvault` profile), not the workloads account. This
attaches the `ca-central-1` region-lock SCP to a **Workloads OU** and moves the member account
into it (see ADR-0009; SCPs never restrict the management account, so the workloads must live in
a member account under the OU for the guardrail to bite).

```bash
just org-init
just org-apply                       # creates the Workloads OU + region-lock SCP, attaches at OU
# Grab the IDs the apply printed:
terraform -chdir=infra/org output -raw root_id           # source parent
terraform -chdir=infra/org output -raw workloads_ou_id   # destination parent
# Move the workloads account into the OU (one-time):
aws organizations move-account \
  --account-id 142083399482 \
  --source-parent-id "$(terraform -chdir=infra/org output -raw root_id)" \
  --destination-parent-id "$(terraform -chdir=infra/org output -raw workloads_ou_id)" \
  --profile loonvault
```

Verify the guardrail (Phase-0 gate) from the **workloads** account (`loonvault-prod` profile):

```bash
# Expect an explicit Deny outside ca-central-1:
aws ec2 describe-vpcs --region us-east-2 --profile loonvault-prod   # -> UnauthorizedOperation / explicit deny
# Control still works in-region:
aws ec2 describe-vpcs --region ca-central-1 --profile loonvault-prod  # -> succeeds
```

## Deploy

```bash
just loonvault-init      # terraform init with backend.hcl (one-time per clone)
just loonvault-build     # bundle Lambda deps + download RDS CA bundle into package/ dirs
just loonvault-plan      # review the plan — confirm resources + region (ca-central-1)
just loonvault-apply     # create the stack
```

> `loonvault-build` must run before `plan`/`apply`. The `ingest`, `transform`, and `read`
> Lambdas zip a pre-built `package/` directory (handler + dependencies installed with
> Lambda-compatible `manylinux2014_x86_64` wheels), and the RDS CA bundle is packaged as a
> layer mounted at `/opt/rds-ca-bundle.pem`. Re-run `build` whenever handler code or
> `requirements.txt` changes. The `authorizer` Lambda has no third-party deps and is zipped
> directly from its handler.
>
> **Hash-pinned deps.** `loonvault-build` installs with `pip install --require-hashes` from a
> committed `lambdas/<fn>/requirements.lock` — every direct *and* transitive dependency is
> pinned by SHA256, so pip verifies each downloaded wheel's hash and a tampered or substituted
> artifact fails the build. `requirements.txt` holds the human-edited direct deps;
> `requirements.lock` is generated from it. When you change a `requirements.txt`, regenerate
> the locks (needs PyPI access + `pip install pip-tools`, run with Python 3.13 to match the
> Lambda runtime) and commit them:
>
> ```bash
> just lock-deps     # writes lambdas/*/requirements.lock with --generate-hashes
> ```

## Post-apply (the stack is NOT functional until both steps run)

**1. Set the real X-Origin-Secret in SSM.** Terraform creates the SSM parameter with a
placeholder value (`PLACEHOLDER_SET_BY_OPERATOR`) and ignores changes to it, so you set the
real value out-of-band. It must match the secret the Cloudflare origin sends in the
`X-Origin-Secret` header.
```bash
aws ssm put-parameter \
  --name /loonvault/origin-secret \
  --type SecureString \
  --value "$(openssl rand -hex 32)" \
  --overwrite \
  --region ca-central-1
```

**2. Initialise the database.** Creates the Postgres roles, the IAM-auth users
(`lv_reader` / `lv_writer` — no passwords; they authenticate with RDS IAM tokens), the
schema, and seeds the `FXCADUSD` indicator row.

RDS is private (no IGW/NAT, not publicly accessible), so reach it through the EC2 Instance
Connect Endpoint (EICE) tunnel — RDS never goes public; the tunnel is IAM-authenticated and
CloudTrail-logged (ADR-0008). Needs the AWS CLI v2, an SSH client, `psql`, and `jq`.

```bash
# terminal 1 — open the tunnel (blocks; Ctrl-C when done)
just db-tunnel
# terminal 2 — run db-init through localhost:5432
just loonvault-db-init
```
> `loonvault-db-init` runs `scripts/db-init.sql` as the RDS **master** user (the only role
> that can create the lv_reader/lv_writer users + grant `rds_iam`). It fetches the
> RDS-managed master password from Secrets Manager. This is the **only** use of the master
> credential — application DB auth is RDS IAM (ADR-0006), so there is no app credential to
> populate. The EICE + bastion are ephemeral (destroyed by `loonvault-destroy`).

## Verify

```bash
terraform -chdir=infra/loonvault output api_endpoint
# curl the endpoint with the X-Origin-Secret header; expect FXCADUSD observations
```

## Destroy (after the interview)

```bash
just loonvault-destroy
```

`loonvault-destroy` tears down the **entire backend** — RDS (+ its managed master secret),
VPC, Lambdas, API Gateway, SQS, the `raw` bucket, the **EICE + db-init bastion**, and the
**`main` CMK** (which enters a pending-deletion window and is not billed). The always-on **`frontend` stack** (public
snapshots bucket) and the **bootstrap** state backend are separate stacks and are untouched —
the parked frontend keeps serving the last-written snapshots via Cloudflare. Re-running `apply`
recreates the backend; note that the RDS instance gets a **new resource ID**, so the
`rds-db:connect` IAM policy re-resolves automatically (expected plan change, not drift — see
ADR-0006).

## Cost reminder

Running 24/7 ≈ $34/mo (busts the <$10 budget). Realistic ephemeral use (a few hours around
interviews) ≈ $4/mo. The **parked baseline** that survives `loonvault-destroy` is only the
bootstrap **tfstate CMK (~$1/mo)** — the `main` CMK and the RDS master secret go away with the
backend, and the frontend snapshots bucket is ~$0. Always `destroy` when you're done.

## Break-glass: `main` branch protection

`main` is protected by the **`protect-main`** repository ruleset (enforcement `active`,
no bypass actors — it binds admins too). Every update to `main` must go through a PR with all
six CI checks green (`Terraform`, `SAST and secrets`, `Lint and workflow security`,
`Supply chain`, `Dependency review`, `Docs drift`). Direct pushes to `main` are rejected.

This is deliberate (it enforces Phase 0 story 33 — no change bypasses the static-scan gate),
but it creates one lockout scenario: **if CI itself wedges** — a pinned Action SHA gets
yanked, a scanner has an outage, or a check is renamed and no longer reports — then *no* PR
can satisfy the required checks, including the PR that fixes CI. Breaking glass temporarily
lifts enforcement so the fix can land, then restores it.

> Requires an **admin** token (the repo owner account). The `arnolds-assistant` collaborator
> has `WRITE` only and cannot change rulesets. Authenticate as the owner first:
> `gh auth switch -u <owner>` (or `gh auth login`).

```bash
REPO=arnoldcastro5000/loonvault

# 1. Find the ruleset id (don't hardcode it — it can change if recreated)
RULESET=$(gh api "/repos/$REPO/rulesets" --jq '.[] | select(.name=="protect-main") | .id')

# 2. Break glass — disable enforcement (dry-run mode; blocks nothing)
gh api --method PATCH "/repos/$REPO/rulesets/$RULESET" -f enforcement=disabled

# 3. Land the fix (PR-merge if possible; direct push to main only while disabled)

# 4. RESTORE immediately after — this is the whole point of "break-glass"
gh api --method PATCH "/repos/$REPO/rulesets/$RULESET" -f enforcement=active

# 5. Confirm it's back on
gh api "/repos/$REPO/rulesets/$RULESET" --jq '.enforcement'   # -> "active"
```

UI equivalent: **Settings → Rules → Rulesets → `protect-main` → Enforcement status** toggle
between `Active` and `Disabled`.

Every PATCH is recorded in the repo audit log, so the disable/restore window is auditable —
treat that as a feature, not a workaround. Keep the disabled window as short as possible and
re-enable in the same sitting; never leave `main` unprotected overnight.
