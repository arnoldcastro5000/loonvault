# LoonVault — STRIDE+DREAD Threat Model

*Version 1.1 · 2026-06-08 · Covers Phases 0–4 architecture*

---

## 1. Purpose and Scope

This document is the authoritative threat model for LoonVault, a bank-grade public API serving Bank of Canada economic indicators. All data — BoC Valet observations, derived Pressure Metrics, and supporting infrastructure configuration — is classified as **Protected B financial information** for this POC.

**In scope:** All runtime components from the Cloudflare edge to RDS Postgres, the ingest pipeline, CI/CD supply chain, developer workstation, and Terraform state.

**Out of scope:** Bank of Canada Valet API (treated as trusted upstream); physical AWS data centre security; Cloudflare internal infrastructure; end-user devices.

**Public posture:** All source code, Terraform configuration, OPA policies, CI/CD pipeline definitions, and documentation — including this document — are published on the project's public GitHub repository. Automated AI-enhanced scanning of the published codebase is anticipated and accepted as part of this security portfolio. All security controls must therefore be **secure by design, not by obscurity** (Kerckhoffs' principle). Publishing the control inventory is a deliberate demonstration that no control relies on an attacker's ignorance of the design. DREAD Discoverability scores throughout this document reflect the fully-public posture.

**Methodology:** STRIDE per component; DREAD for prioritisation. DREAD scores reflect residual risk *given current controls*. Each dimension scored 1–10; final score is the arithmetic mean of the five dimensions.

---

## 2. Threat Actor Profiles

| Code | Profile | Sophistication | Motivation |
|---|---|---|---|
| **OE** | Opportunistic External | Low — automated scanners, credential stuffers | Opportunistic; not targeting LoonVault specifically |
| **TE** | Targeted External | Medium–High — recon, chained exploits | Data theft, disruption, portfolio defacement |
| **SC** | Supply Chain | Medium — compromised dependency or GitHub Action | Persistent access, credential theft |
| **MI** | Malicious Insider / Compromised CI | High — developer credential theft, AI-dev pivot | Infrastructure destruction, data exfiltration |
| **AI** | AI-Enhanced Scanner | High — LLM-powered static analysis of published code at scale | Automated discovery of logic flaws in published Lambda, authorizer, OPA policy, and CI/CD code; dependency CVE matching against published `requirements.txt` / `package.json` |

The **AI** actor is a force-multiplier on OE and TE: published code that would require hours of manual review to audit can be analysed in seconds. The **AI** actor does not introduce new attack *classes* but substantially increases Exploitability and Discoverability for any vulnerability in published code.

---

## 3. Architecture and Trust Boundaries

```
[Public Internet]
      │ TLS 1.3
      ▼
[Cloudflare Edge] — WAF · Rate Limit · DDoS · TLS Full-strict
      │ X-Origin-Secret injected · CF Access JWT (admin)
      ▼
[API Gateway v2] — Lambda Authorizer · Throttling
      │
      ├──▶ [Read Lambda] ──▶ [RDS Postgres / private subnet]
      │         in-VPC              role_reader (SELECT only)
      │
      ├──▶ [Admin Lambda] ──▶ [Ingest Lambda] (triggers)
      │         in-VPC              outside VPC
      │
[EventBridge schedule] ──▶ [Ingest Lambda] ──▶ [S3 Raw Zone]
      outside VPC                               CMK · versioned
                                      │
                                   [SQS+DLQ]
                                      │
                              [Transform Lambda] ──▶ [RDS Postgres]
                                    in-VPC             role_transformer
                                      │
                              [Secrets Manager] ◀── both in-VPC Lambdas
                              [SSM Param Store] ◀── Lambda Authorizer

[GitHub Actions] ── no AWS creds ──▶ static scans only (PUBLIC REPO)
[Developer Terminal] ── IAM Identity Center ──▶ terraform apply / destroy
[Terraform State] ── S3 + DynamoDB lock · CMK encrypted
[Frontend] ── S3 static site (REST endpoint) · ca-central-1 · Cloudflare proxy
```

**Trust boundaries:** Cloudflare edge / API Gateway; VPC perimeter (Ingest Lambda is outside); Lambda execution role boundary; Postgres role boundary; Secrets Manager resource policy boundary; S3 bucket policy boundary.

**What is public:** Lambda code, Terraform modules, OPA policies, GitHub Actions workflows, this threat model, detection rule patterns, DREAD scores, and all control descriptions. **What is not public:** secret values (X-Origin-Secret, DB credential), specific API Gateway URL (changes each `terraform apply`), KMS CMK ARNs (in state, not repo), AWS account ID.

---

## 4. DREAD Scoring Methodology

| Dimension | Description |
|---|---|
| **D — Damage** | Severity of harm if exploited (data loss, outage, compliance breach) |
| **R — Reproducibility** | How reliably can the attack be repeated |
| **E — Exploitability** | Skill and resources required to execute |
| **A — Affected Users** | Breadth of impact across users and data |
| **Di — Discoverability** | How easily an attacker can find or recognise the vulnerability |

**Availability scoring basis:** financial-grade — scored as if the API were always-on production, not ephemeral demo.

