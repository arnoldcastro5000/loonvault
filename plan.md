# LoonVault — Plan

A **bank-grade secure data platform** portfolio project, built to land a **cloud-security
specialist** role (private sector, financial-services aim).

**One-line pitch:** A public API serving Bank of Canada cost-of-living indicators, built and
secured the way a Canadian financial institution would — defense-in-depth, mapped to the
OSFI B-13 Technology and Cyber Risk framework, with a working threat model and live
attack-&-defense demonstrations.

> The data is **payload**, not the point. Its job is to justify real infrastructure worth
> securing. All engineering effort goes toward the **security** story that gets the job.

---

## Locked Decisions

| Dimension | Decision |
|---|---|
| Target role | Cloud-security specialist, private sector (financial-services aim) |
| Cloud | AWS-dominant (`ca-central-1`); Cloudflare at the edge only |
| Archetype | Public data API + always-on static frontend |
| Architecture | **Option B** — serverless + private RDS in a VPC; **HTTP API** (API Gateway v2) |
| IaC | Terraform (manages AWS *and* Cloudflare) |
| Security spine | Threat model (STRIDE) + **OSFI B-13** primary (Technology and Cyber Risk) + **OSFI E-23** (Third-Party Risk) + **GC Cloud Guardrails** secondary (prescriptive verification layer, Prowler-verified) + **CIS Benchmarks** |
| Identity | Tiered: public rate-limited reads + admin plane behind **Cloudflare Access** (Zero-Trust + MFA) |
| Detection | Free-native + OSS (CloudTrail, Flow Logs, EventBridge→CloudWatch→SNS, Prowler) + short paid bursts |
| CI/CD | GitHub Actions + public repo; **CI = static scans only** (`terraform fmt`, `terraform validate`, Checkov, betterleaks, TruffleHog (verified credentials + AWS account IDs), Semgrep (SAST), pip-audit (Python SCA), `npm audit` (frontend SCA), `just --fmt --check` (Justfile syntax), Socket.dev (supply chain), zizmor (Actions workflow security), Dependency Review (PR-time), Ruff (Python linter), ESLint/`next lint` (TypeScript linter), tflint + AWS ruleset (Terraform linter), regal (Rego linter), actionlint (Actions correctness) — no AWS credentials, every push/PR). **Dependabot**: daily PRs for `pip`, `npm`, `github-actions` dependencies. **Local hooks**: gitleaks pre-commit; OPA/Conftest pre-push. **`just loonvault-apply` = terminal-only** (wraps `terraform apply`); `just deploy-frontend` for frontend. No GitHub OIDC role — GitHub Actions never holds AWS credentials; all Terraform changes originate from the developer's terminal. |
| Data | BoC Valet — rates, FX, CPI/core inflation, BCPI (single source) |
| Keys / account / frontend | **Single shared customer-managed KMS CMK** for S3 raw zone, RDS, and Secrets Manager (see ADR-0005 — separate per-service CMKs are the production standard but consolidated here for budget); S3 snapshots bucket uses SSE-S3 (AES-256) not CMK — public reads via Cloudflare cannot decrypt SSE-KMS objects; single account (multi-account documented as tradeoff); **lean static site (hand-written HTML/CSS/JS, no framework) on S3** (website endpoint, `ca-central-1`), Cloudflare CDN/WAF/DDoS in front — chose lean static over Next.js for finish-fast + native-over-frameworks (no build step, no JS/TS dependency surface) |
| Domains | API: `api-loonvault.cloudsecuritypractice.com` → Cloudflare → API Gateway. Frontend: `loonvault.cloudsecuritypractice.com` → Cloudflare → S3 REST endpoint. Cloudflare Access team domain: `loonvault.cloudflareaccess.com` |
| Secrets / DB auth | **RDS IAM authentication** for app DB users (no stored credential — ADR-0006); Secrets Manager (CMK) holds only the RDS-managed master password; SSM Parameter Store (SecureString) for the origin secret + other config |
| Task runner | **Justfile** — `just loonvault-apply`, `just loonvault-destroy`, `just deploy-frontend`, `just scan` wrap all terminal-only operations; raw commands documented in README as fallback |
| STS | Regional endpoint `sts.ca-central-1.amazonaws.com` — avoids us-east-1 SPOF |
| Budget | **< $10/mo** |

---

## Architecture (data flow)

