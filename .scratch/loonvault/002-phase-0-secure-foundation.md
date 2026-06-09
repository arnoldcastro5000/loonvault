---
title: "Phase 0 — Secure foundation"
status: open
labels: [ready-for-agent]
created: 2026-06-07
---

## Problem Statement

LoonVault's security story only holds if the foundation it is built on is secure. Before any application code is written, the platform needs a hardened bootstrapping layer: remote Terraform state that cannot be tampered with or read by unauthorised principals, GitHub Actions authentication that uses no long-lived AWS credentials, a region-enforcement SCP that makes data residency a hard guarantee rather than a convention, and a CloudTrail baseline so that every control-plane action is on record from day one. Without this, all subsequent phases inherit an insecure foundation — and the portfolio's security claims are only as strong as the weakest early decision.

Phase 0 is also the phase most exposed to chicken-and-egg problems: the state bucket must exist before remote state can be configured; AWS Organizations must be enabled before the SCP Terraform resource can be applied. These sequencing constraints make Phase 0 the slowest and most manual of all phases.

---

## Solution

Stand up a minimal, fully hardened AWS environment before any application infrastructure is provisioned. The deliverables are: encrypted remote Terraform state with locking, a GitHub OIDC federation role (no long-lived keys), an SCP enforcing `ca-central-1` at the account level, a CI pipeline with Checkov / Semgrep / pip-audit / betterleaks / OPA gates configured, and a CloudTrail baseline covering management events and scoped data events.

The phase ends with a concrete verification gate: a trivial PR deploys to AWS via OIDC and passes all CI scans; an attempted `us-east-2` resource is blocked by the SCP.

---

## User Stories

### Remote state and bootstrapping

1. As the developer, I want Terraform remote state stored in an S3 bucket encrypted with a CMK and access-controlled to the OIDC role only, so that state cannot be read or modified by unauthorised principals and plaintext secrets in state are protected at rest.
2. As the developer, I want a DynamoDB table used as a Terraform state lock, so that concurrent `terraform apply` runs cannot corrupt state.
3. As the developer, I want the S3 state bucket to have versioning enabled, so that a corrupted or accidentally deleted state file can be recovered from a prior version.
4. As the developer, I want the bootstrap resources (state bucket, lock table) created locally first and then imported into Terraform state, so that the chicken-and-egg dependency is resolved without manual resource management.
5. As the developer, I want the Terraform backend configuration to use the regional STS endpoint (`sts.ca-central-1.amazonaws.com`), so that state operations do not depend on us-east-1.

### GitHub OIDC authentication

6. As the developer, I want a GitHub Actions OIDC federation role provisioned in AWS as a portfolio artefact, so that I can demonstrate how CI/CD would be secured if GitHub Actions were ever permitted to deploy — with a scoped trust policy, no long-lived keys, and a regional STS endpoint.
7. As the developer, I want the OIDC role's trust policy scoped to the specific GitHub repository only (not all of GitHub), so that the demonstrated configuration follows least-privilege even as a non-active artefact.
8. As the developer, I want the OIDC role's permissions limited to state read and resource describe actions only — no `terraform apply` permissions — so that even if the role were assumed, it could not modify infrastructure.
9. As the developer, I want the OIDC role to reference the regional STS endpoint (`sts.ca-central-1.amazonaws.com`) in its trust policy, so that the demonstrated configuration avoids the us-east-1 SPOF dependency.

### AWS Organizations and SCP

10. As the developer, I want AWS Organizations enabled on the account (even as a single-account org), so that SCPs can be applied — this is a prerequisite for the SCP Terraform resource.
11. As the developer, I want an SCP deployed at the account level that denies creation of any resource outside `ca-central-1`, so that data residency is enforced as a hard account-level constraint regardless of IAM policy or human error.
12. As the developer, I want the SCP to permit the IAM and STS global actions that AWS requires (e.g. IAM is a global service), so that the SCP does not break legitimate cross-region control-plane calls.
13. As the developer, I want the SCP to be managed in Terraform (imported after manual enable), so that changes to the policy go through the same CI gates as all other infrastructure.
14. As the developer, I want to verify the SCP is working by attempting to create a resource in `us-east-2` and confirming it is blocked, so that the data residency guarantee is tested and not assumed.

