---
title: "LoonVault platform — public economic data API with bank-grade security"
status: open
labels: [ready-for-agent]
created: 2026-06-07
---

## Problem Statement

LoonVault is a security proof-of-concept. The primary problem it solves is for the developer: demonstrating bank-grade cloud-security competence to financial-services employers in a single deployable project. That requires real infrastructure worth securing — a working, publicly reachable API with genuine data — so the security controls have something to protect. The data is payload, not the point.

The secondary problem (which justifies the infrastructure) is that developers and Canadians who want key Bank of Canada economic indicators — CPI, M2, CAD/USD exchange rates, overnight rate, bond yields, BCPI — and derived Pressure Metrics (Real M2, Yield Curve Spread, Bank Credit Growth Rate) have no simplified public API to call. These derived indicators do not exist as pre-computed endpoints anywhere.

LoonVault solves both: a public API that is real enough to be worth securing, built and defended the way a Canadian financial institution would.

---

## Solution

LoonVault is a public API serving Bank of Canada cost-of-living indicators — both raw Series and derived Pressure Metrics — built and secured the way a Canadian financial institution would.

The architecture is serverless (Lambda + private RDS Postgres in a VPC) on AWS `ca-central-1`, with Cloudflare at the edge providing WAF, rate limiting, Zero-Trust Access, and TLS Full-strict. All infrastructure is managed by Terraform with shift-left security gates (Checkov, Semgrep, pip-audit, betterleaks, OPA) running in CI and via local git hooks. Detection rules cover the six highest-value signals. The backend is ephemeral (`destroy` when idle, `apply` before interviews); the frontend is always-on — a **Next.js/TypeScript static site** built and synced to an **S3 bucket** (`ca-central-1`, REST endpoint), with Cloudflare providing CDN, WAF, and DDoS in front. The site has five nav sections: **Home** (project summary, goals, outcomes), **Data Analysis** (live data dashboard calling the public API), **Posture** (Threat Model and Security Controls sub-pages), **Compliance** (OSFI and GC Cloud Guardrails sub-pages), and a **GitHub** external link to the repo. Posture and Compliance are purely static — always-on independently of the backend.

The two-tier data model (ADR-0002) distinguishes Series (raw, from BoC Valet) from Pressure Metrics (computed internally), which is the structural decision that makes the analytically meaningful indicators possible while preserving the single-source constraint (ADR-0001).

---

## User Stories

### Public API consumers

1. As a developer, I want to retrieve a named Series (e.g. CPI, M2, CAD/USD) via a simple `GET` endpoint, so that I can integrate Bank of Canada data into my application without building a BoC Valet client myself.
2. As a developer, I want to retrieve a named Pressure Metric (e.g. Real M2, Yield Curve Spread) via a `GET` endpoint, so that I can consume derived economic stress indicators without reimplementing the computation.
3. As a developer, I want the API to return a consistent JSON shape for all Indicators, so that I can write a single client that handles both Series and Pressure Metrics.
4. As a developer, I want the API to return observation dates alongside each data point, so that I can plot the time series accurately.
5. As a developer, I want the API to return HTTP error responses with a meaningful status code and message when a series name is invalid or unavailable, so that I can handle errors gracefully in my application.
6. As a developer, I want to be able to call the API from a browser without CORS errors, so that I can build a frontend directly against it.
7. As a developer, I want the API to be reachable at a stable Cloudflare-proxied domain, so that I have a consistent base URL that does not change when the AWS backend is redeployed.

### Frontend users

8. As a Canadian consumer, I want to view current values for key cost-of-living indicators on a simple webpage, so that I can understand economic pressure on my household without reading central bank releases.
9. As a Canadian consumer, I want the frontend to load reliably even when the AWS backend is offline (e.g. after `terraform destroy`), so that the site is always reachable.
10. As a Canadian consumer, I want the frontend to display the date of the most recent observation for each Indicator, so that I know how current the data is.

### Platform administrator