**Discoverability baseline:** Because all code and documentation are public, the minimum Di for any threat touching published code is **6**. Threats that depend solely on runtime secrets or unguessable values retain lower Di scores — the secret value itself is not published even though the SSM path or code that uses it is.

**Severity thresholds (average of 5 dimensions):**

| Range | Severity |
|---|---|
| 8.0 – 10.0 | Critical |
| 6.0 – 7.9 | **High** |
| 4.0 – 5.9 | Medium |
| 1.0 – 3.9 | Low |

---

## 5. Threat Catalogue

### 5.1 Cloudflare Edge

| ID | Cat | Threat | TA | D | R | E | A | Di | Score | Sev |
|---|---|---|---|---|---|---|---|---|---|---|
| T-001 | D | Volumetric DDoS exhausts Cloudflare capacity, API and frontend unavailable | OE TE | 8 | 7 | 5 | 9 | 9 | **7.6** | High |
| T-002 | I | X-Origin-Secret token exfiltrated; Cloudflare WAF and rate-limit bypassed | TE MI | 8 | 6 | 5 | 8 | 6 | **6.6** | High |
| T-003 | S | CF Access JWT stolen via phishing/session hijack; admin plane accessed | TE | 9 | 3 | 4 | 2 | 5 | **4.6** | Medium |
| T-004 | D | Cloudflare service outage (SPOF) — API, frontend, and admin plane all down | — | 9 | 3 | 1 | 9 | 6 | **5.6** | Medium |
| T-005 | I | Cache bypass rule misconfigured — admin 403 or response served from edge cache | OE TE | 6 | 3 | 3 | 4 | 3 | **3.8** | Low |

**Mitigating controls:** Cloudflare DDoS automatic mitigation; rate limiting rules; TLS Full-strict; CF Access Zero-Trust + MFA for admin routes; CF Access JWT validated independently at origin; cache bypass rule on `/admin/*`; X-Origin-Secret stored in SSM (value not published), rotated on schedule.

**Gap — T-002:** SSM Parameter Store type for `X-Origin-Secret` not specified as SecureString in the design. If stored as Standard String, any principal with `ssm:GetParameter` can read it in plaintext. The SSM parameter *path* is visible in published Terraform — an attacker with any foothold knows exactly what to target. Must be SecureString (KMS-encrypted). Di raised to 6 from 4 to reflect published SSM path.

---

### 5.2 API Gateway and Lambda Authorizer

| ID | Cat | Threat | TA | D | R | E | A | Di | Score | Sev |
|---|---|---|---|---|---|---|---|---|---|---|
| T-006 | S | Raw API Gateway URL discovered; requests bypass Cloudflare WAF and rate limiting | OE TE | 6 | 7 | 5 | 7 | 5 | **6.0** | High |
| T-007 | T | SQL injection payload in path parameter exploits Lambda query construction | OE TE AI | 9 | 4 | 3 | 9 | 8 | **6.6** | High |
| T-008 | E | Lambda authorizer path-routing logic flaw — edge case grants admin access without CF Access JWT | TE AI | 9 | 3 | 4 | 2 | 8 | **5.2** | Medium |
| T-009 | I | 5xx error responses leak Lambda ARNs, stack traces, or DB schema detail | OE TE | 5 | 8 | 4 | 5 | 7 | **5.8** | Medium |

**Mitigating controls:** Lambda authorizer rejects requests missing `X-Origin-Secret` (returns 403); API Gateway throttling (burst + rate limits); Cloudflare WAF managed rules (SQLi); Read Lambda uses parameterised queries (`psycopg2`); authorizer validates CF Access JWT (signature, expiry, issuer) on `/admin/*`.

**Gap — T-006:** API Gateway URL is technically discoverable via DNS recon or leaked in error messages. The Lambda authorizer is the only barrier once the URL is known — WAF, rate limiting, and DDoS protection are all bypassed. Mitigation: enforce a least-privilege API GW resource policy restricting invocation to Cloudflare IP ranges as a secondary control.

**Gap — T-008:** Di raised to 8 from 5. The Lambda authorizer routing logic is published Python code. An AI-enhanced scanner can analyse every path-normalisation edge case (URL encoding, trailing slash, case variants) in seconds. Correctness of the authorizer is the only defence — it must be verified by unit tests covering all edge cases for admin path detection.

**Gap — T-009:** No explicit requirement for error sanitisation in Lambda response handlers. Semgrep catches some patterns but a generic exception handler returning `str(e)` would leak internals. Requirement should be explicit in Lambda coding standards.

---

### 5.3 Ingest Lambda (outside VPC)

| ID | Cat | Threat | TA | D | R | E | A | Di | Score | Sev |
|---|---|---|---|---|---|---|---|---|---|---|
| T-010 | T | Supply chain compromise of Ingest Lambda Python dependencies (`requests`, `boto3`) | SC | 8 | 3 | 4 | 7 | 5 | **5.4** | Medium |
| T-011 | T | Compromised Ingest Lambda writes poisoned Protected B data to S3 raw zone | SC MI | 7 | 4 | 4 | 7 | 4 | **5.2** | Medium |
| T-012 | I | Ingest Lambda internet access exploited to beacon credentials or exfiltrate env vars | TE SC | 5 | 3 | 4 | 3 | 4 | **3.8** | Low |

