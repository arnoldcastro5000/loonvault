---
title: "Phase 2 — Breadth"
status: open
labels: [ready-for-agent]
created: 2026-06-07
---

## Problem Statement

After Phase 1, LoonVault serves one Series (CPI) through a secured pipeline. The platform is correct but narrow: a single endpoint returning one indicator is not a meaningful cost-of-living API, and the three Pressure Metrics — the analytically distinctive part of LoonVault's value proposition — do not exist yet. The admin plane is also missing: there is no way to trigger a manual refresh or perform any privileged operation without directly invoking AWS services, which bypasses the audit trail and exposes the raw AWS surface.

The portfolio story is also incomplete at Phase 1: attack scenario #3 (admin call without credentials blocked by Cloudflare Access) cannot be demonstrated, and the Next.js frontend — the always-on face of the project — is not deployed.

---

## Solution

Phase 2 delivers three things in parallel:

**Breadth**: wire all remaining Series (M2, CAD/USD, overnight rate, 10-year and 2-year GoC bond yields, BCPI, bank credit) into the existing ingest pipeline. Extend the Transform Lambda to compute all three Pressure Metrics from stored Series and write them to the same `series_observations` table. Expose all Indicators via `GET /series/{name}` and `GET /pressure-metrics/{name}`.

**Admin plane**: deploy a protected admin Lambda behind Cloudflare Access (Zero-Trust + MFA). Extend the Lambda authorizer to validate both the `X-Origin-Secret` header and the CF Access JWT on admin routes. Wire a `POST /admin/refresh/{series_name}` endpoint for manual ingest triggers.

**Frontend**: deploy the Next.js/TypeScript static site to an S3 bucket (REST endpoint, `ca-central-1`), with Cloudflare providing CDN, WAF, and DDoS in front. Always-on even when the AWS backend is offline.

Phase 2 verification gate: an admin action attempted without a valid CF Access session is blocked; a direct hit on the API Gateway URL (no origin secret) returns 403; all Indicators return real data.

---

## User Stories

### Additional Series

1. As the data pipeline, I want the Ingest Lambda to fetch all configured Series from BoC Valet — CPI, M2, CAD/USD exchange rate, overnight rate, 10-year GoC bond yield, 2-year GoC bond yield, BCPI, and bank credit — on the daily EventBridge schedule, so that all raw data required for the Pressure Metrics is available in S3 and RDS.
2. As the data pipeline, I want the Series list to be configurable via SSM Parameter Store rather than hardcoded in the Lambda, so that a new Series can be added without redeploying the Ingest Lambda.
3. As the data pipeline, I want the Ingest Lambda to fetch each Series sequentially with a short delay between requests, so that LoonVault does not hit undocumented BoC Valet rate limits during bulk ingest.
4. As the data pipeline, I want each Series to be written to its own S3 raw-zone object (keyed by series name and timestamp), so that a failed fetch for one Series does not block or corrupt others and each Series has an independent audit trail in S3.
5. As the data pipeline, I want the Transform Lambda to correctly parse and upsert observations for all Series into `series_observations`, so that every raw Series is queryable by the Read Lambda and available for Pressure Metric computation.
6. As a developer, I want `GET /series/M2`, `GET /series/CAD_USD`, `GET /series/OVERNIGHT_RATE`, `GET /series/BOND_YIELD_10Y`, `GET /series/BOND_YIELD_2Y`, `GET /series/BCPI`, and `GET /series/BANK_CREDIT` to each return a valid JSON response with observations, so that consumers can access any raw Series from LoonVault.

### Pressure Metric computation