11. As the platform administrator, I want a protected admin plane behind Cloudflare Access (Zero-Trust + MFA), so that administrative operations cannot be reached by unauthenticated callers.
12. As the platform administrator, I want the admin API to validate both the shared-secret origin header and the CF Access JWT at the origin Lambda authorizer, so that neither control alone is a single point of failure for the admin plane.
13. As the platform administrator, I want to trigger a manual data refresh outside of the scheduled daily ingest, so that I can recover from a missed run without waiting 24 hours.
14. As the platform administrator, I want to receive an SNS notification when a detection rule fires (CloudTrail disabled, root usage, no-MFA sign-in, IAM policy widened, security group changed, AccessDenied spike), so that I can investigate immediately.
15. As the platform administrator, I want Prowler compliance scans to be runnable on demand, so that I can capture a compliance report as a portfolio artifact at any point.

### Security / shift-left

16. As the developer, I want a gitleaks pre-commit hook that scans staged files before every `git commit`, and every push to run the full static-scan suite in GitHub Actions with no AWS credentials — `terraform fmt`, `terraform validate`, `just --fmt --check`, Checkov, betterleaks, Semgrep (`p/python` + `p/owasp-top-ten` + `p/typescript` + `p/react`), pip-audit, `npm audit`, Socket.dev, zizmor, Dependency Review (PR-time), Ruff, ESLint/`next lint`, tflint, regal, and actionlint — so that secrets, Python and TypeScript security issues, vulnerable and malicious dependencies, IaC misconfigurations, workflow vulnerabilities, and linting errors are all caught before they can reach the deployed infrastructure.
17. As the developer, I want a pre-push git hook to run OPA/Conftest against the `terraform plan` JSON output (using local developer credentials) whenever `.tf` files change, so that LoonVault-specific invariants are enforced locally against the real plan before code reaches GitHub — the "open SG to 0.0.0.0/0" attack scenario is blocked here.
18. As the developer, I want OPA policies to reject any plan that creates an unencrypted S3 bucket, a bucket without Block Public Access, or any CMK-required resource without a CMK, so that data-exposure misconfigs are caught before `terraform apply` is run.
19. As the developer, I want all third-party GitHub Actions in the CI pipeline pinned to immutable commit SHAs (not tags), so that a moved or compromised tag cannot substitute a malicious action — and since GitHub Actions carries no AWS credentials, a compromised Action cannot modify infrastructure regardless.
20. As the developer, I want all infrastructure operations run from the developer's local terminal via `just apply` and `just destroy`, so that no GitHub Actions runner or third-party Action ever holds an AWS session token with write permissions.
21. As the developer, I want Terraform remote state stored in an encrypted, access-controlled S3 bucket with a DynamoDB lock table, so that concurrent applies are prevented and state cannot be read by unauthorized principals.
22. As the developer, I want the SCP enforcing `ca-central-1` deployed at the AWS Organizations account level, so that a misconfigured Terraform resource cannot accidentally land outside Canada, regardless of IAM policy.

### Data pipeline

23. As the data pipeline, I want the Ingest Lambda to fetch the configured BoC Valet Series on a daily EventBridge schedule and write each response as a versioned, CMK-encrypted object to the S3 raw-zone, so that source data is preserved with an immutable audit trail.
24. As the data pipeline, I want the Transform Lambda to be triggered by S3 Event Notification via SQS (with a DLQ), so that a failed transform does not silently drop data and failed messages can be inspected and replayed.
25. As the data pipeline, I want the Transform Lambda to compute all three Pressure Metrics from the stored Series and write the results to RDS, so that derived Indicator values are always consistent with the latest ingested source data.
26. As the data pipeline, I want failed SQS messages to land in the DLQ after the configured retry count, so that transient failures do not cause infinite retry loops and poison-pill messages are isolated.

### Security — data and secrets

27. As the platform, I want the DB credential to be stored in Secrets Manager encrypted with a CMK, restricted via resource policy to only the Read Lambda and Transform Lambda execution role ARNs, so that no other principal — including root — can retrieve it.
28. As the platform, I want the DB credential to be rotated automatically by Secrets Manager, so that a compromised credential has a bounded validity window without manual intervention.
29. As the platform, I want the Read Lambda and Transform Lambda to cache the Secrets Manager response (TTL ~1 hour), so that warm Lambdas can serve requests during a short Secrets Manager outage.
30. As the platform, I want TLS 1.2 enforced at every network hop (Cloudflare Full-strict → API Gateway TLS_1_2 security policy → Lambda → RDS `sslmode=verify-full` + `ssl_min_protocol_version=TLSv1.2`), so that no hop can be downgraded to an insecure protocol.
31. As the platform, I want S3 Block Public Access enabled and the raw-zone bucket policy to deny non-VPC-endpoint access, so that raw data cannot be reached from the public internet.
32. As the platform, I want S3 object versioning enabled on the raw-zone bucket, so that accidental or malicious overwrites do not destroy source data.