- **Ingest:** EventBridge (daily) → Ingestion Lambda (**outside VPC** — needs internet to reach
  BoC Valet) → BoC Valet → **encrypted, versioned S3 raw-zone** (CMK; Object Lock = stretch)
  → S3 Event Notification → **SQS queue** (DLQ for failed transforms; S3 resource policy
  permits S3 to send messages) → Transform Lambda (**inside VPC**, reads S3 via gateway
  endpoint) → **RDS Postgres in a private subnet** (CMK) + **S3 snapshots bucket** (SSE-S3;
  public-readable via Cloudflare; frontend falls back to snapshots when API is unavailable —
  see ADR-0004).
- **Public read:** Cloudflare (DNS, WAF, rate-limit, TLS Full-strict, **1-hour edge cache** on `/series/*` + `/pressure-metrics/*`, query string in cache key, bypass for `/admin/*`) → API Gateway (throttling;
  Lambda authorizer validates **shared-secret header** `X-Origin-Secret`) → Read Lambda
  (**in-VPC**, least-privilege IAM) → RDS (`sslmode=verify-full`, TLS 1.2). **Gateway VPC
  endpoints, no NAT.**
- **Admin:** Cloudflare Access (Zero-Trust + MFA) → API Gateway (Lambda authorizer validates
  **both** shared-secret header and CF Access JWT) → admin Lambda.
- **Frontend:** lean hand-written static site (HTML/CSS/JS, no framework, no build step) synced to **S3 (website endpoint, `ca-central-1`)**, Cloudflare CDN/WAF/DDoS in front. Sections: **Home** (project summary, architecture, + a live indicators panel that calls the public API and falls back to S3 snapshots), **Posture** (threat model + controls), **Compliance** (OSFI + GC Cloud Guardrails + the OPA compliance matrix and blocked-attack evidence), **GitHub ↗**. Home/Posture/Compliance are static, always-on independently of the backend.

### Origin protection
Cloudflare injects `X-Origin-Secret: <token>` on every proxied request. Token stored in SSM
Parameter Store, rotated on a schedule. Lambda authorizer rejects any request missing the
correct header — preventing direct API Gateway URL access that would bypass Cloudflare WAF,
rate limiting, and Access. Admin endpoints additionally validate the CF Access JWT (Cloudflare
public keys at `https://loonvault.cloudflareaccess.com/cdn-cgi/access/certs`).

---

## Security Controls by Domain

(Each maps to a threat in the model and an OSFI B-13 principle — so the attack demos double as evidence.)

- **Identity:** tiered access; least-privilege IAM role per Lambda (exact actions only — no
  wildcards); CI holds no AWS credentials (applies are terminal-only via short-lived IAM
  Identity Center sessions); MFA enforced on admin plane; CF Access JWT
  validated at origin by Lambda authorizer.
- **Network:** VPC, private subnets for RDS + Transform/Read Lambdas; security groups
  (RDS SG ingress is SG-to-SG only — no CIDR blocks, enforced by OPA policy); gateway VPC
  endpoints (no NAT); VPC Flow Logs. Ingest Lambda outside VPC (trust boundary is IAM only).
- **Data:** encryption at rest (shared CMK on S3 raw zone + RDS + Secrets Manager; S3 snapshots
  bucket uses SSE-S3 — public reads via Cloudflare cannot decrypt SSE-KMS); TLS 1.2 enforced
  at every hop (Cloudflare Full-strict; API GW `TLS_1_2` security policy; `sslmode=verify-full`
  + AWS RDS CA bundle; RDS parameter group `ssl_min_protocol_version=TLSv1.2`); S3 Block Public
  Access on all private buckets (raw zone, Terraform state); snapshots bucket and frontend
  bucket are intentional public-read exceptions; versioning (+ Object Lock for integrity);
  explicit data-classification exercise.
- **Secrets / DB auth:** application DB users authenticate via **RDS IAM authentication**
  (ADR-0006) — no stored DB credential. Each Lambda's execution role holds `rds-db:connect`
  on its own `dbuser` ARN; tokens are signed locally (SigV4, 15-min TTL), so the in-VPC
  Lambdas make no Secrets Manager call and need no interface endpoint. The only Secrets
  Manager secret is the RDS **master** password, auto-managed by RDS (`manage_master_user_password`,
  CMK-encrypted) and never read by the Lambdas — Terraform references no secret value, so
  plaintext never appears in state.