**Mitigating controls:** pip-audit + Socket.dev + Dependency Review in CI; SHA-pinned GitHub Actions; Semgrep SAST; Ingest Lambda IAM restricted to `s3:PutObject` + `kms:GenerateDataKey` only (cannot read back data, reach RDS, or call STS); S3 versioning preserves prior objects; DLQ isolates bad transforms.

---

### 5.4 Transform Lambda (in-VPC)

| ID | Cat | Threat | TA | D | R | E | A | Di | Score | Sev |
|---|---|---|---|---|---|---|---|---|---|---|
| T-013 | I | Compromised role_transformer reads entire Protected B series_observations table | TE MI | 8 | 3 | 4 | 7 | 3 | **5.0** | Medium |
| T-014 | T | Crafted SQS message references malicious S3 key, triggers corrupted DB write | TE | 7 | 3 | 4 | 7 | 4 | **5.0** | Medium |
| T-015 | I | Transform Lambda accidentally logs DB credential value to CloudWatch Logs | MI | 8 | 3 | 3 | 5 | 4 | **4.6** | Medium |
| T-016 | D | DLQ overflow from sustained poison-pill messages silently halts pipeline | OE TE | 6 | 6 | 5 | 7 | 5 | **5.8** | Medium |

**Mitigating controls:** SQS resource policy limits producers to S3 raw-zone bucket only; role_transformer scoped to `INSERT`/`UPDATE`/`SELECT` on `series_observations` only (no `DELETE`, `DROP`, `TRUNCATE`); VPC network isolation; Secrets Manager SDK caching (credential not fetched on every invocation); Semgrep SAST (detects accidental logging patterns).

**Gap — T-016:** No CloudWatch alarm on DLQ depth. A sustained bad-message injection fills the DLQ silently — the pipeline stalls but no alert fires. A `ApproximateNumberOfMessagesVisible` alarm on the DLQ is absent from the detection pipeline design.

---

### 5.5 Read Lambda (in-VPC)

| ID | Cat | Threat | TA | D | R | E | A | Di | Score | Sev |
|---|---|---|---|---|---|---|---|---|---|---|
| T-017 | D | Sustained parallel requests exhaust Lambda concurrency; API unavailable | OE TE | 7 | 7 | 6 | 9 | 7 | **7.2** | High |
| T-018 | E | Compromised Read Lambda role retrieves DB credential from Secrets Manager | TE MI | 7 | 3 | 4 | 7 | 3 | **4.8** | Medium |
| T-019 | R | Public API has no per-caller identity; all reads are anonymous and non-attributable | OE TE | 4 | 9 | 9 | 5 | 7 | **6.8** | High |
| T-020 | I | Protected B data returned to callers who bypass Cloudflare WAF via known API GW URL | TE | 6 | 6 | 5 | 8 | 5 | **6.0** | High |

**Mitigating controls:** API Gateway throttling (burst + rate limits); Cloudflare rate limiting; Lambda authorizer (403 without origin secret); role_reader restricted to `SELECT` on `series_observations` only; Secrets Manager resource policy restricts `GetSecretValue` to Read Lambda and Transform Lambda ARNs only; VPC network isolation.

**Gap — T-017:** No reserved concurrency configured on the Read Lambda. An uncapped Lambda can consume the entire account-level concurrency budget (1,000 by default), starving all other Lambdas including the Transform Lambda. Reserved concurrency would cap the blast radius of a flood that bypasses API GW throttling.

**Gap — T-019:** Inherent in the design — the public API intentionally has no authentication. Caller identity is limited to Cloudflare IP-level attribution. Individual query attribution is not possible. For a Protected B system in production, API key issuance or caller tokens would be required. Documented as an accepted design tradeoff.

---

### 5.6 Admin Lambda (in-VPC)

| ID | Cat | Threat | TA | D | R | E | A | Di | Score | Sev |
|---|---|---|---|---|---|---|---|---|---|---|
| T-021 | S | Valid CF Access JWT replayed after session expiry window or from different client | TE | 9 | 3 | 3 | 2 | 5 | **4.4** | Medium |
| T-022 | D | Authenticated admin makes rapid refresh requests, flooding Ingest Lambda invocations | MI | 6 | 3 | 2 | 6 | 4 | **4.2** | Medium |
| T-023 | R | Admin action not attributed if CF Access JWT email extraction is not implemented | MI | 5 | 4 | 4 | 2 | 3 | **3.6** | Low |

**Mitigating controls:** Lambda authorizer validates CF Access JWT (signature, expiry, issuer) on every admin request; admin Lambda logs requesting email from JWT on every invocation; admin Lambda IAM restricted to `lambda:InvokeFunction` on Ingest Lambda ARN only; CF Access MFA requirement inherently rate-limits authenticated sessions; CloudTrail Lambda Invoke data events capture all invocations.

---

### 5.7 RDS Postgres (private subnet)