### Security — network and identity

33. As the platform, I want the Read Lambda and Transform Lambda to run inside the VPC with no route to an internet gateway, reaching S3 only via a gateway VPC endpoint and RDS only via security group, so that network egress is constrained to the minimum required paths.
34. As the platform, I want RDS security group ingress to be SG-to-SG only (no CIDR blocks), enforced by an OPA policy in CI, so that the database cannot be reached from arbitrary IP addresses even if a misconfiguration slips through code review.
35. As the platform, I want the Lambda authorizer to reject any request to the public API that lacks the correct `X-Origin-Secret` header, so that callers who discover the raw API Gateway URL and bypass Cloudflare are denied.
36. As the platform, I want each Lambda to have its own least-privilege IAM execution role scoped to exact actions on exact ARNs (no wildcards), so that a compromised Lambda execution role cannot be used to escalate privilege or reach unrelated resources.
37. As the platform, I want the Read Lambda's execution role to be restricted to `secretsmanager:GetSecretValue` and `kms:Decrypt` on specific ARNs, so that if the role is compromised the blast radius is limited to read-only DB access on public data with no path to S3, IAM, STS, or the raw zone.

### Detection and compliance

38. As the platform, I want CloudTrail management events and scoped data events (S3 raw-zone, KMS CMKs, Lambda invocations) enabled in `ca-central-1`, so that all control-plane and sensitive data-plane actions are logged.
39. As the platform, I want an EventBridge rule to send an SNS alert on the first occurrence of `StopLogging`, `DeleteTrail`, or `UpdateTrail`, so that any attempt to disable the audit trail is immediately visible.
40. As the platform, I want a CloudWatch Logs metric filter on CloudTrail logs to alarm when more than 5 `AccessDenied` errors occur within 5 minutes, so that credential enumeration attempts (e.g. Pacu, ScoutSuite) are detected even though individual denials are noise.
41. As the platform, I want Prowler to be runnable against the live account to produce a compliance report mapped to OSFI B-13 / E-23 and GC Cloud Guardrails, so that compliance posture is verifiable and capturable as a portfolio artifact.
42. As the developer, I want a STRIDE threat model document covering all six threat categories with concrete LoonVault examples, so that I can defend the security design in an interview without notes.
43. As the developer, I want an OSFI B-13 / E-23 control mapping matrix and a GC Cloud Guardrails matrix, so that compliance coverage is explicit and auditable.

### Portfolio / interview demonstration

44. As the developer, I want six documented attack-and-defense scenarios (API flood, SQLi, no-credential admin call, OPA-blocked SG PR, direct API GW hit, suspicious CloudTrail/no-MFA action) that are demonstrably blocked or detected in the live system, so that I can show each control working under realistic conditions.
45. As the developer, I want the backend to be fully reconstructable from `just apply` in a single command, so that I can spin it up before an interview and destroy it after without losing anything.
46. As the developer, I want a published blog post tying the architecture, threat model, and attack demonstrations together, so that the portfolio is navigable by a hiring manager without a live walkthrough.
47. As the developer, I want a third-party sub-service register documenting every AWS service with criticality assessment and cloud exit path, so that OSFI E-23 third-party risk obligations are demonstrably satisfied.
48. As the developer, I want a cloud exit strategy document that includes the Secrets Manager export path (`aws secretsmanager get-secret-value`), so that the exit strategy is complete and verifiable.
49. As the developer, I want an architecture diagram showing trust boundaries, data flow, and controls at each hop, so that a hiring manager or interviewer can understand the security design without a live walkthrough.
50. As the developer, I want an incident response plan covering breach notification procedure, escalation path, and notification timelines, so that the portfolio demonstrates operational security maturity beyond just technical controls.
51. As the developer, I want a data classification exercise documenting that all LoonVault data — BoC Valet observations and derived Pressure Metrics — is classified as Protected B financial information for this POC, with rationale explaining why publicly available economic data warrants Protected B treatment in a Canadian financial institution context, and explicitly mapping each classification decision to the control it drives, so that the portfolio demonstrates classification-driven security design and data governance maturity, not just technical capability.