- **Database:** least-privilege Postgres roles — Read Lambda connects as login user
  `lv_reader` (granted `rds_iam` for auth), which inherits the `NOLOGIN` role `role_reader`
  (`SELECT` only on specific tables); Transform Lambda connects as `lv_writer` (also
  `rds_iam`), inheriting `role_writer`
  (`INSERT`/`UPDATE` only) in Phase 1, upgraded to `role_transformer`
  (`SELECT`/`INSERT`/`UPDATE` on `series_observations` only) in Phase 2 — read access is
  required to compute Pressure Metrics from stored Series. `role_writer` is retained for
  future write-only consumers. No role can `DROP`, `TRUNCATE`, `DELETE`, or access another
  role's schema.
- **Detection/response:** CloudTrail (management events + data events scoped to S3 raw-zone,
  KMS CMKs, Lambda functions); VPC Flow Logs; six detection rules (see Detection Pipeline);
  Prowler compliance scans; auto-remediation (stretch).
- **Governance / shift-left:** Terraform + Checkov + tflint (Terraform correctness) + Semgrep (SAST) + Ruff (Python linter) + ESLint/`next lint` (TypeScript linter) + regal (Rego linter) + pip-audit (Python SCA) + `npm audit` (frontend SCA) + Socket.dev (supply chain) + zizmor (Actions workflow security) + actionlint (Actions correctness) + Dependency Review (PR-time) + Dependabot (automated updates) + betterleaks + TruffleHog + gitleaks (CI secret scanning) + gitleaks (pre-commit) + OPA (pre-push hook); remote state
  encrypted + locked; OPA enforces LoonVault-specific invariants (e.g. RDS SG ingress must be
  SG-to-SG, never CIDR) — policy covers both `aws_security_group` (inline ingress blocks) and
  `aws_security_group_rule` (standalone rule resources). OPA cannot catch post-deploy drift —
  that is Prowler's job. All third-party GitHub Actions pinned to immutable **commit SHAs**
  (not tags — tags can be moved, as demonstrated by tj-actions/changed-files CVE-2025-30066
  and Trivy-Action Mar 2026).
- **AI-assisted development:** The primary threat in AI-assisted development is **prompt injection**: malicious content in a fetched web page, a dependency README, or a crafted repository file injects instructions into the AI's context, causing it to introduce a subtle, plausible-looking change to security-critical code — a bypass condition in the Lambda authorizer, a weakened OPA policy rule, a hardcoded value replacing a Secrets Manager reference. The AI becomes a confused deputy: the developer authorised it to edit code, not to introduce backdoors. Compensating controls: Claude Code runs inside a devcontainer with filesystem scope limited to the repo (no access to SSH keys, AWS credentials, or system files outside the project), bubblewrap process sandbox active, and outbound network restricted to an allowlist — limiting what content the AI can fetch and act on. All Terraform and Justfile commands (`just loonvault-apply`, `just loonvault-destroy`, `just deploy-frontend`, `just scan`) are executed by the developer outside the devcontainer — AWS credentials are never present in the devcontainer environment at all, not even as environment variables. Developer AWS access uses short-lived IAM Identity Center session tokens (not long-lived access keys), so the credential validity window is bounded even in a worst-case scenario. All AI-generated code passes the full CI gate before deploy — shift-left scans are agnostic to authorship and catch misconfigurations regardless of how they were introduced. Neither B-13 nor GC Cloud Guardrails currently addresses AI-assisted development; these controls are the compensating measure. See T-051 in the threat model.
- **Edge:** Cloudflare WAF, rate limiting, DDoS protection, TLS Full-strict, Zero-Trust Access, **edge caching** (1-hour TTL on public API endpoints; bypass on `/admin/*`).
- **Account:** AWS Organizations + SCP enforcing `ca-central-1` at account level (data
  sovereignty — supports E-23 data residency obligations); regional STS endpoint
  (`sts.ca-central-1.amazonaws.com`).

---

## Lambda IAM Roles (least-privilege, exact actions)

### Ingest Lambda (outside VPC)
- `s3:PutObject` on `arn:aws:s3:::loonvault-raw/*`
- `kms:GenerateDataKey` on shared CMK ARN
- CloudWatch Logs on its log group

### Transform Lambda (inside VPC)
- `s3:GetObject` on `arn:aws:s3:::loonvault-raw/*`
- `s3:PutObject` on `arn:aws:s3:::loonvault-snapshots/*`
- `rds-db:connect` on the `lv_writer` dbuser ARN (RDS IAM auth — no Secrets Manager)
- `kms:Decrypt` on shared CMK ARN (covers S3 raw zone read + SQS message decrypt)
- `kms:GenerateDataKey` on shared CMK ARN (covers RDS; snapshots bucket uses SSE-S3, no KMS needed)
- VPC attachment (`AWSLambdaVPCAccessExecutionRole`)
- CloudWatch Logs on its log group