| ID | Cat | Threat | TA | D | R | E | A | Di | Score | Sev |
|---|---|---|---|---|---|---|---|---|---|---|
| T-024 | T | MITM on Lambda-to-RDS TLS connection intercepts Protected B data in transit | TE | 8 | 2 | 3 | 8 | 3 | **4.8** | Medium |
| T-025 | E | SQL privilege escalation from role_reader or role_transformer to Postgres superuser | TE AI | 9 | 2 | 3 | 8 | 6 | **5.6** | Medium |
| T-026 | T | Compromised role_transformer UPDATEs series_observations rows with bogus values | TE MI | 7 | 3 | 4 | 8 | 3 | **5.0** | Medium |
| T-027 | I | RDS automated snapshot shared outside account or not covered by CMK key policy | TE MI | 8 | 3 | 4 | 8 | 3 | **5.2** | Medium |
| T-028 | D | Single-AZ RDS instance failure (AZ outage or hardware fault) takes down write path | — | 8 | 3 | 1 | 9 | 5 | **5.2** | Medium |

**Mitigating controls:** `sslmode=verify-full` + RDS CA bundle in both in-VPC Lambdas; `ssl_min_protocol_version=TLSv1.2` RDS parameter group; role_reader (`SELECT` only) and role_transformer (`SELECT`/`INSERT`/`UPDATE` only) — neither has `DROP`, `TRUNCATE`, `DELETE`, `GRANT`, or `CREATE`; RDS in private subnet with no IGW route; SG-to-SG ingress only (OPA-enforced); CMK encryption at rest; RDS block public accessibility.

**Gap — T-025:** Di raised to 6 from 4. The Postgres role definitions (`role_reader`, `role_transformer`, `role_writer`) and their exact privilege grants are published in documentation. An attacker who gains DB access knows precisely which privilege paths exist. pgaudit (Postgres audit logging) is not configured — DB-level DML operations are not attributed beyond Lambda-invocation-level CloudTrail.

**Gap — T-027:** RDS automated snapshot sharing policy not explicitly specified in the design. Snapshots inherit CMK encryption but could be shared to another account by a privileged insider. Mitigation: Prowler check to detect public or cross-account snapshot sharing.

---

### 5.8 S3 Raw Zone

| ID | Cat | Threat | TA | D | R | E | A | Di | Score | Sev |
|---|---|---|---|---|---|---|---|---|---|---|
| T-029 | T | Compromised Ingest Lambda role `PutObject`s manipulated data (new version overwrites) | SC MI | 8 | 4 | 5 | 7 | 4 | **5.6** | Medium |
| T-030 | I | Bucket policy misconfiguration exposes raw zone publicly (Block Public Access drift) | MI | 8 | 2 | 2 | 8 | 4 | **4.8** | Medium |
| T-031 | T | S3 versioning disabled via post-deploy drift; historical data permanently overwritten | MI | 7 | 3 | 4 | 7 | 3 | **4.8** | Medium |

**Mitigating controls:** Block Public Access (bucket + account level); bucket policy denies non-VPC-endpoint access; S3 versioning; OPA policy enforces Block Public Access in CI (pre-push + Checkov); Ingest Lambda IAM has only `s3:PutObject` (cannot delete or delete-version); CloudTrail S3 data events on raw zone (GetObject, PutObject); Object Lock is stretch goal.

**Gap — T-029:** Without Object Lock (stretch goal), a compromised Ingest Lambda can `PutObject` a new bad version. Versioning preserves prior versions but the pipeline will process the new bad version until the issue is detected.

**Gap — T-031:** OPA and Checkov enforce versioning at plan time; post-deploy drift (e.g., manually disabling versioning in the console) is Prowler's job. Prowler scan required before portfolio completion.

---

### 5.9 Secrets Manager and KMS

| ID | Cat | Threat | TA | D | R | E | A | Di | Score | Sev |
|---|---|---|---|---|---|---|---|---|---|---|
| T-032 | I | DB credential accidentally placed in Terraform state via regression (e.g., `random_password` reintroduced) | MI | 7 | 2 | 3 | 5 | 3 | **4.0** | Medium |
| T-033 | I | Unauthorized `GetSecretValue` on DB credential secret by compromised principal | TE MI | 8 | 2 | 3 | 6 | 3 | **4.4** | Medium |
| T-034 | D | KMS CMK disabled or scheduled for deletion; all encrypted data (S3, RDS, Secrets Manager) inaccessible | MI | 9 | 2 | 4 | 9 | 3 | **5.4** | Medium |
| T-035 | D | Secrets Manager regional outage prevents Lambda cold starts; API unavailable | — | 7 | 3 | 1 | 9 | 4 | **4.8** | Medium |

**Mitigating controls:** DB password generated directly in Secrets Manager (not `random_password`); Terraform references secret ARN only; Secrets Manager resource policy restricts `GetSecretValue` to Read Lambda and Transform Lambda execution role ARNs; root explicitly denied; CloudWatch alarm on anomalous `GetSecretValue` volume; CloudTrail KMS data events (Decrypt/GenerateDataKey); automatic key rotation annually; CMK deletion requires 7–30 day pending period; SDK-level credential caching (TTL ~1hr) allows warm Lambdas to survive short Secrets Manager outages.

**Gap — T-034:** No EventBridge rule fires specifically on `DisableKey`, `ScheduleKeyDeletion`, or `CancelKeyDeletion` KMS API calls. These should be added to the detection pipeline. Current detection covers IAM policy widening but not CMK lifecycle events.

---

### 5.10 CloudTrail and Detection Pipeline