---

## Implementation Decisions

### Architecture

- **Serverless + private RDS in VPC** (Option B): HTTP API Gateway v2 → Read Lambda (in-VPC) → RDS Postgres (private subnet). No NAT — gateway VPC endpoints only (S3 gateway endpoint, no interface endpoints). Ingest Lambda outside VPC because it needs public internet access to reach BoC Valet; its trust boundary is IAM only.
- **Two-tier data model** (ADR-0002): Series (fetched from BoC Valet, stored as-is in S3 raw-zone and RDS) and Pressure Metrics (computed by Transform Lambda from stored Series). API exposes both as Indicators. See ADR-0002 for why this shape is locked.
- **Single data source: BoC Valet only** (ADR-0001): Statistics Canada and other sources are explicitly out of scope. Adding a second source is a meaningful scope expansion, not a one-line change.
- **Budget ceiling: < $10/mo**: driven by Secrets Manager (~$0.40/mo), KMS CMKs (~$1–3/mo total), CloudWatch Logs retention, and `db.t4g.micro` free tier. Gateway VPC endpoints only — interface endpoints (~$7/mo each) are excluded. Managed security services (GuardDuty, Security Hub, AWS Config) run in short evidence bursts only.

### Modules to build

- **Terraform root module + remote state bootstrap**: S3 encrypted state bucket, DynamoDB lock table. No GitHub OIDC role — all Terraform changes originate from the developer's terminal.
- **Networking module**: VPC, private subnets (RDS + in-VPC Lambdas), S3 gateway endpoint, security groups (SG-to-SG only — enforced by OPA policy for both `aws_security_group` inline blocks and standalone `aws_security_group_rule` resources).
- **AWS Organizations + SCP module**: Organizations enabled as Phase 0 prerequisite; SCP enforcing `ca-central-1` applied at account level (GR05 data residency).
- **KMS CMK module**: three CMKs — S3 raw-zone, RDS, Secrets Manager — with key management procedure documented. Annual automatic rotation enabled.
- **S3 raw-zone module**: CMK-encrypted, versioned, Block Public Access, Object Lock (stretch), bucket policy denying non-endpoint access.
- **Secrets Manager module**: DB credential secret (CMK-encrypted), resource policy restricting `GetSecretValue` to Read Lambda and Transform Lambda execution role ARNs only, automatic rotation enabled. Password generated directly in Secrets Manager — Terraform references the ARN only, never the plaintext value, so it never appears in state.
- **RDS module**: Postgres `db.t4g.micro`, private subnet, CMK-encrypted, `ssl_min_protocol_version=TLSv1.2` parameter group. Least-privilege Postgres roles: `role_reader` (SELECT on specific tables), `role_writer` (INSERT/UPDATE only — Transform Lambda in Phase 1), `role_transformer` (SELECT/INSERT/UPDATE on `series_observations` only — Transform Lambda from Phase 2, since Pressure Metric computation needs to read stored Series; `role_writer` retained for future write-only consumers). No role can DROP, TRUNCATE, DELETE, or access another role's schema.
- **SQS + DLQ module**: queue for S3 Event Notification → Transform Lambda trigger; DLQ for failed transforms.
- **Lambda module (×4)**: Ingest, Transform, Read, Admin — all implemented in **Python** (boto3 for AWS SDK, psycopg2 for Postgres, requests for BoC Valet HTTP). Each Lambda has its own least-privilege execution role (exact actions, exact ARNs, no wildcards). Secrets Manager SDK-level caching (TTL ~1hr) in Transform and Read Lambdas. RDS CA bundle bundled into each in-VPC Lambda deployment package.
- **API Gateway module**: HTTP API v2, Lambda authorizer (validates `X-Origin-Secret` header; Admin endpoints also validate CF Access JWT against Cloudflare public keys), throttling configured.
- **Cloudflare module (Terraform)**: DNS, WAF managed rules, rate limiting, Full-strict TLS, Zero-Trust Access for admin plane (MFA enforced). `X-Origin-Secret` token stored in SSM Parameter Store, rotated on a schedule.
- **CloudTrail + detection module**: management events + scoped data events (S3 raw-zone GetObject/PutObject, KMS Decrypt/GenerateDataKey, Lambda Invoke). Six detection rules: five EventBridge → SNS (single-occurrence signals); one CloudWatch Logs metric filter → CW Alarm → SNS (AccessDenied spike > 5 in 5 min). CloudWatch alarm on anomalous `GetSecretValue` volume.
- **OPA policies (CI)**: SG ingress must be SG-to-SG (no CIDR blocks); S3 bucket must have Block Public Access; CMK required on RDS, S3, Secrets Manager resources. Covers both `aws_security_group` inline ingress and `aws_security_group_rule` standalone resources.
- **CI pipeline (GitHub Actions)**: Checkov, Semgrep (`p/python` + `p/owasp-top-ten` + `p/typescript` + `p/react`), pip-audit (Python SCA), `npm audit` (frontend SCA), `just --fmt --check` (Justfile syntax), Socket.dev (npm supply chain), zizmor (Actions workflow security), Dependency Review (PR-time), Ruff (Python linter), ESLint/`next lint` + `eslint-plugin-security` (TypeScript linter), tflint + `tflint-ruleset-aws` (Terraform correctness), regal (Rego linter), actionlint (Actions correctness), betterleaks, TruffleHog, `terraform fmt`, `terraform validate` — no AWS credentials, every push/PR. All third-party Actions pinned to immutable commit SHAs. Dependabot configured for `pip`, `npm`, and `github-actions` on a daily schedule. GitHub Actions never deploys and holds no AWS credentials; all Terraform changes originate from the developer's terminal (no OIDC role exists).
- **Local git hooks**: gitleaks pre-commit (secrets before commit); OPA/Conftest against `terraform plan` JSON pre-push (fires on `.tf` changes, uses developer AWS credentials).
- **Frontend S3 module**: public S3 bucket (`ca-central-1`, REST endpoint) serving the Next.js static build output. Cloudflare DNS points to the S3 REST endpoint; Cloudflare proxy provides CDN, WAF, and DDoS. Full-strict TLS: Cloudflare → S3 HTTPS REST endpoint (valid AWS certificate). Build and deploy: `just deploy-frontend` from the terminal (wraps `npm run build && aws s3 sync out/ s3://loonvault-frontend/`).