7. As the data pipeline, I want the Transform Lambda to compute the Real M2 Pressure Metric (M2 ÷ CPI index) after ingesting any M2 or CPI observation, and upsert the result into `series_observations` under the `real_m2` series name, so that Real M2 is always consistent with the latest stored M2 and CPI values.
8. As the data pipeline, I want the Transform Lambda to compute the Yield Curve Spread Pressure Metric (10-year GoC bond yield minus 2-year GoC bond yield) after ingesting any bond yield observation, and upsert the result into `series_observations` under the `yield_curve_spread` series name, so that the spread is always consistent with the latest stored yield data.
9. As the data pipeline, I want the Transform Lambda to compute the Bank Credit Growth Rate Pressure Metric (month-over-month percentage change in bank credit) after ingesting any bank credit observation, and upsert the result into `series_observations` under the `bank_credit_growth_rate` series name, so that the rate is always consistent with the latest stored bank credit values.
10. As the data pipeline, I want the Transform Lambda to skip Pressure Metric computation for a given date when one or more required input Series have no observation for that date, so that a gap in source data produces no Pressure Metric row rather than an incorrect one.
11. As the data pipeline, I want Pressure Metric computation to use the most recent available observation date shared by all required input Series when dates do not align exactly, so that minor publication-date skew between BoC Valet Series does not produce systematically empty Pressure Metric results.
12. As the data pipeline, I want Pressure Metric rows in `series_observations` to be recomputed (upserted) on each ingest run, so that a corrected upstream Series observation propagates into Pressure Metric values without manual intervention.
13. As a developer, I want `GET /pressure-metrics/real_m2`, `GET /pressure-metrics/yield_curve_spread`, and `GET /pressure-metrics/bank_credit_growth_rate` to each return a valid JSON response with observations, so that consumers can access all three derived economic stress indicators.
14. As a developer, I want the Pressure Metric API response to include a `derived_from` field listing the input Series names, so that a consumer can understand where the computed value comes from without reading the documentation.

### API surface

15. As a developer, I want `GET /series` (no name parameter) to return a list of all available Series names, so that I can discover what raw data is available without reading the documentation.
16. As a developer, I want `GET /pressure-metrics` (no name parameter) to return a list of all available Pressure Metric names, so that I can discover what derived indicators are available.
17. As a developer, I want all Indicator endpoints (`/series/{name}` and `/pressure-metrics/{name}`) to support an optional `?limit=N` query parameter capping the number of observations returned (most recent N), so that clients do not need to paginate a full time series when only the latest values are needed.
18. As a developer, I want the API to return HTTP 404 with a consistent error shape for any unknown Series or Pressure Metric name, so that the error contract is the same across both path prefixes.
19. As a developer, I want the API to return appropriate CORS headers on all public endpoints, so that the Next.js frontend and any third-party browser client can call it without cross-origin errors.

### Postgres role upgrade

20. As the platform, I want a `role_transformer` Postgres role added to RDS with `SELECT`, `INSERT`, and `UPDATE` on `series_observations`, so that the Transform Lambda can read back stored Series observations to compute Pressure Metrics within a single database connection — without requiring a separate read connection or relaxing the `role_writer` definition.
21. As the platform, I want the Transform Lambda updated to connect as `role_transformer` instead of `role_writer` from Phase 2 onward, so that Pressure Metric computation has the read access it needs while the role change is explicitly tracked.
22. As the platform, I want `role_writer` retained (not dropped) for any future Lambda that needs write-only access without read, so that the least-privilege role vocabulary remains usable as the system grows.

### Lambda authorizer upgrade

23. As the platform, I want the Lambda authorizer to distinguish public routes (`/series/*`, `/pressure-metrics/*`) from admin routes (`/admin/*`) and apply different validation logic per route, so that the public API remains accessible without a CF Access session while the admin plane is fully protected.
24. As the platform, I want the Lambda authorizer to validate the CF Access JWT on all admin routes by fetching Cloudflare's public keys from the team's Access certs endpoint and verifying the JWT signature, expiry, and issuer, so that a forged or replayed CF Access token is rejected at the origin.
25. As the platform, I want the Lambda authorizer to cache the CF Access public keys in Lambda memory (with a TTL), so that a cold-start key fetch does not add latency to every admin request and a Cloudflare key rotation is picked up within the cache TTL.
26. As the platform, I want the Lambda authorizer to require both a valid `X-Origin-Secret` header and a valid CF Access JWT for all admin routes, so that neither control alone is sufficient — an attacker who obtains the origin secret still cannot reach the admin Lambda without a valid CF Access session.
27. As the platform, I want the admin's email extracted from the validated CF Access JWT to be passed to the admin Lambda as a request context field, so that every admin action is attributable to a specific identity in CloudWatch Logs.

