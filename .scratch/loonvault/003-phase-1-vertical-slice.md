---
title: "Phase 1 — Vertical slice"
status: open
labels: [ready-for-agent]
created: 2026-06-07
---

## Problem Statement

Phase 0 delivered a hardened AWS foundation with no application logic in it. Phase 1 delivers the first end-to-end proof that the security controls work on real data: one Series (CPI) flowing from BoC Valet through an encrypted S3 raw-zone, a VPC-resident Transform Lambda, an encrypted RDS Postgres instance, and out through a Cloudflare-protected public `GET` endpoint — all with least-privilege IAM, least-privilege Postgres roles, shared-secret origin protection, and TLS `sslmode=verify-full` at every hop.

Without Phase 1, LoonVault has a secure container with nothing inside it. The security portfolio story requires a live, callable endpoint returning real data so that each control can be demonstrated working against something real.

---

## Solution

Wire the complete ingest-to-read pipeline for a single Series. The Ingest Lambda fetches CPI observations from BoC Valet on a daily EventBridge schedule and writes the raw response as a versioned, CMK-encrypted S3 object. An S3 Event Notification triggers an SQS queue, which drives the Transform Lambda (inside the VPC) to parse the response and write observations to RDS Postgres. The Read Lambda (also inside the VPC) serves `GET /series/{name}` via API Gateway, protected by a Lambda authorizer that validates the `X-Origin-Secret` header injected by Cloudflare. All database connections use `sslmode=verify-full` with the RDS CA bundle. The DB credential lives in Secrets Manager (CMK-encrypted, resource-policy-restricted, SDK-cached).

Phase 1 verification gate: a live `GET /series/CPI` returns real CPI observations as JSON; a direct hit on the API Gateway URL (bypassing Cloudflare) returns 403.

---

## User Stories

### Ingest Lambda

1. As the data pipeline, I want the Ingest Lambda to run on a daily EventBridge schedule, so that CPI observations are refreshed automatically without manual intervention.
2. As the data pipeline, I want the Ingest Lambda to fetch the CPI Series from the BoC Valet API and write the raw response as a JSON object to the S3 raw-zone, so that the source data is preserved exactly as received before any transformation.
3. As the data pipeline, I want each S3 raw-zone object to be encrypted with the S3 CMK and stored with a key that includes the Series name and ingestion timestamp, so that objects are identifiable, independently decryptable, and do not overwrite prior fetches.
4. As the data pipeline, I want the Ingest Lambda to run outside the VPC, so that it can reach the public BoC Valet API without NAT — its trust boundary is IAM only.
5. As the data pipeline, I want the Ingest Lambda to handle BoC Valet API errors (rate limits, timeouts, unexpected response shapes) by logging the error and exiting non-zero, so that EventBridge can be configured to retry and the failure is visible in CloudWatch Logs.
6. As the data pipeline, I want the Ingest Lambda's IAM execution role restricted to `s3:PutObject` on the raw-zone bucket ARN and `kms:GenerateDataKey` on the S3 CMK ARN only, so that a compromised Ingest Lambda cannot read back stored data, touch RDS, or reach Secrets Manager.

### S3 → SQS trigger

7. As the data pipeline, I want the S3 raw-zone bucket to send an event notification to the SQS queue on every `ObjectCreated` event, so that each new raw object automatically triggers a Transform Lambda invocation without polling.
8. As the data pipeline, I want the SQS queue to have a dead-letter queue configured with a maximum receive count, so that a poison-pill message or a repeatedly failing transform does not loop indefinitely and is instead isolated for inspection.
9. As the data pipeline, I want the SQS queue's S3 event notification resource policy to allow only the raw-zone S3 bucket to send messages, so that no other source can inject messages into the transform queue.

### Transform Lambda