### Key interface decisions

- **API authorizer**: single Lambda authorizer handles both public and admin paths. Public path: validates `X-Origin-Secret` header only. Admin path: validates `X-Origin-Secret` header **and** CF Access JWT (Cloudflare public keys at `https://loonvault.cloudflareaccess.com/cdn-cgi/access/certs`).
- **Secrets Manager vs SSM**: Secrets Manager for DB credential only (automatic rotation justifies the cost premium). SSM Parameter Store for all other config (origin secret token, BoC Valet series list, etc.).
- **Pressure Metric computation**: computed in Transform Lambda at ingest time and stored in RDS alongside Series rows. Read Lambda queries RDS for both — no on-the-fly computation at read time.
- **Regional STS endpoint**: `sts.ca-central-1.amazonaws.com` explicitly configured in the AWS provider and SDK config to avoid us-east-1 SPOF dependency.

### GC Cloud Guardrails compliance triggers (per governance memory)

Every new AWS service added must be logged in the third-party sub-service register with a criticality assessment, and three checks must pass: data residency (SCP covers `ca-central-1`), encryption at rest (CMK required), audit trail (CloudTrail + alarms). Services already registered: Secrets Manager (HIGH criticality), SQS (MEDIUM criticality).

---

## Testing Decisions

**What makes a good test**: tests observable behavior at the highest available seam, not implementation internals. A good test for a Terraform policy does not inspect Rego internals — it feeds a plan JSON and asserts on pass/fail. A good Lambda handler test does not assert on which SDK method was called — it asserts on the HTTP response shape for a given event.