### Admin Lambda

28. As the platform administrator, I want a `POST /admin/refresh/{series_name}` endpoint that triggers an immediate Ingest Lambda invocation for the specified Series, so that I can recover from a missed daily run or force a refresh without waiting 24 hours.
29. As the platform administrator, I want the admin Lambda to reject refresh requests for unknown Series names with HTTP 400, so that typos in the series name do not silently trigger a no-op invocation.
30. As the platform administrator, I want every admin Lambda invocation to log the requesting admin's email (from the CF Access JWT), the action performed, and the outcome to CloudWatch Logs, so that the admin audit trail is complete and attributable.
31. As the platform administrator, I want the admin Lambda's IAM execution role restricted to `lambda:InvokeFunction` on the Ingest Lambda ARN only, so that a compromised admin Lambda cannot reach any other AWS resource.
32. As the platform, I want the admin Lambda deployed inside the VPC alongside the Read and Transform Lambdas, so that it is not reachable from the public internet except through API Gateway → Lambda authorizer → admin Lambda.

### Cloudflare Access

33. As the platform administrator, I want Cloudflare Access configured to protect all `/admin/*` routes with a Zero-Trust policy requiring a verified email in the allow list and MFA, so that admin operations cannot be reached by anyone who does not hold a valid, MFA-backed CF Access session.
34. As the platform administrator, I want the CF Access policy's allow list restricted to my own email address, so that no other identity can authenticate to the admin plane even if they have Cloudflare credentials.
35. As the platform, I want Cloudflare Access configured to issue a JWT on successful authentication that the Lambda authorizer can verify using Cloudflare's published public keys, so that the Zero-Trust session proof travels with the request all the way to the origin.
36. As the platform, I want Cloudflare Access managed in Terraform alongside all other Cloudflare resources, so that access policy changes go through CI gates and are version-controlled.
37. As the platform, I want a Cloudflare Cache Rule that explicitly bypasses caching for all `/admin/*` routes, so that admin responses — including 403s from Cloudflare Access on unauthenticated requests — are never served stale from the edge cache.
38. As the developer, I want to demonstrate attack scenario #3 — an admin API call attempted without a valid CF Access session is blocked before reaching the origin — with a live recording, so that the identity control is evidenced in the portfolio.

### Next.js frontend

39. As a Canadian consumer, I want a Data Analysis section showing the current value and most recent observation date for every Indicator (all Series and all Pressure Metrics), so that I can see key economic pressure signals at a glance without calling the API directly.
40. As a Canadian consumer, I want each Indicator displayed with a human-readable label and a brief description of what it measures, so that the data is interpretable without an economics background.
41. As a Canadian consumer, I want the Data Analysis section to display a "data unavailable" state gracefully when the AWS backend is offline (e.g. after `terraform destroy`), so that the rest of the site remains fully usable — Home, Posture, Compliance, and the GitHub link are always-on independently of the backend.
42. As a Canadian consumer, I want the frontend to show the Pressure Metrics visually distinguished from raw Series, so that I can understand at a glance which indicators are derived vs. directly from the Bank of Canada.
43. As the developer, I want the Next.js site structured with five nav sections — **Home**, **Data Analysis**, **Posture** (Threat Model + Security Controls sub-pages), **Compliance** (OSFI + GC Cloud Guardrails sub-pages), and a **GitHub** external link — so that Phase 3 documentation content slots into the Posture and Compliance sections without restructuring the site.
44. As the developer, I want the Next.js frontend built with `output: 'export'` producing per-route `.html` files, so that each page is directly addressable on the S3 REST endpoint without routing workarounds.
45. As the developer, I want `just deploy-frontend` to build and sync the static output to the S3 bucket (`ca-central-1`, REST endpoint), so that the site is hosted on AWS without CloudFront or any intermediate CDN layer beyond Cloudflare.
46. As the developer, I want Cloudflare DNS for `loonvault.cloudsecuritypractice.com` pointing to the S3 REST endpoint with the Cloudflare proxy enabled, so that Cloudflare provides CDN caching, WAF, and DDoS protection in front of the S3 origin.
47. As the developer, I want the frontend to call the public API at `https://api-loonvault.cloudsecuritypractice.com` (not the raw API Gateway URL), so that all API traffic from the frontend passes through Cloudflare WAF and rate limiting.
48. As the developer, I want the frontend to be always-on even when the AWS backend stack is destroyed, so that the portfolio URL — including the documentation section — remains live between interview windows at negligible cost.
49. As the developer, I want the documentation section to display a "content coming in Phase 3" placeholder in Phase 2, so that the site structure and navigation are verified working before the documentation content is written.
50. As the developer, I want `npm audit` to run in GitHub Actions on every push against the frontend `package.json`, so that vulnerable Next.js or React dependencies are caught in CI alongside pip-audit for the Python dependencies.