10. As the data pipeline, I want the Transform Lambda to be triggered by the SQS queue, so that each raw S3 object is processed exactly once (within SQS delivery guarantees) as it arrives.
11. As the data pipeline, I want the Transform Lambda to read the raw S3 object referenced in the SQS message, parse the BoC Valet JSON response, and upsert each observation (series name, date, value) into the `series_observations` RDS table, so that the Read Lambda always queries from a normalised, queryable store rather than raw JSON.
12. As the data pipeline, I want the Transform Lambda to connect to RDS as the `role_writer` Postgres role, which has `INSERT` and `UPDATE` on `series_observations` only, so that a compromised Transform Lambda cannot read data, drop tables, or access tables it does not own.
13. As the data pipeline, I want the Transform Lambda to connect to RDS with `sslmode=verify-full` using the AWS RDS CA bundle, so that the connection is encrypted and the server certificate is verified — not just encrypted but unverified (`sslmode=require`).
14. As the data pipeline, I want the Transform Lambda to retrieve the DB credential from Secrets Manager with SDK-level caching (TTL ~1 hour), so that warm Lambda invocations do not call Secrets Manager on every execution and the Lambda survives short Secrets Manager outages.
15. As the data pipeline, I want the Transform Lambda to run inside the VPC in a private subnet, reaching S3 via the gateway VPC endpoint and RDS via security group, so that neither S3 nor RDS traffic leaves the AWS network.
16. As the data pipeline, I want the Transform Lambda's IAM execution role restricted to `s3:GetObject` on the raw-zone bucket ARN, `kms:Decrypt` on the S3 CMK ARN, `secretsmanager:GetSecretValue` on the DB credential secret ARN, and `kms:Decrypt` on the Secrets Manager CMK ARN, plus VPC attachment permissions, so that blast radius if the role is compromised is limited to reading raw S3 objects and connecting to RDS as `role_writer`.
17. As the data pipeline, I want a failed SQS message delivery to land in the DLQ after the configured retry count, so that a persistently failing observation does not block subsequent ingest runs.

### RDS Postgres

18. As the platform, I want a `series_observations` table in RDS with columns for series name, observation date, value, and ingested-at timestamp, so that all Series data is stored in a single normalised table queryable by name and date.
19. As the platform, I want a `role_reader` Postgres role with `SELECT` on `series_observations` only, so that the Read Lambda cannot write, delete, or access tables outside its scope.
20. As the platform, I want a `role_writer` Postgres role with `INSERT` and `UPDATE` on `series_observations` only, so that the Transform Lambda cannot read data back, drop tables, or access tables outside its scope.
21. As the platform, I want neither `role_reader` nor `role_writer` to have `DROP`, `TRUNCATE`, `DELETE`, or `CREATE` privileges, so that a compromised Lambda execution role cannot destroy or restructure the database.
22. As the platform, I want RDS to enforce TLS 1.2 as the minimum protocol via the `ssl_min_protocol_version=TLSv1.2` RDS parameter group setting, so that a downgrade attack inside the VPC cannot strip encryption from the Lambda-to-RDS connection.
23. As the platform, I want RDS deployed in a private subnet with no route to an internet gateway, accessible only via security group from the Transform Lambda SG and Read Lambda SG, so that the database has no network path to the public internet.
24. As the platform, I want the RDS security group ingress rule to reference the Lambda security groups (SG-to-SG), not CIDR blocks, so that only the specific Lambda functions can reach RDS regardless of IP address changes.

### Secrets Manager

25. As the platform, I want the DB credential stored in Secrets Manager encrypted with the Secrets Manager CMK, so that the credential is protected at rest with a key independent of the S3 and RDS CMKs.
26. As the platform, I want the Secrets Manager secret's resource policy to restrict `GetSecretValue` to the Read Lambda and Transform Lambda execution role ARNs only, explicitly denying all other principals including root, so that credential access is enforced at the resource level not just IAM.
27. As the platform, I want automatic rotation enabled on the DB credential secret, so that the credential's validity window is bounded without manual rotation.
28. As the platform, I want the DB password generated directly in Secrets Manager (not via `random_password` in Terraform), so that the plaintext credential never appears in Terraform state.

### Read Lambda and API Gateway