### CI pipeline

15. As the developer, I want every push to run `terraform fmt -check`, `terraform validate`, and `just --fmt --check` in GitHub Actions, so that syntactically invalid or poorly formatted Terraform and Justfile are caught before review — no AWS credentials required.
16. As the developer, I want every push to run Checkov against the Terraform HCL in GitHub Actions, so that known IaC misconfigurations are caught in CI — no AWS credentials required.
17. As the developer, I want a gitleaks pre-commit hook that scans staged files before every `git commit`, so that secrets (access keys, tokens, passwords) are caught at the earliest possible point — before they enter git history at all.
18. As the developer, I want every push to run betterleaks in GitHub Actions as a belt-and-suspenders secret scan, so that any secrets that slipped past the pre-commit hook are caught in CI before they can be read by other contributors — no AWS credentials required.
19. As the developer, I want a pre-push git hook that runs OPA/Conftest against the `terraform plan` JSON output before any push containing `.tf` file changes, so that LoonVault-specific invariants (SG-to-SG ingress only, CMK required) are enforced locally against the real plan before code reaches GitHub — this hook uses the developer's local AWS credentials and does not run in GitHub Actions.
20. As the developer, I want every push to run Semgrep with the `p/python`, `p/owasp-top-ten`, `p/typescript`, and `p/react` rule packs in GitHub Actions, so that Python security issues (injection patterns, weak crypto, insecure subprocess usage) and TypeScript/React security issues (XSS, `dangerouslySetInnerHTML`, `eval()`, prototype pollution) are caught in CI from the first code commit onward — no AWS credentials required.
21. As the developer, I want every push to run pip-audit against the Lambda `requirements.txt` in GitHub Actions, so that known CVEs in Python dependencies (boto3, psycopg2-binary, requests) are caught in CI — no AWS credentials required.
22. As the developer, I want every push to run `npm audit` against the frontend `package.json` in GitHub Actions, so that known CVEs in Next.js, React, and transitive npm dependencies are caught in CI alongside the Python SCA scan — no AWS credentials required.
23. As the developer, I want Socket.dev to scan npm packages on every push in GitHub Actions, so that supply chain risks beyond known CVEs — typosquatting, new install scripts, maintainer account takeovers, and behavioural anomalies — are caught before a malicious package reaches the deployed frontend — no AWS credentials required.
24. As the developer, I want Dependabot configured for all three dependency ecosystems (`pip`, `npm`, and `github-actions`) with a daily update schedule, so that dependency updates are surfaced automatically as PRs and SHA-pinned Actions are kept current without manual tracking — a compromised old version is not silently retained.
25. As the developer, I want the `actions/dependency-review-action` to run on every PR, so that any newly introduced dependency with a known vulnerability of High severity or above is flagged at review time before the PR can be merged — complementing the full-tree scans that pip-audit and npm audit perform on every push.
26. As the developer, I want zizmor to run on every push in GitHub Actions scanning all `.github/workflows/*.yml` files, so that GitHub Actions-specific misconfigurations — script injection via untrusted workflow inputs, `pull_request_target` misuse, and overly broad workflow permissions — are caught in CI before they can be exploited to exfiltrate secrets or hijack the runner — no AWS credentials required.
27. As the developer, I want Ruff to run against all Lambda Python code on every push in GitHub Actions, so that style, correctness, and import-ordering issues are caught in CI — Ruff replaces flake8, pylint, and isort in a single fast invocation — no AWS credentials required.
28. As the developer, I want `next lint` (ESLint with `eslint-plugin-security`) to run against the frontend TypeScript code on every push in GitHub Actions, so that React best practices, TypeScript-level issues, and security anti-patterns are caught in CI alongside Semgrep — no AWS credentials required.
29. As the developer, I want tflint with the `tflint-ruleset-aws` plugin to run against the Terraform code on every push in GitHub Actions, so that AWS-specific correctness issues — invalid instance types, deprecated arguments, provider-level misconfiguration — are caught in CI alongside Checkov's security-focused checks — no AWS credentials required.
30. As the developer, I want regal to run against all OPA Rego policy files on every push in GitHub Actions, so that logic bugs, performance anti-patterns, and style issues in the policies that enforce the SG-to-SG and CMK invariants are caught before they create a false sense of security — no AWS credentials required.
31. As the developer, I want actionlint to run against all `.github/workflows/*.yml` files on every push in GitHub Actions, so that workflow correctness issues — typos in event names, invalid action inputs, type errors in expressions, shell script errors in `run:` steps — are caught alongside zizmor's security-focused checks — no AWS credentials required.
32. As the developer, I want all third-party GitHub Actions in the CI pipeline pinned to immutable commit SHAs (not tags), so that a moved or compromised tag cannot substitute a malicious action — and so that a compromised Action gains no AWS session token since GitHub Actions carries no credentials.
33. As the developer, I want a passing CI run to be a required status check before a PR can be merged, so that no infrastructure change can bypass the static scan gates.
34. As the developer, I want all infrastructure operations invoked from the developer's local terminal via `just apply` and `just destroy` (never from GitHub Actions), so that a compromised GitHub Actions runner or third-party Action has no path to modify AWS infrastructure.