### Phase 2 verification gate

51. As the developer, I want to demonstrate that an admin API call without a valid CF Access session returns a 403 from Cloudflare Access before the request reaches API Gateway, so that attack scenario #3 is evidenced end-to-end.
52. As the developer, I want all three Pressure Metrics to return real computed values from `GET /pressure-metrics/{name}`, so that the two-tier data model is verified working end-to-end with live BoC Valet data.
53. As the developer, I want all CI gates (`just --fmt --check`, Checkov, betterleaks, Semgrep, pip-audit, `npm audit`, Ruff, ESLint, tflint, regal, actionlint, Socket.dev, zizmor, Dependency Review, `terraform validate`) to pass on every push and PR, and the pre-push OPA/Conftest hook to pass against the Phase 2 `terraform plan` output, so that the new infrastructure, updated IAM roles, and all Python and TypeScript code are verified clean before `just apply` is run from the terminal.

---

## Implementation Decisions

### Lambda runtime (unchanged from Phase 1)

All Lambdas remain Python. The admin Lambda introduced in Phase 2 follows the same pattern: boto3 for AWS SDK calls (`lambda:InvokeFunction`), no Postgres connection. No new runtime dependencies are introduced in Phase 2.

### Pressure Metric computation placement

Pressure Metrics are computed inside the Transform Lambda at ingest time and stored in `series_observations` alongside raw Series rows — not computed at read time in the Read Lambda. This was decided in the platform PRD and is locked: it means the Read Lambda queries RDS for both Series and Pressure Metrics identically, and the computation cost is paid once at ingest, not on every read.

The Transform Lambda queries the `series_observations` table for all required input Series observations for the relevant date range after upserting the newly ingested Series observation, then computes and upserts each affected Pressure Metric. This requires `SELECT` access, which is why `role_transformer` replaces `role_writer` for the Transform Lambda in Phase 2.

### Date alignment strategy for Pressure Metrics

BoC Valet Series are not always published on the same calendar date. Real M2 requires M2 and CPI; both are monthly but may lag by different amounts. The strategy: for each Pressure Metric, find the most recent date on which all required input Series have an observation, compute for that date, and upsert. If no such date exists, skip. This is evaluated on every ingest run, so Pressure Metric observations catch up as each required Series arrives.

### `series_observations` schema — no changes needed

The table schema established in Phase 1 (`series_name`, `observation_date`, `value`, `ingested_at`, primary key `(series_name, observation_date)`) accommodates Pressure Metric rows without modification. Pressure Metric rows use canonical names (`real_m2`, `yield_curve_spread`, `bank_credit_growth_rate`) as `series_name`. The upsert semantics are identical to Series rows.

### API contract additions