| ID | Cat | Threat | TA | D | R | E | A | Di | Score | Sev |
|---|---|---|---|---|---|---|---|---|---|---|
| T-036 | R | CloudTrail disabled before attack; audit trail window destroyed | TE MI | 9 | 5 | 4 | 5 | 6 | **5.8** | Medium |
| T-037 | T | CloudTrail log objects deleted or tampered with in log bucket | TE MI | 8 | 2 | 2 | 5 | 3 | **4.0** | Medium |
| T-038 | E | EventBridge detection rules modified or deleted to suppress specific alerts | TE MI | 8 | 3 | 4 | 5 | 7 | **5.4** | Medium |
| T-039 | R | AccessDenied spike CloudWatch alarm misconfigured or metric filter targeting wrong log group | MI | 7 | 4 | 5 | 5 | 4 | **5.0** | Medium |

**Mitigating controls:** EventBridge rule fires on `StopLogging`/`DeleteTrail`/`UpdateTrail` (1 occurrence → SNS); CloudTrail log bucket has deletion-deny policy (`s3:DeleteObject` denied, including root); CloudTrail log file validation detects tampering; CloudTrail management events capture EventBridge rule changes; six detection rules cover the highest-signal events; SNS alerts have confirmed subscriber (email).

**Gap — T-036:** The EventBridge alert fires *after* CloudTrail is disabled — an attacker who disables CloudTrail, acts, then re-enables it has an unlogged window of seconds-to-minutes. This is inherent to detection-based audit trail protection.

**Gap — T-038:** Di raised to 7 from 3. The exact EventBridge rule patterns and all six detection rules are published in this document and in the Terraform code. An attacker can read exactly which CloudTrail event names trigger alerts and which do not. No detection rule fires specifically on `PutRule`, `DeleteRule`, or `DisableRule`. Consider adding EventBridge management events to the detection ruleset.

---

### 5.11 CI/CD Pipeline and Supply Chain

| ID | Cat | Threat | TA | D | R | E | A | Di | Score | Sev |
|---|---|---|---|---|---|---|---|---|---|---|
| T-040 | T | Malicious npm or pip package injected into Lambda or frontend dependencies | SC | 8 | 4 | 5 | 7 | 5 | **5.8** | Medium |
| T-041 | E | Developer IAM Identity Center session stolen via workstation compromise | MI | 9 | 3 | 5 | 7 | 4 | **5.6** | Medium |
| T-042 | T | OPA/Checkov logic gap exploited using published policy knowledge to craft bypassing Terraform | TE AI | 7 | 4 | 5 | 6 | 9 | **6.2** | High |
| T-043 | T | GitHub Actions script injection via untrusted input in `run:` step | SC | 6 | 3 | 3 | 5 | 5 | **4.4** | Medium |

**Mitigating controls:** pip-audit (Python CVEs), `npm audit` (Node CVEs), Socket.dev (supply chain behaviour analysis), Dependency Review (PR-time), Dependabot (daily updates); SHA-pinned Actions (immutable commit SHAs); zizmor (workflow security — script injection, `pull_request_target`); betterleaks + gitleaks + TruffleHog (secret scanning); IAM Identity Center issues short-lived session tokens; devcontainer network-isolated from AWS credentials; OPA + Checkov + tflint + Semgrep in CI; regal lints Rego policies; Semgrep `p/owasp-top-ten` covers injection patterns.

**Gap — T-042:** Di raised to 9 from 4 — the published OPA policies and Checkov configuration fully specify what is and is not blocked. An attacker (or AI-enhanced scanner) can read the exact Rego rules and craft a Terraform configuration that passes every policy check while still introducing a misconfiguration outside the rules' scope. This raises T-042 from Medium to High. Every gap in the OPA rule set is visible to the attacker. Mitigation: regal lints Rego policies for correctness; Prowler catches post-deploy drift that OPA misses; regular policy review as architecture evolves.

**Gap — T-041:** Developer workstation is the single path to `terraform apply`. A compromised workstation with an active Identity Center session gives full infrastructure control. No out-of-band approval or break-glass mechanism exists. Accepted for POC; production upgrade: require a second approver for destructive operations.

---

### 5.12 Terraform State

| ID | Cat | Threat | TA | D | R | E | A | Di | Score | Sev |
|---|---|---|---|---|---|---|---|---|---|---|
| T-044 | I | Terraform state read exposes full infrastructure topology (ARNs, resource IDs, config) | TE MI | 6 | 2 | 3 | 4 | 3 | **3.6** | Low |
| T-045 | T | Terraform state modified to destroy or drift critical resources | MI | 9 | 2 | 4 | 8 | 3 | **5.2** | Medium |

**Mitigating controls:** State bucket CMK-encrypted; access restricted to the developer's IAM Identity Center session (no CI principal has access); Block Public Access; S3 versioning; DynamoDB lock table prevents concurrent modification; CloudTrail S3 data events on state bucket.

---

### 5.13 Frontend S3 Bucket