### KMS CMKs

35. As the platform, I want three KMS CMKs provisioned — one for the S3 raw-zone, one for RDS, one for Secrets Manager — so that each storage layer has an independently rotatable, independently revocable encryption key.
36. As the platform, I want annual automatic rotation enabled on all CMKs, so that key material is refreshed without manual intervention.
37. As the platform, I want each CMK's key policy to restrict administrative and cryptographic access to the minimum required principals, so that key compromise is constrained to the intended usage scope.
38. As the developer, I want a key management procedure document describing each CMK's purpose, rotation schedule, and the steps required to revoke and replace it, so that OSFI B-13 data security and GC Cloud Guardrails GR06 obligations are met.

### CloudTrail baseline

39. As the platform, I want CloudTrail enabled in `ca-central-1` capturing all management events, so that every control-plane action (resource creation, IAM changes, SCP modifications) is on record from the first day of the build.
40. As the platform, I want CloudTrail data events enabled for the S3 raw-zone bucket (GetObject, PutObject), the KMS CMKs (Decrypt, GenerateDataKey), and Lambda functions (Invoke), scoped to specific ARNs rather than account-wide, so that sensitive data-plane actions are auditable without incurring the cost of full account-wide data event logging.
41. As the platform, I want CloudTrail logs delivered to a dedicated S3 log bucket with its own CMK encryption and a bucket policy that denies deletion and modification of log objects, so that an attacker who gains access to the account cannot erase their audit trail.
42. As the platform, I want an EventBridge rule that sends an SNS alert on the first occurrence of `StopLogging`, `DeleteTrail`, or `UpdateTrail`, so that any attempt to disable or tamper with the audit trail is immediately visible — even before the full detection pipeline is built in Phase 3.
43. As the developer, I want CloudWatch Logs retention on all log groups set to 2 years, so that the retention period meets Protected B operational standards even though the current data is unclassified.

### Phase 0 verification gate

44. As the developer, I want a trivial PR to pass all CI scans (`terraform fmt`, `terraform validate`, `just --fmt --check`, Checkov, tflint, betterleaks, Semgrep, Ruff, `next lint`, pip-audit, `npm audit`, Socket.dev, zizmor, actionlint, regal, Dependency Review) and the pre-push OPA/Conftest hook, so that the full scan pipeline is verified working before application code is added — Semgrep, Ruff, `next lint`, pip-audit, npm audit, and Socket.dev will return clean results in Phase 0 (no Python or TypeScript code yet) but their configuration is validated.
45. As the developer, I want confirmation that the SCP blocks a resource creation attempt in `us-east-2`, so that data residency enforcement is tested before any Series data lands in the environment.

---

## Implementation Decisions

### Bootstrap sequencing

- AWS Organizations must be enabled manually before any Terraform work begins — even a single-account org requires the service to be active before SCPs can be created. This is a Phase 0 prerequisite, not a Terraform resource. Import the org and root into Terraform state after enabling.
- The S3 state bucket and DynamoDB lock table must be created with a local backend first, then the backend block changed to `s3` and `terraform init -migrate-state` run. This is a one-time manual step; document it in the repo README so it is reproducible.
- Order of apply: (1) bootstrap module (state bucket, lock table, OIDC role) with local backend → (2) migrate to remote state → (3) org/SCP module → (4) KMS module → (5) CloudTrail module. Each step depends on the prior completing cleanly.