29. As a developer, I want to call `GET /series/{name}` and receive a JSON response containing the Series name and an array of observations (date + value), so that I can consume CPI data without building a BoC Valet client.
30. As a developer, I want the API to return HTTP 404 with a meaningful error message when I request a Series name that does not exist in the database, so that I can distinguish a bad request from a server error.
31. As a developer, I want the API to return HTTP 200 with an empty observations array when a known Series has no stored observations yet, so that the client can handle a freshly bootstrapped system gracefully.
32. As a developer, I want the API to include CORS headers in its responses, so that I can call it from a browser-based frontend.
33. As the platform, I want the Read Lambda to connect to RDS as `role_reader` with `sslmode=verify-full`, so that read-path database access is least-privilege and encrypted with server certificate verification.
34. As the platform, I want the Read Lambda to retrieve the DB credential from Secrets Manager with SDK-level caching (TTL ~1 hour), so that warm Lambda invocations do not call Secrets Manager on every read request.
35. As the platform, I want the Read Lambda's IAM execution role restricted to `secretsmanager:GetSecretValue` on the DB credential secret ARN and `kms:Decrypt` on the Secrets Manager CMK ARN, plus VPC attachment permissions, so that the blast radius of a compromised Read Lambda is limited to read-only DB access on public data with no path to S3, IAM, STS, or the raw zone.
36. As the platform, I want a Lambda authorizer on the API Gateway that rejects any request missing the correct `X-Origin-Secret` header with HTTP 403, so that callers who discover the raw API Gateway URL and bypass Cloudflare are denied at the origin.
37. As the platform, I want API Gateway throttling configured (burst and rate limits), so that a caller who reaches the origin directly cannot overwhelm the Read Lambda even if the Cloudflare rate limit is bypassed.
38. As the platform, I want the `X-Origin-Secret` token stored in SSM Parameter Store (not hardcoded), so that it can be rotated without redeploying the Lambda authorizer.

### Cloudflare

39. As the platform, I want `api-loonvault.cloudsecuritypractice.com` proxied through Cloudflare with TLS Full-strict mode, so that the connection from the client to Cloudflare is TLS-terminated at the edge and Cloudflare verifies the origin certificate — not just encrypted to Cloudflare with plaintext onward.
40. As the platform, I want Cloudflare WAF managed rules enabled on `api-loonvault.cloudsecuritypractice.com`, so that common attack patterns (SQLi, XSS, known bad IPs) are filtered at the edge before reaching API Gateway.
41. As the platform, I want Cloudflare rate limiting configured on `api-loonvault.cloudsecuritypractice.com`, so that a single IP cannot flood the origin with requests even without volumetric DDoS.
42. As the platform, I want Cloudflare to inject the `X-Origin-Secret` header on every proxied request, so that the Lambda authorizer can verify the request passed through Cloudflare without requiring client-side configuration.
43. As the platform, I want Cloudflare DNS records and WAF configuration managed in Terraform, so that Cloudflare configuration is version-controlled and goes through the same CI gates as AWS infrastructure.
44. As the platform, I want a Cloudflare Cache Rule applied to `/series/*` and `/pressure-metrics/*` with a 1-hour TTL and query string included in the cache key, so that repeated reads of the same endpoint are served from Cloudflare's edge without hitting the origin Lambda and RDS — reducing latency and backend load. BoC Valet publishes daily; a 1-hour TTL is safe without requiring active cache invalidation.
44a. *(Optional)* As the data pipeline, I want the Ingest Lambda to call the Cloudflare Cache Purge API (`POST /zones/{zone_id}/purge_cache` with prefix `api-loonvault.cloudsecuritypractice.com/series/` and `api-loonvault.cloudsecuritypractice.com/pressure-metrics/`) after a successful ingest run, so that edge caches are invalidated immediately after new data is written — eliminating the 1-hour staleness window. The Cloudflare Zone ID and a scoped API token (`cache_purge:edit` permission only) are stored in SSM Parameter Store. Pull in if the 1-hour TTL proves unacceptable.

### VPC and networking

45. As the platform, I want a VPC with private subnets in at least one availability zone for the Transform Lambda, Read Lambda, and RDS, so that no application component has a direct route to the internet gateway.
46. As the platform, I want an S3 gateway VPC endpoint attached to the private subnet route tables, so that the Transform Lambda can reach S3 without traffic leaving the AWS network and without requiring a NAT gateway.
47. As the platform, I want separate security groups for the Transform Lambda, Read Lambda, and RDS instance — with RDS ingress referencing Lambda SGs directly — so that the network topology enforces least-privilege access at the connection level, not just the IAM level.
48. As the platform, I want VPC Flow Logs enabled, so that network-level anomalies (unexpected inter-SG traffic, attempted RDS access from outside the VPC) are captured for the detection pipeline in Phase 3.

### Phase 1 verification gate

