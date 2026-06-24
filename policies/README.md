# LoonVault policy-as-code (OPA-on-plan)

Compliance-annotated [Open Policy Agent](https://www.openpolicyagent.org/) policies that gate
Terraform changes **before deploy**, evaluated against `terraform show -json` plan output. This is
the pre-deploy / preventive layer of LoonVault's layered governance (region-lock SCP = org
guardrail; Prowler = post-deploy verification). Each rule is tagged with the OSFI B-13 principle and
GC Cloud Guardrail it enforces: the policies double as **compliance evidence** (compliance-as-code).

Structure follows AWS's pattern-based policy-as-code guidance: organised by control *intent*, not
by service:

```
policies/
├── shared/tfplan.rego          # plan-JSON helpers + the deny-message format
├── patterns/
│   ├── networking/             # exposure restriction: public admin ports, DB SG-to-SG
│   ├── storage/                # exposure restriction: S3 public access
│   └── baseline/               # allowed configuration: region lock
├── fixtures/                   # sample plan JSON (compliant / violating)
└── tests/  (co-located *_test.rego in each pattern dir)
```

## Input contract

Rules read a Terraform plan in JSON:

```bash
terraform plan -out=tfplan.bin
terraform show -json tfplan.bin > tfplan.json
```

Resources are taken from `.resource_changes[]` where `.change.actions` includes `create` or
`update` (deletes/no-ops/reads are ignored). The region rule reads
`.configuration.provider_config.aws.expressions.region.constant_value`.

## Run

```bash
# unit-test the policies (no AWS credentials needed)
conftest verify -p policies

# evaluate a plan (all pattern namespaces)
conftest test --all-namespaces -p policies tfplan.json

# lint the Rego
regal lint policies/
```

## Enforcement (where these run)

Layered, matching LoonVault's credential-free-CI stance:

- **CI (`lint` job)**: runs the **unit tests** (`conftest verify`) + `regal` + the compliance-matrix `--check`. No AWS creds, so it validates the *policies*, not a live plan. Pinned: `conftest 0.56.0`, `opa 1.17.0`, `regal 0.41.1`.
- **Pre-push hook** (`.githooks/pre-push`): on your terminal, where creds live: for a changed gated stack it runs `terraform plan` → `terraform show -json` → `conftest test`, blocking the push on a denial. Skips automatically in the devcontainer (`DEVCONTAINER=true`, no creds) and via `SKIP_POLICY_GATE=1` / `git push --no-verify`.
- **`just` recipes**: `just policy-test` (unit tests); `just loonvault-plan` / `just loonvault-apply` plan, run the conftest gate, and (apply) prompt before applying the reviewed plan.

**Scope:** the plan-gate currently covers the **`loonvault`** stack only. `infra/frontend` is excluded: its snapshots bucket is a deliberate public-read exception that the storage policy would deny; gating it needs a documented policy exception first.

**Install conftest on your terminal** (pinned to match CI):
```bash
curl -sSLo /tmp/conftest.tgz \
  "https://github.com/open-policy-agent/conftest/releases/download/v0.56.0/conftest_0.56.0_Linux_x86_64.tar.gz"
sudo tar xzf /tmp/conftest.tgz -C /usr/local/bin conftest
```

## Validation artifacts (audit evidence)

Every real-plan evaluation (the pre-push hook and `just loonvault-plan`/`-apply`, via
`scripts/policy-report.sh`) records a per-run artifact to **`policy-reports/`**: written on
both pass and fail. This is the per-deploy *result* evidence (complementing `COMPLIANCE.md`,
which is *coverage*). AWS's pattern-based policy-as-code guidance recommends retaining these so
results travel with the change record for audit instead of vanishing into logs.

`policy-reports/` is **git-ignored** (per-run records may contain plan detail). Each file is
`policy-reports/<stack>-<utc>-<gitsha>.json`:
```json
{
  "run":    { "timestamp": "...", "stack": "loonvault", "git_commit": "<sha>",
              "policy_version": "<git tree sha of policies/>", "tool": "conftest 0.56.0" },
  "scope":  "infra/loonvault plan (terraform show -json)",
  "result": "pass | fail",
  "conftest": { "...": "raw conftest -o json output" }
}
```
`policy_version` pins the report to the exact policy set that produced it. CI does **not** produce
these (no AWS credentials → no real plan); it runs the unit tests only. The future ADR-0010 apply
runner writes the same artifact to its handoff/evidence location.

## Rules (v1)

| Pattern | Rule | OSFI B-13 | GC |
|---|---|---|---|
| networking | No `0.0.0.0/0` / `::/0` ingress on admin ports 22/3389 | Cyber Security – Infrastructure security |, |
| networking | DB ingress (5432) must be SG-to-SG (no CIDR) | Cyber Security – Infrastructure security |, |
| storage | Every bucket has a BPA (all four flags true); no public ACL; no public bucket policy | Cyber Security – Data security (at rest) | GR06 |
| baseline | Provider region must be `ca-central-1` | Cyber Security – Infrastructure security | GR05 |