### Terraform module structure

- **`bootstrap/`**: S3 state bucket (CMK-encrypted, versioned), DynamoDB lock table, GitHub OIDC provider, OIDC federation role. Applied once locally; all subsequent work uses remote state.
- **`org/`**: AWS Organizations import, SCP resource (`aws_organizations_policy` + `aws_organizations_policy_attachment`). SCP denies all regions except `ca-central-1`, with explicit exceptions for IAM/STS/CloudFront (global services).
- **`kms/`**: three CMK resources (S3, RDS, Secrets Manager), key policies, aliases. Outputs CMK ARNs for consumption by later modules.
- **`cloudtrail/`**: CloudTrail trail, S3 log bucket (separate CMK, deletion-deny bucket policy), EventBridge rule for trail-tampering alert, SNS topic, CloudWatch log group (2-year retention).
- **`ci/`**: not a Terraform module — GitHub Actions workflow files. OPA policy files live alongside Terraform under `policies/`.

### OPA policy scope for Phase 0

Phase 0 OPA policies cover the infrastructure provisioned in this phase:
- S3 bucket resources must have Block Public Access enabled and CMK encryption configured.
- KMS CMK resources must have automatic rotation enabled.
- All resources must be in `ca-central-1` (belt-and-suspenders alongside the SCP — OPA catches it at plan time, SCP at apply time).
Policies covering SG ingress and RDS encryption are written in Phase 0 but only fire when those resource types are introduced in Phase 1.

### OIDC role permissions

The OIDC role is a portfolio artefact demonstrating how CI deployment would be secured — it is not used by the active pipeline. Its permissions are read-only: `s3:GetObject`, `s3:ListBucket` on the state bucket; `dynamodb:GetItem` on the lock table; and describe-level actions on AWS resources (no write, no apply). GitHub Actions carries no credentials and never assumes this role. The developer applies infrastructure locally using their own AWS credentials (IAM user or IAM Identity Center). The OIDC role's value is demonstrating the correct trust policy shape (repo-scoped, regional STS endpoint) to an interviewer.

### CloudTrail log bucket vs application log bucket

The CloudTrail log bucket is a separate resource from the S3 raw-zone bucket (provisioned in Phase 1). It uses its own CMK, has a strict bucket policy denying `s3:DeleteObject` and `s3:PutBucketPolicy` to all principals including root, and is not referenced by any application code. This separation limits blast radius if the application S3 configuration is ever misconfigured.

### Regional STS endpoint

`sts.ca-central-1.amazonaws.com` must be explicitly set in: (1) the OIDC role trust policy's `sts:ExternalId` condition, (2) the AWS provider `sts_region` argument in Terraform, and (3) any SDK configuration in later Lambda functions. Default STS endpoints route through us-east-1; without this, a us-east-1 outage can break credential issuance even for a fully `ca-central-1`-resident stack.

---

## Testing Decisions

**What makes a good test for Phase 0**: Phase 0 has no application logic to unit-test. Good tests assert on observable infrastructure intent (does this plan produce compliant resources?) and observable pipeline behavior (does this PR pass/fail the gate?). Tests should not inspect Terraform internals — they should feed plan JSON to a policy evaluator and assert on the evaluator's verdict.

### Seam 1 — OPA/Conftest policy evaluation (pre-push hook, local, requires developer AWS credentials)

- Trigger: pre-push git hook, fires only when `.tf` files are in the push
- Input: `terraform plan -out plan.bin && terraform show -json plan.bin`
- Run: `conftest test --policy policies/ plan.json`
- Assertions: no CIDR-based ingress rules present; all S3 buckets have Block Public Access; all KMS CMKs have `enable_key_rotation = true`; all resources are in `ca-central-1`
- Rego unit tests (`conftest verify`) test each policy rule in isolation with crafted pass/fail fixtures — these run in CI (no AWS needed) on every push
- This seam is the crown-jewel demonstration for attack scenario #4 (OPA blocks bad SG PR)

### Seam 2 — Checkov static scan (no AWS required)

- `checkov -d .` on every push
- Catches: unencrypted S3, public RDS, missing CloudTrail validation, missing log bucket access logging