| ID | Cat | Threat | TA | D | R | E | A | Di | Score | Sev |
|---|---|---|---|---|---|---|---|---|---|---|
| T-046 | T | Frontend static content tampered — defacement or XSS payload injected into pages | TE MI | 7 | 4 | 5 | 5 | 5 | **5.2** | Medium |
| T-047 | D | Frontend S3 bucket unavailable; static site unreachable | — | 5 | 2 | 1 | 6 | 4 | **3.6** | Low |

**Mitigating controls:** Frontend deployed only via `just deploy-frontend` from developer terminal (no CI write access); Cloudflare CDN caches frontend content (1-hour TTL) — site remains available during short S3 outages; Semgrep + ESLint (`eslint-plugin-security`) catch XSS patterns in Next.js components; React's built-in DOM escaping prevents most XSS if no `dangerouslySetInnerHTML` is used; bucket policy grants anonymous read-only `s3:GetObject` with no public write or list (Block Public Access is deliberately *not* enabled on this bucket — unlike the raw-zone and state buckets — because the Cloudflare-proxied REST endpoint requires public object reads); Cloudflare WAF in front.

---

### 5.14 Published Architecture and AI-Enhanced Scanning

These threats arise specifically from the public posture: full code publication combined with AI-enhanced static analysis creates threat vectors that do not exist for a private-code system.

| ID | Cat | Threat | TA | D | R | E | A | Di | Score | Sev |
|---|---|---|---|---|---|---|---|---|---|---|
| T-048 | E | AI-enhanced static analysis of published Lambda authorizer code identifies path-routing edge case; admin access obtained without CF Access JWT | TE AI | 9 | 4 | 6 | 2 | 9 | **6.0** | High |
| T-049 | R | Published detection thresholds enable threshold-evasion attack patterns (e.g., ≤5 AccessDenied errors per 5 min stays below alarm; known blind spots in detection rules exploited) | TE AI | 7 | 8 | 7 | 5 | 9 | **7.2** | High |
| T-050 | I | Published Terraform reveals exact SSM parameter paths; any principal with `ssm:GetParameter` access immediately knows the X-Origin-Secret parameter name without enumeration | TE AI | 6 | 5 | 4 | 7 | 9 | **6.2** | High |
| T-051 | T | Prompt injection via malicious content in a fetched web page, dependency README, or crafted repo file causes the AI development assistant to introduce a subtle security-critical code change (e.g., authorizer bypass condition, weakened OPA rule) that passes human review and CI scans | SC TE | 9 | 4 | 5 | 7 | 6 | **6.2** | High |

**Mitigating controls (T-048):** Lambda authorizer correctness is the sole control — unit tests covering all path-normalisation edge cases (URL encoding, trailing slash, case variants, double slashes) must be comprehensive and form part of the CI gate. Security by design: the authorizer's dual-validation (origin secret + CF Access JWT) means finding one edge case is insufficient — both checks must be bypassed simultaneously for admin access.

**Mitigating controls (T-049):** The published detection thresholds are a known and accepted tradeoff of the public posture. The six detection rules are single-occurrence for high-signal events (root usage, CloudTrail disabled, IAM policy widened, SG changed, no-MFA sign-in) — these cannot be evaded by staying below a threshold. Only the AccessDenied spike (>5 in 5 min) is threshold-based. Mitigation: consider lowering the threshold post-deploy or adding a secondary metric for slower enumeration (e.g., >20 AccessDenied in 30 min). The detection rule configuration intentionally errs toward false positives over false negatives for high-signal events.

**Mitigating controls (T-050):** SSM parameter *paths* are published; the *values* are not. The X-Origin-Secret value is set at runtime and not stored in code or documentation. Mitigation: enforce SecureString type for all SSM parameters containing security-sensitive values (see Gap G-01). Even with the path known, reading a SecureString requires both IAM `ssm:GetParameter` permission and KMS `kms:Decrypt` permission on the parameter's CMK.

**Mitigating controls (T-051):** The devcontainer sandbox restricts what the AI can read (repo scope only — no SSH keys, AWS credentials, or system files) and what it can fetch (network allowlist). AWS credentials are absent from the devcontainer environment entirely, bounding the blast radius of any compromised AI context. All AI-generated code passes the full CI gate before deploy — Semgrep, Checkov, OPA, and regal are agnostic to authorship and will catch misconfigurations regardless of how they were introduced. Developer review of AI-generated diffs is the final human gate before commit. The residual risk is a subtle, semantically plausible change that passes both human review and all static scans — for example, a logic inversion in a boolean guard that is syntactically valid and stylistically normal.

---

## 6. All Threats — Ranked by DREAD Score