49. As the developer, I want a live `GET https://api-loonvault.cloudsecuritypractice.com/series/CPI` to return a valid JSON response with real CPI observations, so that the end-to-end pipeline is verified working against real data.
50. As the developer, I want a direct `GET` to the API Gateway URL (bypassing Cloudflare, without the `X-Origin-Secret` header) to return HTTP 403, so that the origin-protection control is verified working.
51. As the developer, I want all CI gates (`just --fmt --check`, Checkov, betterleaks, Semgrep, pip-audit, `npm audit`, Ruff, ESLint, tflint, regal, actionlint, Socket.dev, zizmor, Dependency Review, `terraform validate`) to pass on every push and PR, and the pre-push OPA/Conftest hook to pass against the Phase 1 `terraform plan` output, so that the new VPC, RDS, Lambda, and API Gateway resources and the first Lambda code are free of known misconfigurations and vulnerabilities before `just apply` is run from the terminal.

---

## Implementation Decisions

### Which Series for Phase 1

CPI (Consumer Price Index) is the single Series wired in Phase 1. It is the most foundational indicator for LoonVault's cost-of-living framing, widely understood, and required as an input to the Real M2 Pressure Metric in Phase 2. All other Series and all Pressure Metrics are Phase 2.

### RDS schema

One table, `series_observations`, serves both Series (Phase 1) and Pressure Metrics (Phase 2). The schema is wide enough for Phase 2 from the start so the Transform Lambda schema migration is not a Phase 2 blocker:

- `series_name` (text, not null) — the canonical Series or Pressure Metric name (e.g. `"CPI"`, `"real_m2"`)
- `observation_date` (date, not null) — the BoC Valet observation date
- `value` (numeric, not null) — the observed or computed value
- `ingested_at` (timestamptz, not null, default now()) — when the row was written
- Primary key: `(series_name, observation_date)` — upsert on conflict

`role_reader` has `SELECT` on this table. `role_writer` has `INSERT` and `UPDATE` on this table. No other privileges for either role.

### API contract

`GET /series/{name}` — name is the canonical Series name (case-insensitive match against `series_name`).

Response (HTTP 200):
```
{
  "name": "<canonical series name>",
  "observations": [
    { "date": "YYYY-MM-DD", "value": <number> },
    ...
  ]
}
```
Observations are ordered by date ascending. Empty array is a valid response (not 404) when the Series exists but has no stored observations. HTTP 404 when `name` does not match any known Series. HTTP 403 when `X-Origin-Secret` is missing or incorrect (returned by the Lambda authorizer before the Read Lambda is invoked).

The `/series` path prefix is chosen to remain consistent with the Phase 2 `/series/{name}` and `/pressure-metrics/{name}` surface — both are Indicators, served from different path prefixes that reflect the two-tier data model (ADR-0002).

### Lambda authorizer

Stateless request-based authorizer (not token-based). Reads `X-Origin-Secret` from the request headers, compares against the value fetched from SSM Parameter Store (cached in Lambda memory for the process lifetime). Returns IAM allow policy on match, deny on mismatch — API Gateway returns 403 on deny. Phase 1 authorizer handles the public path only; the admin path authorizer (which also validates the CF Access JWT) is Phase 2.

### Ingest Lambda BoC Valet integration

The Ingest Lambda calls the BoC Valet REST API for the CPI series and writes the full response body as a single JSON object to S3. The S3 key format is `{series_name}/{YYYY}/{MM}/{DD}T{HH}Z.json`. The Transform Lambda's S3 event handler reads the key from the SQS message's S3 event record to fetch and parse the object. No intermediate transformation in the Ingest Lambda — raw in, raw out.

### DB credential lifecycle

Password is generated directly in Secrets Manager via the AWS console or CLI before `terraform apply` — Terraform references the secret ARN only, never the value. This ensures the plaintext credential never appears in Terraform state. Automatic rotation is enabled; the rotation Lambda (AWS-managed for Postgres) is configured as part of the Secrets Manager module.

### TLS to RDS

Both the Transform Lambda and Read Lambda connect to RDS with `sslmode=verify-full`. The AWS RDS CA bundle (`rds-ca-2019` or the current regional bundle) must be bundled into each Lambda deployment package or fetched at cold start. This verifies the server certificate and prevents a MITM attack inside the VPC — `sslmode=require` encrypts but does not verify, which is insufficient.

### Lambda runtime