### Seam 3a — Semgrep SAST (no AWS required, configured in Phase 0, meaningful from Phase 1 for Python, Phase 2 for TypeScript)

- `semgrep --config p/python --config p/owasp-top-ten --config p/typescript --config p/react` on every push
- Python rules (`p/python` + `p/owasp-top-ten`): injection patterns, weak crypto, insecure subprocess usage, hardcoded credentials — first meaningful results in Phase 1 when Lambda code is added
- TypeScript/React rules (`p/typescript` + `p/react`): XSS, `dangerouslySetInnerHTML`, `eval()`, prototype pollution, unsafe refs — first meaningful results in Phase 2 when the Next.js frontend is added
- Returns clean in Phase 0 — no Python or TypeScript code yet. Configuration is validated.

### Seam 3b — pip-audit SCA (no AWS required, configured in Phase 0, meaningful from Phase 1)

- `pip-audit -r requirements.txt` on every push
- Catches: known CVEs in boto3, psycopg2-binary, requests and transitive dependencies (OSV database)
- Returns clean in Phase 0 — no `requirements.txt` yet. First meaningful results in Phase 1.

### Seam 3c — npm audit SCA (no AWS required, configured in Phase 0, meaningful from Phase 2)

- `npm audit` against the frontend `package.json` on every push
- Catches: known CVEs in Next.js, React, TypeScript toolchain, and transitive npm dependencies
- Returns clean in Phase 0 — no frontend `package.json` yet. First meaningful results in Phase 2 when the Next.js frontend is added.

### Seam 3d — Socket.dev supply chain scan (no AWS required, configured in Phase 0, meaningful from Phase 2)

- Socket.dev GitHub Action on every push scanning npm packages
- Catches: supply chain risks beyond CVEs — typosquatting, new install scripts, maintainer account takeovers, suspicious package behaviour, dependency confusion
- Complements `npm audit` (CVE database) with behavioural analysis of package intent
- Returns clean in Phase 0 — no `package.json` yet. First meaningful results in Phase 2.

### Seam 3e — Dependency Review (no AWS required, PR-time only)

- `actions/dependency-review-action` runs on every PR (not on direct pushes — requires a base/head comparison)
- Catches: newly introduced dependencies with known High/Critical vulnerabilities, by diffing the dependency tree between the PR base and head
- Complements pip-audit and npm audit (which scan the full tree on every push) by focusing specifically on what a given PR *adds*
- Returns clean in Phase 0 — no dependency files yet. Becomes meaningful from Phase 1 onward.

### Seam 3f — zizmor GitHub Actions workflow scan (no AWS required, configured and meaningful from Phase 0)

- zizmor GitHub Action scans all `.github/workflows/*.yml` files on every push
- Catches: script injection via `${{ github.event.* }}` in `run:` steps, `pull_request_target` trigger with untrusted code checkout, overly broad `permissions:` declarations, missing `permissions: read-all` default
- Unlike betterleaks (which looks for secret strings) and Semgrep (which analyses Python/TypeScript), zizmor understands GitHub Actions workflow semantics — it is the only tool in the chain that can catch these workflow-structure vulnerabilities
- Meaningful from Phase 0 because the workflow files themselves are added in Phase 0; zizmor runs clean if the workflows are written correctly from the start

### Seam 3g — Linters (no AWS required, configured in Phase 0, meaningful per language introduction)

Five linters configured in Phase 0 alongside the SAST/SCA tools, each meaningful once the code they target is introduced:

- **Ruff** (`ruff check .`) — Python style, correctness, import ordering. Replaces flake8, pylint, isort. Returns clean in Phase 0; first meaningful results in Phase 1 when Lambda code is added.
- **ESLint** (`next lint` with `eslint-plugin-security`) — TypeScript/React best practices and security anti-patterns. Returns clean in Phase 0 and Phase 1; first meaningful results in Phase 2 when the Next.js frontend is added.
- **tflint** (`tflint --recursive` with `tflint-ruleset-aws`) — Terraform correctness: invalid instance types, deprecated arguments, provider-level issues. Complements Checkov (security) with correctness checks. Meaningful from Phase 0 — Terraform files are added here.
- **regal** (`regal lint policies/`) — OPA Rego correctness: logic bugs, performance anti-patterns, style. The OPA policies are a core security control; linting them gives confidence that they evaluate as intended. Meaningful from Phase 0 — Rego policy files are written here.
- **actionlint** — GitHub Actions workflow correctness: typos in event names, invalid action inputs, type errors in `${{ }}` expressions, shell errors in `run:` steps. Complements zizmor (security) with correctness. Meaningful from Phase 0 — workflows are added here.