**`GET /series`**
```
{ "series": ["CPI", "M2", "CAD_USD", "OVERNIGHT_RATE", "BOND_YIELD_10Y", "BOND_YIELD_2Y", "BCPI", "BANK_CREDIT"] }
```

**`GET /pressure-metrics`**
```
{ "pressure_metrics": ["real_m2", "yield_curve_spread", "bank_credit_growth_rate"] }
```

**`GET /pressure-metrics/{name}`** — same shape as `GET /series/{name}` with an additional `derived_from` field:
```
{
  "name": "real_m2",
  "derived_from": ["M2", "CPI"],
  "observations": [
    { "date": "YYYY-MM-DD", "value": <number> },
    ...
  ]
}
```

**`POST /admin/refresh/{series_name}`** — admin only (CF Access JWT + origin secret required)
- Request body: empty
- Response (202): `{ "triggered": true, "series_name": "<name>" }`
- Response (400): `{ "error": "unknown series name" }`

### Lambda authorizer routing logic

The authorizer receives the request path from API Gateway context. If the path starts with `/admin/`, it validates both the `X-Origin-Secret` header and the CF Access JWT (signature, expiry, issuer claim matching the configured CF team domain). If the path starts with `/series/` or `/pressure-metrics/`, it validates the `X-Origin-Secret` header only. Any other path returns deny.

The CF Access public keys endpoint (`https://loonvault.cloudflareaccess.com/cdn-cgi/access/certs`) is fetched at Lambda cold start and cached in process memory with a 10-minute TTL. The team domain is stored in SSM Parameter Store alongside the origin secret.

### Cloudflare Access configuration

CF Access application: protects `https://api-loonvault.cloudsecuritypractice.com/admin/*`. Policy type: Allow. Rule: Email matches `<developer email>`. MFA: required (configured as a Cloudflare Access rule requiring a hard-key or TOTP second factor). JWT TTL: 24 hours (Cloudflare default). The `CF-Access-Jwt-Assertion` header is forwarded to origin by Cloudflare automatically on authenticated requests.

The CF Access application and policy are managed in Terraform using the Cloudflare provider, alongside the existing WAF and DNS resources.

### Admin Lambda IAM role

`lambda:InvokeFunction` on the Ingest Lambda ARN only. No S3, no RDS, no Secrets Manager access. The admin Lambda does not connect to the database — it only triggers the Ingest Lambda, which handles its own credential retrieval.

### Next.js frontend on S3

Built with **Next.js/TypeScript** using `output: 'export'`. The export produces per-route `.html` files, each directly addressable as an S3 object key on the REST endpoint — no routing workarounds or Lambda@Edge needed.

**Build and deploy**: `just deploy-frontend` (wraps `npm run build && aws s3 sync out/ s3://loonvault-frontend/`). Run from the developer's local terminal alongside `just apply` — no AWS credentials in GitHub Actions. The S3 bucket is public-read with static website serving disabled; Cloudflare is the only intended entry point.

**TLS**: the S3 REST endpoint (`<bucket>.s3.ca-central-1.amazonaws.com`) serves HTTPS with a valid AWS-issued certificate. This enables Cloudflare Full-strict TLS (Cloudflare → origin must be HTTPS with a valid cert). The S3 website endpoint (HTTP-only) cannot satisfy Full-strict and is not used.

**CDN and security**: Cloudflare DNS points to the S3 REST endpoint with the Cloudflare proxy enabled. Cloudflare provides CDN caching, WAF, DDoS protection, and rate limiting in front of the S3 origin. No CloudFront layer.

**Navigation structure**: five nav sections with a shared header:

- **Home** (Phase 2): static summary of the project, its goals, and outcomes. Always-on, no API calls.
- **Data Analysis** (Phase 2): fetches `GET /series` and `GET /pressure-metrics` to discover available Indicators, then fetches each with `?limit=1` for the latest value. Displays all Indicators with human-readable labels, observation dates, and visual distinction between Series and Pressure Metrics. Degrades gracefully when the backend is offline — shows "data unavailable" rather than a broken page.
- **Posture** (structure Phase 2, content Phase 3): dropdown sub-pages for **Threat Model** and **Security Controls**. Displays "content coming in Phase 3" placeholder in Phase 2. Purely static.
- **Compliance** (structure Phase 2, content Phase 3): dropdown sub-pages for **OSFI** (B-13 / E-23 mapping) and **GC Cloud Guardrails** mapping. Displays placeholder in Phase 2. Purely static.
- **GitHub ↗** (Phase 2): nav item that opens the project repo in a new tab. Not a rendered page.

**npm audit**: `npm audit` runs in GitHub Actions on every push against the frontend `package.json`, catching vulnerable Next.js or React dependencies. This runs without AWS credentials alongside the other static scans.

---

## Testing Decisions

**What makes a good test for Phase 2**: Pressure Metric computation is the most logic-dense new code in this phase and the most likely place for silent correctness bugs. Good tests feed known input Series observations and assert on the exact computed Pressure Metric values — not on whether a database call was made. Date alignment edge cases (missing input Series for a date, lagged publication) must be covered by unit tests because they are invisible in integration tests unless that exact condition is present in live data.

### Seam 1 — OPA/Conftest (established in Phase 0, unchanged)

No new policy rules needed for Phase 2. The existing policies fire on any new IAM roles (admin Lambda execution role must follow least-privilege shape).

### Seam 1c — Semgrep TypeScript/React SAST (first meaningful results in Phase 2)

- `p/typescript` + `p/react` rules fire for the first time when the Next.js frontend code is added
- Key checks: no `dangerouslySetInnerHTML` with unescaped user-controlled content, no `eval()`, no unsafe `postMessage` handling, no prototype pollution patterns
- API response data rendered to the DOM must flow through React's built-in escaping — Semgrep flags any bypass
- Prior art: configured in Phase 0, ran clean through Phase 1 (no TypeScript code). This phase is where these rules become load-bearing.

### Seam 2 — Checkov (established in Phase 0, unchanged)

Fires on Cloudflare Access resources only to the extent the Cloudflare Terraform provider has Checkov rules. No new AWS resource types introduced in Phase 2 beyond the admin Lambda (covered by existing Lambda checks).

### Seam 3 — Lambda handler unit tests (established in Phase 1, extended here)

**Transform Lambda — Pressure Metric computation** (highest priority in Phase 2):
- Given stored M2 and CPI observations for the same date, assert Real M2 is computed correctly (M2 ÷ CPI)
- Given stored 10Y and 2Y bond yield observations for the same date, assert Yield Curve Spread is computed correctly (10Y − 2Y)
- Given stored bank credit observations for two consecutive months, assert Bank Credit Growth Rate is computed correctly (MoM % change)
- Given M2 observation with no CPI for that date, assert no Real M2 row is produced
- Given only one month of bank credit data, assert no Bank Credit Growth Rate row is produced (insufficient history)
- Given corrected upstream M2 value for a past date, assert Real M2 for that date is recomputed on next ingest run

**Lambda authorizer — admin path**:
- Given a valid `X-Origin-Secret` and valid CF Access JWT (signed with test key, correct issuer, not expired), assert allow policy returned
- Given a valid `X-Origin-Secret` and expired CF Access JWT, assert deny policy returned
- Given a valid `X-Origin-Secret` and JWT with wrong issuer, assert deny policy returned
- Given a valid `X-Origin-Secret` and no CF Access JWT header, assert deny policy returned on admin path
- Given a public path (`/series/CPI`) with valid `X-Origin-Secret` and no CF Access JWT, assert allow policy returned (public path requires origin secret only)

**Admin Lambda**:
- Given a valid request for a known series name, assert the Ingest Lambda invoke is triggered and 202 returned
- Given a valid request for an unknown series name, assert 400 returned without invoking the Ingest Lambda

**Read Lambda — extended**:
- Given `GET /pressure-metrics/real_m2` with mock DB result, assert correct JSON shape including `derived_from` field
- Given `GET /pressure-metrics/unknown`, assert 404
- Given `GET /series` (list endpoint), assert all configured series names returned
- Given `GET /pressure-metrics` (list endpoint), assert all three Pressure Metric names returned