| Score | Sev | ID | Cat | Threat |
|---|---|---|---|---|
| **7.6** | High | T-001 | D | Volumetric DDoS exhausts Cloudflare capacity |
| **7.2** | High | T-017 | D | Lambda concurrency exhaustion — API unavailable |
| **7.2** | High | T-049 | R | Published detection thresholds enable threshold-evasion |
| **6.8** | High | T-019 | R | Public API anonymous — reads non-attributable |
| **6.6** | High | T-007 | T | SQL injection via path parameter |
| **6.6** | High | T-002 | I | X-Origin-Secret exfiltrated — Cloudflare bypassed |
| **6.2** | High | T-042 | T | OPA/Checkov gap exploited using published policy knowledge |
| **6.2** | High | T-050 | I | Published SSM paths enable targeted enumeration |
| **6.2** | High | T-051 | T | Prompt injection causes AI to introduce subtle security-critical code change |
| **6.0** | High | T-006 | S | Raw API Gateway URL bypasses Cloudflare |
| **6.0** | High | T-020 | I | Protected B data served without WAF filtering |
| **6.0** | High | T-048 | E | AI analysis of published authorizer code finds edge case |
| **5.8** | Med | T-009 | I | Error responses leak internal details |
| **5.8** | Med | T-016 | D | DLQ overflow halts pipeline (no alarm) |
| **5.8** | Med | T-036 | R | CloudTrail disabled — audit window destroyed |
| **5.8** | Med | T-040 | T | Malicious npm/pip dependency in Lambda |
| **5.6** | Med | T-004 | D | Cloudflare SPOF — all services unavailable |
| **5.6** | Med | T-025 | E | SQL privilege escalation to Postgres superuser |
| **5.6** | Med | T-029 | T | Ingest Lambda overwrites S3 raw objects |
| **5.6** | Med | T-041 | E | Developer workstation → IAM session stolen |
| **5.4** | Med | T-010 | T | Ingest Lambda supply chain compromise |
| **5.4** | Med | T-034 | D | KMS CMK disabled — all encrypted data inaccessible |
| **5.4** | Med | T-038 | E | EventBridge rules suppressed |
| **5.2** | Med | T-008 | E | Lambda authorizer logic flaw → admin access |
| **5.2** | Med | T-011 | T | Ingest Lambda writes poisoned data to S3 |
| **5.2** | Med | T-027 | I | RDS snapshot shared outside account |
| **5.2** | Med | T-028 | D | Single-AZ RDS failure — write path down |
| **5.2** | Med | T-045 | T | Terraform state modified — infrastructure drift |
| **5.2** | Med | T-046 | T | Frontend content tampered — XSS/defacement |
| **5.0** | Med | T-013 | I | Transform role reads all Protected B series data |
| **5.0** | Med | T-014 | T | Crafted SQS message → malicious DB write |
| **5.0** | Med | T-026 | T | role_transformer overwrites series_observations |
| **5.0** | Med | T-039 | R | AccessDenied alarm misconfigured — spike undetected |
| **4.8** | Med | T-018 | E | Read Lambda role → DB credential extracted |
| **4.8** | Med | T-024 | T | MITM on Lambda-to-RDS connection |
| **4.8** | Med | T-030 | I | S3 raw zone exposed publicly (drift) |
| **4.8** | Med | T-031 | T | S3 versioning disabled via drift |
| **4.8** | Med | T-035 | D | Secrets Manager outage blocks cold starts |
| **4.6** | Med | T-003 | S | CF Access JWT stolen — admin plane accessed |
| **4.6** | Med | T-015 | I | Transform Lambda logs DB credential |
| **4.4** | Med | T-021 | S | CF Access JWT replayed |
| **4.4** | Med | T-033 | I | Unauthorized GetSecretValue on DB credential |
| **4.4** | Med | T-043 | T | GitHub Actions script injection |
| **4.2** | Med | T-022 | D | Admin refresh floods Ingest Lambda |
| **4.0** | Med | T-032 | I | DB credential in Terraform state (regression) |
| **4.0** | Med | T-037 | T | CloudTrail logs deleted |
| **3.8** | Low | T-005 | I | Edge cache serves admin response |
| **3.8** | Low | T-012 | I | Ingest Lambda beacons via internet access |
| **3.6** | Low | T-023 | R | Admin action not attributed |
| **3.6** | Low | T-044 | I | Terraform state exposes infrastructure topology |
| **3.6** | Low | T-047 | D | Frontend S3 unavailable |

**Score distribution:** 0 Critical · 12 High · 34 Medium · 5 Low (51 threats)

No Critical findings. The three new threats introduced by the public posture (T-048, T-049, T-050) all score High — they represent genuine elevated risk from publication but are mitigated by the principle that the controls are designed to work even when fully described.

---

## 7. Control Gaps

The following gaps were identified during this analysis. None create a Critical finding given existing compensating controls, but each should be tracked to closure.

| # | Gap | Affected Threats | Priority | Recommended Fix |
|---|---|---|---|---|
| G-01 | SSM Parameter Store type for `X-Origin-Secret` not specified as SecureString | T-002 T-050 | High | Declare as `aws_ssm_parameter` with `type = "SecureString"` and KMS key reference in Terraform |
| G-02 | No reserved concurrency on Read Lambda | T-017 | High | Set `reserved_concurrent_executions` in Lambda Terraform resource; size to expected peak + headroom |
| G-03 | No CloudWatch alarm on SQS DLQ depth | T-016 | Medium | Add `ApproximateNumberOfMessagesVisible > 0` alarm on DLQ → SNS topic |
| G-04 | No detection rule for KMS CMK lifecycle events | T-034 | Medium | Add EventBridge rule matching `DisableKey`, `ScheduleKeyDeletion`, `CancelKeyDeletion` |
| G-05 | No detection rule for EventBridge rule modification | T-038 | Medium | Add EventBridge rule matching `PutRule`, `DeleteRule`, `DisableRule` |
| G-06 | No explicit error sanitisation requirement in Lambda coding standards | T-009 | Medium | Add coding standard: all Lambda handlers must return opaque error messages to callers; internal details logged to CloudWatch only |
| G-07 | No pgaudit (Postgres audit logging) | T-024 T-026 | Medium | Enable pgaudit via RDS parameter group; log DDL and DML for Protected B compliance |
| G-08 | RDS snapshot sharing policy not specified | T-027 | Medium | Add Prowler/AWS Config rule detecting cross-account or public snapshot sharing |
| G-09 | API Gateway access logging not explicitly configured | T-006 T-019 | Medium | Enable API GW access logging to CloudWatch Logs; add log format capturing IP, path, status, latency |
| G-10 | No CloudWatch alarm on Lambda error rate or duration | Multiple | Low | Add alarms on `Errors` and `Duration` metrics per Lambda function |
| G-11 | AccessDenied spike threshold (>5 in 5 min) is published and evadable | T-049 | Medium | Consider a secondary slower-window alarm (e.g., >20 in 30 min) to catch low-and-slow enumeration that stays below the primary threshold |