All four Lambdas (Ingest, Transform, Read, Lambda authorizer) are implemented in **Python**. Key dependencies: `boto3` (AWS SDK — S3, Secrets Manager, SSM, SQS), `psycopg2-binary` (Postgres), `requests` (BoC Valet HTTP fetch). The RDS CA bundle is bundled into each in-VPC Lambda deployment package rather than fetched at cold start, removing a runtime outbound dependency. Python was chosen over Go for conciseness given the simple glue-code nature of each Lambda, and over Node.js for boto3's maturity and the availability of psycopg2 for Postgres.

### VPC design

Single AZ for Phase 1 (budget constraint — Multi-AZ RDS is a production upgrade path documented in plan.md). One private subnet for RDS, one private subnet for in-VPC Lambdas (Transform + Read). Ingest Lambda has no VPC attachment. S3 gateway endpoint attached to the private subnet route table. No NAT gateway — no interface VPC endpoints. VPC Flow Logs to CloudWatch Logs (same 2-year retention as other log groups).

### Cloudflare Terraform provider

Cloudflare resources (DNS record, WAF ruleset, rate limit rule, Cache Rules, Transform Rules) are managed in the same Terraform repo as AWS resources, using the Cloudflare provider. The `X-Origin-Secret` token is stored in SSM Parameter Store; Cloudflare Transform Rules inject it as a request header. Token rotation: update SSM, redeploy the Lambda authorizer to flush the cached value, update the Cloudflare Transform Rule — documented in the runbook.

**Cache Rules**: a single Cache Rule matches `/series/*` and `/pressure-metrics/*` with Edge TTL of 1 hour and `Cache Key > Query String > Include All`. The admin cache bypass (`/admin/*`) is added in Phase 2 when admin routes are introduced.

**Optional — post-ingest cache purge** (story 44a): if active invalidation is pulled in, the Ingest Lambda calls `POST /zones/{zone_id}/purge_cache` with the two API prefixes after a successful write. The Cloudflare Zone ID and a scoped API token (`cache_purge:edit` only — no other Cloudflare permissions) are stored in SSM Parameter Store alongside the origin secret. The Lambda's existing IAM role needs `ssm:GetParameter` on those two additional SSM paths. This replaces passive TTL expiry with immediate invalidation — the only scenario where it matters is a same-hour re-ingest (manual refresh or DLQ replay).

---

## Testing Decisions

**What makes a good test for Phase 1**: a good test asserts on the observable contract at the highest available seam — the HTTP response shape for the Read Lambda, the SQS message processing outcome for the Transform Lambda — not on internal SDK calls or database query strings. Mock at the AWS SDK boundary, not deeper.

### Seam 1 — OPA/Conftest policy evaluation (no AWS required, established in Phase 0)

Now additionally asserts on Phase 1 resources:
- RDS instance has `storage_encrypted = true` with a CMK (not the default AWS-managed key)
- No security group has a CIDR-based ingress rule (Phase 0 policy, now fires on VPC/Lambda/RDS SGs)
- No public subnet route table has a route to an internet gateway

### Seam 1b — Semgrep SAST (no AWS required, first meaningful Python results in Phase 1)

- `semgrep --config p/python --config p/owasp-top-ten --config p/typescript --config p/react` on every push
- First meaningful Python results here: Ingest Lambda (HTTP fetch), Transform Lambda (DB writes), Read Lambda (DB reads), Lambda authorizer (header parsing)
- Key Python checks: no SQL string interpolation (parameterised queries only), no `subprocess.call(shell=True)`, no hardcoded credentials, no use of weak hash functions
- TypeScript/React rules (`p/typescript` + `p/react`) are configured but return clean in Phase 1 — no frontend code yet. First meaningful TypeScript results in Phase 2.
- Prior art: configured in Phase 0, runs clean until Lambda code is added here

### Seam 1c — pip-audit SCA (no AWS required, first meaningful results in Phase 1)

- `pip-audit -r requirements.txt` on every push
- Scans boto3, psycopg2-binary, requests and all transitive dependencies against OSV database
- Any critical or high CVE is a CI failure; medium CVEs are reviewed case by case
- Prior art: configured in Phase 0, runs clean until `requirements.txt` is added here

### Seam 2 — Checkov static scan (no AWS required, established in Phase 0)