Prior art: the Lambda handler unit test pattern established in Phase 1 applies directly. All new Lambda tests follow the same `handler(event, context) → response` interface with SDK boundary mocking.

### Seam 4 — HTTP API integration tests (requires deployed stack, extended here)

- `GET /pressure-metrics/real_m2` returns HTTP 200 with observations and `derived_from: ["M2", "CPI"]`
- `GET /pressure-metrics/yield_curve_spread` returns HTTP 200 with observations including at least one negative value (historical inversion)
- `POST https://api-loonvault.cloudsecuritypractice.com/admin/refresh/CPI` without CF Access session cookie returns 403 from Cloudflare Access before reaching API Gateway
- `POST https://api-loonvault.cloudsecuritypractice.com/admin/refresh/CPI` with valid CF Access session returns 202
- `GET https://api-loonvault.cloudsecuritypractice.com/series` returns all eight Series names

---

## Out of Scope

- **Full detection pipeline** — Phase 3. VPC Flow Logs are already enabled; the five additional detection rules (root usage, no-MFA, IAM widened, SG changed, AccessDenied spike) are not wired in Phase 2.
- **Prowler compliance scan** — Phase 3.
- **STRIDE threat model document** — Phase 3 deliverable.
- **OSFI B-13 / E-23 and GC Cloud Guardrails mapping matrices** — Phase 3 deliverables.
- **Attack demonstration clips** — Phase 4, except scenario #3 (admin without credentials) which is verified in the Phase 2 gate and should be recorded at that point.
- **Blog post** — Phase 4.
- **Auto-remediation mini-SOAR** — stretch goal.
- **Statistics Canada as a data source** — locked out by ADR-0001.
- **Rich frontend beyond MVP dashboard** — the Phase 2 frontend is a minimal always-on display; charts, historical plots, and mobile optimisation are not in scope.

---

## Further Notes

- **Canonical Series names**: the Series names used as `series_name` values in `series_observations` and as URL path segments must be agreed before Phase 2 begins and treated as stable identifiers — changing them later requires a data migration and a breaking API change. Suggested canonical names: `CPI`, `M2`, `CAD_USD`, `OVERNIGHT_RATE`, `BOND_YIELD_10Y`, `BOND_YIELD_2Y`, `BCPI`, `BANK_CREDIT`. Pressure Metric names: `real_m2`, `yield_curve_spread`, `bank_credit_growth_rate`. All lowercase for Pressure Metrics (they are derived, not sourced) and uppercase for Series (they are sourced identifiers matching BoC Valet conventions).
- **BoC Valet series codes**: each canonical Series name maps to a specific BoC Valet series code (e.g. CPI maps to `STATIC_TOTPCPIALLINDX`). These mappings belong in SSM Parameter Store alongside the series list, not hardcoded in the Lambda, so they can be corrected without a redeploy if BoC Valet codes change.
- **Phase 2 understanding gate** (from plan.md): before starting Phase 3, be able to answer without notes — why Zero-Trust (CF Access + MFA) beats network-based admin access; why validating the CF Access JWT at the origin matters and what the shared-secret header alone does not prevent; the three identities in the system (public consumer, privileged admin, machine/IAM role) and how each authenticates; where rate limiting and throttling happen and why defense-in-depth across both Cloudflare and API Gateway matters.
- **Frontend graceful degradation**: the Next.js frontend should detect a non-200 response from the API and display a static "data temporarily unavailable" message rather than a JS error. This is the primary resilience requirement for the always-on frontend when the AWS backend is destroyed between interviews.
- **Frontend S3 bucket**: the public S3 bucket (`ca-central-1`, REST endpoint) and the Next.js static files remain always-on at negligible cost. The AWS backend (Lambda, RDS, API Gateway) is ephemeral; the frontend and its Cloudflare DNS record are not.