### Read Lambda (inside VPC)
- `rds-db:connect` on the `lv_reader` dbuser ARN (RDS IAM auth — no Secrets Manager, no KMS)
- VPC attachment (`AWSLambdaVPCAccessExecutionRole`)
- CloudWatch Logs on its log group
- **Blast radius if compromised:** DB reads only (data is public anyway). Cannot write to S3,
  touch other Lambdas, call IAM/STS, or reach the raw zone. Network isolation reinforces this.

---

## Detection Pipeline

Six rules. EventBridge for single-occurrence signals (one event = already suspicious).
CloudWatch Logs metric filter for rate-based signals (spike detection requires counting across
time — EventBridge has no memory across events).

| Signal | Tool | Pattern / Filter | Threshold |
|---|---|---|---|
| CloudTrail disabled | EventBridge → SNS | `eventName`: `StopLogging`, `DeleteTrail`, `UpdateTrail` | 1 occurrence |
| Console sign-in without MFA | EventBridge → SNS | `source: aws.signin`, `MFAUsed: No` | 1 occurrence |
| Root account usage | EventBridge → SNS | `userIdentity.type: Root` | 1 occurrence |
| IAM policy widened | EventBridge → SNS | `eventName`: `PutUserPolicy`, `AttachRolePolicy`, `CreatePolicy` | 1 occurrence |
| AccessDenied spike | CloudTrail → CW Logs → metric filter → CW Alarm → SNS | `{ ($.errorCode = "AccessDenied") }` | > 5 in 5 min |
| Security group rule added | EventBridge → SNS | `eventName`: `AuthorizeSecurityGroupIngress`, `RevokeSecurityGroupIngress` | 1 occurrence |

AccessDenied spike = fingerprint of permission enumeration (Pacu, ScoutSuite). One
AccessDenied is noise; a burst is an attacker probing what a compromised credential can reach.

Additional: CloudWatch/CloudTrail alarm on IAM policy changes that widen `rds-db:connect`
scope, and on `GetSecretValue` against the RDS-managed master secret (which the Lambdas
never call — any access is anomalous by definition).

---

## OSFI B-13 / E-23 — Control Mapping

OSFI B-13 has three domains: Governance and Risk Management, Technology Operations and
Resilience, and Cyber Security. OSFI E-23 covers third-party risk management (effective
July 1, 2025).

| Domain | Principle | LoonVault control |
|---|---|---|
| **Cyber Security** | Identity & access management | Cloudflare Access + MFA; CF Access JWT validated at origin; least-privilege IAM role per Lambda; credential-less CI (terminal-only applies via short-lived Identity Center sessions) |
| **Cyber Security** | Data security (at rest) | CMK on S3, RDS, Secrets Manager; automatic annual key rotation; key management procedure documented |
| **Cyber Security** | Data security (in transit) | TLS 1.2 at every hop; Cloudflare Full-strict; `sslmode=verify-full`; `ssl_min_protocol_version=TLSv1.2` |
| **Cyber Security** | Infrastructure security | VPC private subnets; SG-to-SG ingress only (OPA enforced); gateway VPC endpoints; SCP enforces `ca-central-1` |
| **Cyber Security** | Threat & vulnerability management | OPA (pre-push hook) + Checkov + Semgrep (SAST) + pip-audit (SCA) + betterleaks + TruffleHog in CI; gitleaks pre-commit; Prowler post-deploy scans; SHA-pinned Actions |
| **Cyber Security** | Security monitoring & response | CloudTrail (management + data events); 6 EventBridge/CloudWatch detection rules; incident response plan |
| **Technology Operations** | Change management | IaC (Terraform); CI pipeline gates; Secrets Manager automatic rotation |
| **Governance** | Risk identification & assessment | STRIDE threat model; data classification exercise (Protected B-ready) |
| **E-23 Third-party** | Vendor risk management | Third-party sub-service register; cloud exit strategy |

Cloud exit strategy must explicitly document Secrets Manager export path:
`aws secretsmanager get-secret-value --secret-id <name>` → store in destination system.

### GC Cloud Guardrails — Secondary Verification

GC Cloud Guardrails are the federal government's prescriptive cloud baseline (30 controls,
published by TBS under Directive on Service and Digital, Appendix G). Not the primary target
(they apply to government departments, not private financial institutions), but the controls
built for OSFI B-13 satisfy them simultaneously. Prowler verifies this automatically.