Distinction from security tools: linters catch *incorrectness* and *bad practice*; Semgrep/zizmor/Socket.dev catch *exploitable vulnerabilities*. Both layers are needed — a syntactically correct but logically wrong Rego policy gives false assurance.

### Dependabot — automated dependency updates (scheduled, not a push-time gate)

- Configured via `.github/dependabot.yml` covering: `pip` (Lambda `requirements.txt`), `npm` (frontend `package.json`), `github-actions` (keeps SHA-pinned Actions current)
- Daily schedule — opens PRs automatically when updates are available
- Not a CI gate that blocks pushes; it is a background automation that surfaces updates as PRs for review
- Particularly valuable for SHA-pinned Actions: Dependabot opens a PR to update the pinned SHA when a new release is available, preventing stale pins from silently lagging behind a patched version

### Seam 3h — Secret scanning (two layers, no AWS required)

- **gitleaks pre-commit hook**: scans staged files on every `git commit`; catches secrets before they enter git history
- **betterleaks in GitHub Actions**: scans on every push; catches anything that slipped past the pre-commit hook
- Together these form a belt-and-suspenders secret detection layer: local speed + CI coverage

### Seam 4 — Terraform plan smoke test (no AWS required)

- `terraform plan` must exit 0 against the bootstrap module with a mock `terraform.tfvars`
- Validates variable wiring, module references, and provider configuration without touching AWS
- Run in CI on every PR touching `*.tf` files

### Seam 5 — SCP enforcement verification (requires live AWS, manual)

- Attempt `aws ec2 run-instances --region us-east-2` with a role subject to the SCP
- Assert: request is denied with `AccessDeniedException` citing the SCP
- One-time gate at the end of Phase 0; result captured as a screenshot for the portfolio

No prior art for tests exists in the repo yet — Seam 1 (OPA/Conftest) establishes the pattern that all subsequent policy tests will follow.

---

## Out of Scope

- **Application infrastructure** — VPC, subnets, RDS, SQS, Lambda, API Gateway. These are Phase 1 and Phase 2 work. The networking and KMS modules are provisioned in Phase 0 only to the extent needed to unblock Phase 1 (CMK ARN outputs, VPC skeleton).
- **Secrets Manager** — provisioned in Phase 1 alongside RDS.
- **Full detection pipeline** — the five remaining detection rules (root usage, no-MFA sign-in, IAM policy widened, SG change, AccessDenied spike) are Phase 3 work. Only the CloudTrail-disabled rule is wired in Phase 0 because it protects the audit trail that all other detection depends on.
- **Prowler compliance scan** — Phase 3. Phase 0 establishes the resources Prowler will scan; running a meaningful scan requires more infrastructure to exist.
- **Cloudflare configuration** — Phase 1 (DNS, WAF, origin secret).
- **Lambda code** — Phase 1.
- **Understanding gate questions** — not implemented here; they are developer study obligations listed in plan.md and must be completed before Phase 1 begins.

---

## Further Notes

- **AWS Organizations is the single most likely blocker**: enabling it is a console-only action that can take several minutes to propagate. Do not start Terraform work until the org is confirmed active and the management account root is importable.
- **State bucket CMK dependency**: the CMK for state bucket encryption must exist before the bucket is created. In the bootstrap module, create the CMK first; reference its ARN in the bucket resource. Terraform handles this within a single `apply` if the dependency is expressed via resource reference (not hardcoded ARN).
- **CI gate ordering**: gitleaks must run before any AWS-touching step in the pipeline — a secret committed alongside an IaC change should be caught before credentials are used.
- **Phase 0 understanding gate** (from plan.md): before starting Phase 1, be able to answer without notes — why OIDC federation is safer than long-lived keys; why remote state must be encrypted and locked; what each CI gate catches and its limits; what CloudTrail management vs data events are; why the SCP matters even when all resources are intentionally in `ca-central-1`.