### Seams (highest to lowest cost)

**Seam 1 — OPA/Conftest policy evaluation** (no AWS required)
- Input: `terraform plan -out plan.bin && terraform show -json plan.bin`
- Assertions: SG ingress is SG-to-SG only (no CIDR); S3 has Block Public Access; CMK applied to RDS/S3/Secrets Manager
- Rego unit tests via `conftest verify` for the policy logic itself
- This is the primary seam for the shift-left story (attack scenario #4)

**Seam 2 — Checkov static scan** (no AWS required)
- Runs against HCL directly in CI on every PR
- Existing tool, no new seam needed

**Seam 3 — Lambda handler unit tests** (proposed new seam)
- Test the handler function interface: `handler(event, context) → response`
- Mock at the AWS SDK boundary (Secrets Manager client, RDS connection pool) — not deeper
- Assertions: correct HTTP status codes, correct JSON shape, error handling for missing/invalid series names
- Prior art to establish with the first Lambda written (no existing tests in the repo yet)

**Seam 4 — HTTP API integration tests** (requires deployed stack)
- Hit the live API Gateway endpoint via Cloudflare
- Assertions: correct JSON shape, valid data, CORS headers present, direct API GW URL returns 403 (missing origin secret), admin endpoint returns 403 without CF Access token
- Run against ephemeral infra only — not in CI

---

## Out of Scope

- **Statistics Canada as a data source** — locked out by ADR-0001. Adding it requires a separate ingest path with its own auth, rate limiting, and schema decisions.
- **Multi-account AWS Organizations setup** — single account with Organizations enabled for SCP only. Multi-account is documented as the production upgrade path but is out of budget scope.
- **Multi-AZ RDS** — budget constraint. Documented as a production upgrade path (synchronous standby, ~60–120s automatic failover). A read replica is explicitly not equivalent to Multi-AZ for write resilience.
- **Always-on managed security services** — GuardDuty, Security Hub, AWS Config are enabled in short evidence bursts only (capture screenshots, then disable) to stay within the < $10/mo budget.
- **Auto-remediation mini-SOAR** — stretch goal (enhances attack scenario #6: detect → auto-respond); pull in if Phase 4 completes ahead of schedule.
- **Attack scenario #7 (S3 integrity tamper)** — stretch goal; requires Object Lock and a provenance-hash verification step.
- **SBOM generation** — stretch goal (Semgrep SAST and pip-audit SCA are now core; SBOM output is the remaining stretch item).
- **User authentication on the public API** — data is public; rate limiting at the Cloudflare edge is sufficient. No API key issuance or user accounts.

---

## Further Notes

- **AWS Organizations prerequisite**: AWS Organizations must be enabled before the SCP Terraform resource can be applied. This is a manual Phase 0 step — even a single-account org requires Organizations enabled. Do not advance Phase 0 until this is confirmed.
- **Terraform state bootstrap**: the S3 state bucket and DynamoDB lock table must be created before Terraform remote state can be configured. This is a chicken-and-egg bootstrap step — create locally first, then migrate state.
- **DB password not in Terraform state**: password is generated directly in Secrets Manager (not via `random_password`). Terraform references the ARN only. This is a deliberate decision to ensure plaintext never appears in state.
- **Understanding gates**: each phase has a build gate and an understanding gate. The understanding gate (whiteboard and defend the design cold) must be passed before advancing to the next phase. AI accelerates the build; the understanding must be the developer's own.
- **Ephemeral backend**: `just destroy` after interviews; `just apply` before. KMS CMKs persist (not destroyed) at ~$1/mo each at rest. Frontend S3 bucket and Next.js static files remain always-on at negligible cost; Home, Posture, Compliance, and the GitHub link are fully static and require no backend. Only Data Analysis makes live API calls.
- **Supply chain risk residual**: SHA-pinning mitigates the tag-moving risk demonstrated by tj-actions/changed-files (Mar 2025) and Trivy-Action (Mar 2026). Residual: a zero-day compromise of a pinned SHA is undetectable without Sigstore/cosign. Accepted for this POC; production upgrade path is dependency review automation and signed Actions verification.