Interview framing: *"I built against OSFI B-13 as the primary framework because it governs
my target employers. I also verified the controls satisfy GC Cloud Guardrails — the federal
government's cloud baseline — demonstrating compliance breadth verifiable via Prowler."*

| Guardrail | Satisfied by |
|---|---|
| GR04 — Admin access safeguards | Cloudflare Access + MFA; CF Access JWT validated at origin |
| GR05 — Data location | SCP enforces `ca-central-1` |
| GR06 — Encryption at rest | CMK on S3, RDS, Secrets Manager; annual key rotation |
| GR07 — Encryption in transit | TLS 1.2 at every hop; `sslmode=verify-full` |
| GR11 — Logging and monitoring | CloudTrail (management + data events); CloudWatch alarms; Prowler |

---

## Phased Build (~8 weeks, evenings/weekends, foundation-first)

Each phase leaves a deployable, secure thing — stop at any phase and still have a portfolio.

- **Phase 0 — Secure foundation:**
  - *Prerequisite:* Enable AWS Organizations; import into Terraform state.
  - Terraform remote state (encrypted S3 + DynamoDB lock), SCP to enforce `ca-central-1`,
    CI with Checkov/Semgrep/pip-audit/betterleaks/OPA (pre-push hook)/gitleaks (pre-commit), CloudTrail +
    logging baseline (management events — which include KMS cryptographic calls — plus S3/Lambda data events).
  → *Verify: a trivial PR passes every CI scan with no AWS credentials present; SCP blocks a `us-east-2` resource.*

- **Phase 1 — Vertical slice:** one series → S3 raw → RDS → one public `GET`, fully secured.
  Includes: shared-secret header on API GW, `sslmode=verify-full` + RDS CA bundle, least-
  privilege Postgres roles, RDS IAM authentication for app DB users (no stored credential).
  → *Verify: live endpoint returns real data, encrypted, least-privilege.*

- **Phase 2 — Breadth:** more series + derived "pressure" metrics + Cloudflare Access admin
  plane (Lambda authorizer validates shared secret + CF Access JWT).
  → *Verify: admin action blocked without Access; direct API GW URL returns 403.*

- **Phase 3 — Detection + docs:** the five remaining detection rules live (all six active), Prowler, threat-model doc,
  OSFI B-13 / E-23 mapping matrix.
  → *Verify: Prowler report produced + a triggered alert.*

- **Phase 4 — Attack & Defense + blog + polish.**
  → *Verify: scenarios #1–6 each demonstrably blocked/detected.*

---

## Understanding Gates (you must defend these cold)

Each phase has a **build-gate** (it works) *and* an **understanding-gate** (you can whiteboard
and defend it with no notes). AI may accelerate the build; the understanding must be yours,
because security interviews deep-dive exactly here. Do not advance a phase until you can
answer its questions out loud, unaided.

**Phase 0 — Secure foundation**
- [ ] Why CI holds no AWS credentials at all (terminal-only applies via short-lived IAM
      Identity Center sessions) — what a compromised Action can and cannot reach as a result,
      and why this beats both long-lived IAM keys *and* OIDC-federated CI deploys for a
      single-developer project.
- [ ] Why Terraform remote state must be encrypted, access-controlled, and locked — what
      sensitive values land in state in plaintext, and what the DynamoDB lock prevents.