Now fires on: VPC, subnets, security groups, RDS instance, Lambda functions, API Gateway, SQS queue, Secrets Manager secret. Catches: unencrypted RDS, Lambda environment variable secrets, API Gateway without throttling, SQS without encryption.

### Seam 3 — Lambda handler unit tests (new seam, established in Phase 1)

Test the handler function interface: `handler(event, context) → response`. Mock at the AWS SDK boundary (S3 client, SQS client, Secrets Manager client, RDS connection pool). Do not assert on which SDK methods were called — assert on the output.

**Ingest Lambda**:
- Given a valid BoC Valet API response, assert the handler returns success and would write a correctly keyed S3 object
- Given a BoC Valet API timeout, assert the handler raises an error (so EventBridge retries)

**Transform Lambda**:
- Given a valid SQS event pointing to a valid S3 object with parseable BoC Valet JSON, assert the handler produces the correct list of `(series_name, observation_date, value)` tuples for DB insertion
- Given a malformed S3 object, assert the handler raises an error (so the message goes to the DLQ)

**Read Lambda**:
- Given a valid event for `GET /series/CPI` and a mock DB result, assert the response is HTTP 200 with the correct JSON shape and observation ordering
- Given a valid event for an unknown series name, assert HTTP 404
- Given a valid event with no stored observations, assert HTTP 200 with an empty observations array

**Lambda authorizer**:
- Given a request with the correct `X-Origin-Secret` header, assert the authorizer returns an allow policy
- Given a request with a missing or incorrect header, assert it returns a deny policy

This seam is the prior art for all future Lambda tests in Phase 2 and beyond.

### Seam 4 — HTTP API integration tests (requires deployed stack)

- `GET https://api-loonvault.cloudsecuritypractice.com/series/CPI` returns HTTP 200 with valid JSON and at least one observation
- `GET /series/NONEXISTENT` returns HTTP 404
- Direct `GET` to the API Gateway URL without `X-Origin-Secret` returns HTTP 403
- `GET /series/CPI` with `Origin: https://example.com` returns appropriate CORS headers

Run against ephemeral stack only — not in CI.

---

## Out of Scope

- **Additional Series beyond CPI** — Phase 2 (M2, CAD/USD, overnight rate, bond yields, BCPI). The schema and pipeline are designed to accommodate them; only CPI is wired.
- **Pressure Metrics** — Phase 2. The `series_observations` table schema is wide enough for them from the start, but no Pressure Metric is computed in Phase 1.
- **Admin plane and Cloudflare Access** — Phase 2. The Lambda authorizer in Phase 1 validates the origin secret only; the CF Access JWT validation is not wired.
- **Frontend** — Phase 2 or later. The API is callable from a browser (CORS headers present) but no frontend site is deployed.
- **Full detection pipeline** — Phase 3. VPC Flow Logs are enabled in Phase 1 (low cost, high future value) but detection rules beyond the CloudTrail-disabled alert from Phase 0 are not wired.
- **Pressure Metric RDS table** — out of scope (single `series_observations` table handles both tiers per the schema decision above).
- **Multi-AZ RDS** — budget constraint, documented as production upgrade path.

---

## Further Notes

- **BoC Valet API rate limits**: the Valet API is a public, unauthenticated REST API. It has no published rate limit but is intended for human use. Daily ingest of one Series is well within any reasonable threshold. If additional Series are added in Phase 2, fetch them sequentially with a short delay rather than in parallel.
- **Upsert semantics**: the Transform Lambda uses upsert (INSERT … ON CONFLICT DO UPDATE) on the `(series_name, observation_date)` primary key. This makes the transform idempotent — replaying a message from the DLQ or re-ingesting the same BoC Valet response does not create duplicate rows.
- **Phase 1 understanding gate** (from plan.md): before starting Phase 2, be able to answer without notes — how each Lambda's execution role was scoped; blast radius if the Read Lambda's role is compromised; CMK vs AWS-managed key; what "private subnet" means and how Lambdas reach RDS and S3; trace one request end-to-end from Cloudflare to RDS; why `sslmode=verify-full` matters even inside a private subnet; why Secrets Manager instead of SSM for the DB credential; how the shared-secret header prevents direct API Gateway access.
- **CA bundle packaging**: bundling the RDS CA certificate into the Lambda deployment package is preferred over fetching it at cold start — it avoids an outbound HTTPS call at startup and removes a runtime dependency on the AWS certificate endpoint.