---

## 8. Residual Risks Accepted

The following risks are known, accepted for this POC, and documented with production upgrade paths.

| Risk | Threats | Rationale | Production Upgrade |
|---|---|---|---|
| **Public architecture posture** — all code, controls, and this threat model are published | T-042 T-048 T-049 T-050 | Intentional portfolio design; demonstrates security by design not obscurity; accepted risk | No architectural change; any production system handling real Protected B data should not publish its full threat model with DREAD scores |
| **Published detection thresholds** — attackers know exact alarm conditions | T-049 | Inherent consequence of public docs; high-signal rules are single-occurrence (not threshold-based); only AccessDenied spike is threshold-based | Omit threshold values from public documentation in production; treat detection configuration as sensitive |
| **Anonymous public API** — no per-caller identity | T-019 | Public data API; API key issuance is out of scope | API key issuance with usage plans in API Gateway; OAuth2 client credentials |
| **Single-AZ RDS** | T-028 | Budget constraint (~$10/mo ceiling) | Multi-AZ RDS (synchronous standby, ~60–120s automatic failover). Note: read replica ≠ Multi-AZ for write resilience |
| **Cloudflare as SPOF** | T-001 T-004 | Entire edge layer; Cloudflare outage takes down API, frontend, and admin plane | Route 53 health checks + origin failover to AWS WAF as second CDN/WAF layer |
| **Single AWS account** | T-041 T-045 | Budget and complexity constraint | Multi-account AWS Organizations: separate accounts for prod, dev, and audit trail |
| **No Object Lock on S3 raw zone** | T-029 T-031 | Stretch goal; versioning alone preserves history | Enable Object Lock in COMPLIANCE mode with a retention period matching Protected B audit requirements |
| **Developer workstation = single apply path** | T-041 | Deliberate design (no CI credentials); workstation compromise = full control | Bastion/jump host with session recording; dual-approval for destructive operations (`terraform destroy`) |
| **SHA-pinned Actions residual supply chain risk** | T-040 | Zero-day compromise of a pinned SHA undetectable without independent verification | Sigstore/cosign for signed Actions verification; SLSA attestations for dependencies |
| **Secrets Manager cold-start gap** | T-035 | Warm Lambdas survive on SDK cache; cold starts during an outage fail | Fallback to SSM Parameter Store for a read-only credential copy; or accept cold-start failure as bounded |

---

## 9. STRIDE Coverage Matrix

The table below confirms at least one threat was modelled per STRIDE category per major component.

| Component | S | T | R | I | D | E |
|---|---|---|---|---|---|---|
| Cloudflare Edge | T-003 | T-005 | — | T-002 | T-001 T-004 | — |
| API Gateway + Authorizer | T-006 | T-007 | — | T-009 | — | T-008 |
| Ingest Lambda | — | T-010 T-011 | — | T-012 | — | — |
| Transform Lambda | — | T-014 | — | T-013 T-015 | T-016 | T-013 |
| Read Lambda | — | — | T-019 | T-020 | T-017 | T-018 |
| Admin Lambda | T-021 | — | T-023 | — | T-022 | — |
| RDS Postgres | — | T-024 T-026 | — | T-027 | T-028 | T-025 |
| S3 Raw Zone | — | T-029 T-031 | — | T-030 | — | — |
| Secrets Manager / KMS | — | — | — | T-032 T-033 | T-034 T-035 | — |
| CloudTrail / Detection | — | T-037 T-038 | T-036 T-039 | — | — | — |
| CI/CD / Supply Chain | T-043 | T-040 T-042 | — | T-044 | — | T-041 |
| Terraform State | — | T-045 | — | T-044 | — | — |
| Frontend S3 | — | T-046 | — | — | T-047 | — |
| Public posture / AI scanning | — | T-042 T-048 T-051 | T-049 | T-050 | — | T-048 |

---

*This document is the Phase 3 deliverable referenced in `plan.md`. Update it whenever the architecture changes. The attack-and-defense demonstrations in Phase 4 (`docs/attack-demos/`) are the live evidence that the mitigating controls listed here actually work. Version history: 1.0 — initial model; 1.1 — updated for public GitHub posture and AI-enhanced scanning threat actor.*