- [ ] What each gate catches *and its limits*: Checkov (IaC misconfig), Semgrep (Python SAST via `p/python`: injection, weak crypto, insecure patterns; TypeScript/React SAST via `p/typescript` + `p/react`: XSS, `dangerouslySetInnerHTML`, `eval()`, prototype pollution; cross-language via `p/owasp-top-ten`), pip-audit (Python dependency CVEs), `npm audit` (frontend JS/TS dependency CVEs), Socket.dev (supply chain risks beyond CVEs: typosquatting, install scripts, maintainer takeovers), zizmor (GitHub Actions workflow security: script injection, `pull_request_target` misuse, overly broad permissions), Dependency Review (newly introduced vulnerable deps on each PR), Dependabot (automated daily dependency update PRs — keeps SHA-pinned Actions current), gitleaks pre-commit (secrets before commit), betterleaks + TruffleHog in CI (secrets that slipped through), OPA pre-push hook (LoonVault-specific invariants against plan JSON),
      OPA/conftest (LoonVault-specific invariants Checkov cannot express), and the five linters
      — Ruff (Python), ESLint/`next lint` (TypeScript/React), tflint (Terraform AWS correctness),
      regal (Rego), actionlint (Actions) — plus `just --fmt --check` (Justfile syntax), which catch
      *incorrectness and bad practice* rather than exploitable vulnerabilities. Why that distinction
      matters: a syntactically valid but logically wrong Rego policy passes regal yet still gives
      false security assurance. Why "it passed the scanners" ≠ "it's secure." What OPA cannot catch
      (post-deploy drift — that's Prowler).
- [ ] What CloudTrail records (management vs data events); why data events are off by default
      and what blind spot that creates (e.g. S3 object-level GetObject/PutObject and Lambda
      Invoke are invisible without S3/Lambda data events — note KMS cryptographic calls like
      Decrypt are *management* events, so they are captured without data events); why disabling
      CloudTrail must itself trigger an alert.
- [ ] Why the SCP enforcing `ca-central-1` matters even when all resources are intentionally
      deployed there — what it prevents that IAM policy alone cannot.

**Phase 1 — Vertical slice**
- [ ] How you scoped each Lambda execution role to least privilege; exact actions and ARNs;
      why a wildcard action/resource is dangerous.
- [ ] Blast radius if the Read Lambda's role is compromised — what the attacker can and cannot
      reach, and why.
- [ ] Encryption at rest vs in transit; what a CMK + key policy controls; how it differs from
      AWS-managed keys; envelope encryption in one sentence.
- [ ] What "private subnet" means (no route to IGW) and how Transform/Read Lambdas reach RDS
      (security group) and S3 (gateway endpoint, no NAT). Why Ingest Lambda is outside the VPC.
- [ ] Trace one request end-to-end: Cloudflare → API Gateway → Lambda → RDS. Where TLS
      terminates at each hop. Why `sslmode=verify-full` matters even inside a private subnet
      (`require` encrypts but doesn't verify — MITM inside the VPC is the threat).
- [ ] Why RDS IAM authentication for app DB users (no stored credential, removes the Secrets
      Manager interface endpoint, short-lived tokens — ADR-0006); the tradeoffs (connection-rate
      ceiling, resource-ID-tied ARN on an ephemeral instance); why the RDS master secret still
      uses Secrets Manager.
- [ ] How the shared-secret header prevents direct API Gateway access; what happens to your
      threat model if it's absent or the token is leaked.

**Phase 2 — Breadth**
- [ ] Zero-Trust: why identity-aware Cloudflare Access + MFA beats network-based admin access.
- [ ] Why validating the CF Access JWT at the origin matters — what the shared-secret header
      alone doesn't prevent.
- [ ] The three identities in the system (public consumer, privileged admin, machine/IAM role)
      and how each authenticates.
- [ ] Where rate limiting/throttling happens (Cloudflare edge *and* API Gateway) and why
      defense-in-depth across both layers matters.

**Phase 3 — Detection + docs**
- [ ] STRIDE: each letter, with a concrete threat from *your* system for each category.
- [ ] Your detection pipeline end-to-end — which signals use EventBridge (single-occurrence)
      vs CloudWatch Logs metric filter (rate/spike); why EventBridge alone cannot detect spikes.
- [ ] Why an AccessDenied spike is a stronger signal than a single event; what attack pattern
      it fingerprints.
- [ ] What OSFI B-13 is, why it exists, and how ≥3 of its principles map to controls you built. Difference between B-13 (technology and cyber risk) and E-23 (third-party risk). Why B-13 is the primary target (governs private financial institutions) and GC Cloud Guardrails is the secondary verification layer (government baseline, prescriptive, Prowler-verified). Why demonstrating both is stronger than either alone.
- [ ] What Prowler checks, what a finding means, how you'd remediate one; CIS benchmark vs
      threat model — the difference.
- [ ] Why you classified all LoonVault data as Protected B even though BoC Valet observations
      are publicly available — what a Canadian financial institution would do with economic
      data used in risk and credit decisions, and how the classification drove the control
      selection rather than the controls being over-engineered for the data.

**Phase 4 — Attack & Defense**
- [ ] For each of scenarios #1–6: attacker goal, the exact control that stops it, **and the
      blast radius if that control were absent.**
- [ ] Which scenarios are caught by more than one layer; which have a single point of failure.
- [ ] For #4 (OPA): how Rego evaluates the policy, where in the pipeline it runs, what it
      cannot catch (post-deploy drift).

**Cross-cutting (interviewers love these)**
- [ ] Blast radius if the Read Lambda's role is compromised — what can the attacker reach?
- [ ] Where are the single points of failure in the whole design? (Cloudflare, single-AZ RDS,
      ca-central-1.) What is the production upgrade path for each? Why a read replica is not
      the same as Multi-AZ for write resilience.
- [ ] What you'd do differently with a real budget / in production (Multi-AZ RDS, always-on
      GuardDuty, AWS WAF on API Gateway, multi-account org) — and *why you didn't here.*
- [ ] Why us-east-1 is a SPOF for many AWS accounts even in other regions, and how using the
      regional STS endpoint mitigates it.

---

## Attack-&-Defense Demonstrations

| # | Attack | Defense | Domain | Status |
|---|---|---|---|---|
| 1 | API request flood | Cloudflare rate-limit + API GW throttling | Availability/DoS | Core |
| 2 | SQLi / malicious payload | WAF managed rules + parameterized queries | App security | Core |
| 3 | Admin call w/o credentials | Cloudflare Access (Zero-Trust) + CF Access JWT validated at origin | Identity | Core |
| 4 | PR opens SG `0.0.0.0/0:22` or public S3 | **Custom OPA + Checkov block the deploy** | Shift-left | Core (crown jewel) |
| 5 | Direct hit on API GW / RDS / raw S3 | Shared-secret header (403) + private subnet + Block Public Access | Network/data | Core |
| 6 | Suspicious action (disable CloudTrail, no-MFA) | EventBridge → CloudWatch alarm → SNS | Detection | Core |
| 7 | Tamper with ingested record in S3 | Versioning/Object Lock + provenance-hash mismatch | Integrity | Stretch |
| — | Auto-remediation (mini-SOAR): detect → auto-fix | EventBridge → Lambda re-blocks resource | Response | Stretch |

---

## Deliverables / Artifacts

- Public GitHub repo + strong README
- Architecture diagram (trust boundaries, data flow, controls)
- STRIDE threat-model document (the centerpiece)
- Security controls inventory (organised by domain; cross-referenced to OSFI B-13 principles and GC Cloud Guardrails)
- OSFI B-13 / E-23 ↔ controls mapping matrix (primary; partly auto-generated from Prowler)
- GC Cloud Guardrails ↔ controls mapping matrix (secondary verification; Prowler-verified)
- Data classification exercise (all data classified as Protected B; rationale and control mapping documented)
- Incident response plan (breach notification procedure, escalation path, notification timelines)
- Prowler / scan reports (compliance %, findings remediated)
- 6 core attack-&-defense clips / annotated screenshots
- One blog post tying it together
- Ephemeral backend demo (`apply` before interviews, `destroy` after) + always-on frontend
- Cloud exit strategy document (includes Secrets Manager export path)
- Third-party sub-service register

---

## Budget Guardrails ( < $10/mo )

- **App DB auth via RDS IAM** (ADR-0006) — no stored credential, no Secrets Manager call on
  the data path. Secrets Manager holds only the RDS-managed master password (~$0.40/mo).
- **Gateway VPC endpoints only** (S3 gateway endpoint — free). **No interface endpoints and
  no NAT**: the in-VPC Lambdas sign IAM auth tokens locally, so they make no AWS API call
  needing an endpoint. (Removing the Secrets Manager interface endpoint that an earlier
  Secrets-Manager design required saves ~$14.60/mo while the stack runs — see ADR-0006.)
- RDS `db.t4g.micro` (~$0.016/hr running); `destroy`/`apply` around interviews keeps it near
  $0 when idle. Note: the AWS Free Tier changed on 2025-07-15 — accounts created after that
  date get a 6-month / $200-credit plan, **not** the legacy 12-month free tier, so the
  ephemeral apply/destroy pattern (not a perpetual free instance) is what keeps RDS cost down.
- Managed security services (GuardDuty/Security Hub/Config) enabled in **short evidence
  bursts only** — capture screenshots, then disable.
- **Single shared KMS CMK** (~$1/mo) for S3 raw zone, RDS, and Secrets Manager (ADR-0005);
  the Phase 0 Terraform state CMK is separate (~$1/mo) → ~$2/mo total.
- CloudWatch Logs retention: **2 years** (Protected B requirement; ~$1–2/mo at LoonVault volume).
- **Last-resort cost control:** if monthly spend exceeds budget, `just loonvault-destroy` the entire
  backend stack. Re-apply (`just loonvault-apply`) only before interviews. Frontend S3 bucket and
  the static site files remain always-on at negligible cost. The shared CMK persists (keys are not destroyed — ~$1/mo at rest).
  IaC makes full restore a single command.

---

## Honest Residual Risks

1. **All data classified as Protected B.** BoC Valet data is publicly available, but for this
   POC it is classified as Protected B financial information — the same classification a
   Canadian financial institution would apply to economic data used in risk and credit
   decisions. The infrastructure was built to match that classification from day one;
   the controls are commensurate, not over-engineered. The data-classification exercise
   is a portfolio artifact documenting the rationale and the governance link between
   classification and control selection.
2. **8 weeks + "some Terraform"** — Phase 0 is the slowest stretch; protect scope ruthlessly.
   The single-source / serverless / no-NAT choices exist to defend this.
3. **RDS 12-month free-tier cliff** — handled by `destroy`/`apply` via IaC.
4. **Single points of failure (by design, budget-constrained):**
   - *Cloudflare:* entire edge layer; outage takes down public API, frontend, and admin plane.
     Production upgrade: origin failover via Route 53 health checks + AWS WAF as second layer.
   - *RDS single-AZ:* AZ failure takes down writes. Production upgrade: Multi-AZ RDS
     (synchronous standby, automatic failover ~60–120s). Note: a read replica helps read
     scaling but requires manual promotion — it is not equivalent to Multi-AZ.
   - *`ca-central-1` region:* full region failure takes down everything. Out of budget scope.
   - *DB auth (RDS IAM):* app DB auth no longer depends on Secrets Manager (ADR-0006) — IAM
     tokens are signed locally, so there is no Secrets Manager cold-start dependency on the
     data path. The IAM control plane (token validation) routes through us-east-1; see below.
5. **us-east-1 dependency:** IAM control plane routes through us-east-1. Mitigated by regional
   STS endpoint. Documented as an infrastructure dependency outside our control.
6. **GitHub Actions supply chain risk:** CI carries no AWS credentials at all, so a
   compromised third-party Action cannot reach AWS infrastructure — but it can still tamper
   with the runner, exfiltrate the `GITHUB_TOKEN`, or poison artifacts. Real precedents: GhostAction (Sep 2025,
   3,325 secrets stolen), tj-actions/changed-files (Mar 2025, 23,000+ repos, AWS keys
   exposed), Trivy-Action (Mar 2026, 10,000+ workflows). Mitigated by pinning all Actions to
   commit SHAs. Residual risk: a zero-day compromise of a pinned SHA is undetectable without
   independent verification (e.g. Sigstore/cosign). Accepted for this POC; production upgrade
   path is dependency review automation and signed Actions verification.

---

## Third-party Sub-service Register

Every new AWS service added to the design is logged here before the decision is finalised.
Triggers: data residency check (SCP covers `ca-central-1`), encryption at rest (CMK required),
audit trail (CloudTrail + alarms). Documented in cloud exit strategy.

| Service | Criticality | Exit path |
|---|---|---|
| AWS Secrets Manager | LOW — holds only the RDS-managed master password; app DB auth uses RDS IAM (ADR-0006), so the data path has no Secrets Manager dependency | `aws secretsmanager get-secret-value --secret-id <name>` → destination system |
| RDS IAM authentication | MEDIUM — app DB connections fail if the IAM/STS control plane is unavailable; token validation routes through us-east-1 (mitigated by regional STS endpoint) | Re-enable password auth + Secrets Manager as documented fallback |
| AWS SQS | MEDIUM — Transform Lambda not triggered if unavailable; messages retained in queue and processed on recovery | Export messages via `aws sqs receive-message`; replay against replacement system |
| AWS S3 (static frontend bucket) | LOW — Cloudflare serves cached responses during an S3 outage; frontend degrades gracefully | `aws s3 sync s3://<frontend-site-bucket>/ ./frontend/` → serve the static files from any CDN or static host |

---

## Stretch Goals (pull in if ahead of schedule)

1. Auto-remediation (mini-SOAR) — first to pull in; turns scenario #6 into a showpiece.
2. Attack scenario #7 (integrity tamper) — earns the integrity framing.
3. Governance slice (data-lake access governance, archetype 2).
4. SBOM generation (SAST via Semgrep and SCA via pip-audit are now core; SBOM output from pip-audit is the remaining stretch item).
5. Post-ingest Cloudflare cache purge — Ingest Lambda calls `POST /zones/{zone_id}/purge_cache` after successful write; eliminates the 1-hour staleness window. Cloudflare API token (`cache_purge:edit` only) in SSM. Pull in if same-hour staleness is unacceptable.
