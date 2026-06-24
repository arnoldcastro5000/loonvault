# Origin-protect the static site with a Lambda Function URL behind Cloudflare

The always-on static site is served through a small **AWS Lambda behind a Function URL**, sitting
behind Cloudflare. Cloudflare (the only CDN/WAF/TLS layer) injects the shared origin secret
(`X-Origin-Secret`); the Lambda **validates that header** against an SSM Parameter Store value, reads
the requested object from a now-**private** S3 site bucket via IAM, and returns it with a strict set
of HTTP security headers. This extends the hosting decision in
[ADR-0012](0012-lean-static-frontend-from-markdown.md) and applies the same origin-protection model the
API already uses to the static site.

**Why the static site needs this.** Origin protection forces all traffic through Cloudflare's WAF,
rate-limiting, and DDoS controls and prevents anyone from hitting the origin directly to bypass them.
The project already does this for the API — Cloudflare injects `X-Origin-Secret`, the Lambda authorizer
rejects requests without it (`plan.md`, "Origin protection"). We want the **same control on the static
site**, plus the static site's own response should carry a strict security-header policy (CSP, HSTS,
etc.). Raw S3 can do neither: an S3 bucket policy **cannot condition on an arbitrary request header**,
and S3 cannot attach a site-wide Content-Security-Policy.

**Why a Lambda Function URL, and not CloudFront.** To validate a viewer header you need a piece of
compute in front of S3 that can read it. The obvious AWS answer is CloudFront (+ a CloudFront Function
or Lambda@Edge), but **CloudFront duplicates Cloudflare** — it is itself a CDN, and Cloudflare is
already serving DNS, CDN, WAF, TLS, and DDoS. Running two CDNs for one small static site is redundant.
A **Lambda Function URL** is the leanest AWS-native compute that validates the header *without* adding
a second CDN: Cloudflare remains the sole edge; the Lambda is just a header-gated content server behind
it — structurally identical to Cloudflare → API Gateway/authorizer for the API. It also keeps the
shared secret in **SSM Parameter Store** (read and cached at runtime, rotatable), matching the API —
unlike a CloudFront Function, which has no network access and would have to bake the secret into edge
code.

**Alternatives considered and rejected.**
- *Raw S3 + Cloudflare* (the ADR-0012 status quo) — can't enforce the secret header (S3 can't read it)
  and leaves the bucket public. This is what we're replacing.
- *CloudFront + OAC (+ CloudFront Function / Lambda@Edge)* — works and is AWS-native, but **adds a
  second CDN layer on top of Cloudflare**; rejected as redundant. (CloudFront Functions also can't
  reach SSM, forcing the secret into code; Lambda@Edge is us-east-1-only, versioned, and heavier.)
- *Bucket policy restricted to Cloudflare's published IP ranges (`aws:SourceIp`)* — zero compute and
  achieves origin lock, but it is **not the shared-secret-header mechanism** (so it diverges from the
  API's model) and requires keeping Cloudflare's IP list current. Reasonable, but inconsistent.
- *nginx on a container (e.g. Google Cloud Run)* — moves the public face **off AWS**, splitting the
  architecture across clouds for an AWS security portfolio; rejected (same reasoning as choosing S3 over
  GitHub Pages in ADR-0012).

**How it works.**
```
Cloudflare (DNS · CDN · WAF · TLS · injects X-Origin-Secret)
  → Lambda Function URL (AuthType NONE, HTTPS)
      → validate X-Origin-Secret against SSM (cached in memory) → 403 if missing/wrong
      → GetObject from the PRIVATE S3 site bucket (IAM, least privilege)
      → return with content-type + Cache-Control + strict security headers
```
Cloudflare proxies the site domain to the Function URL with SSL mode `Full (strict)` (the Function URL
presents a valid AWS certificate), so transport is HTTPS end-to-end. The Function URL uses
`AuthType NONE`; the **secret header is the gate** — a direct request to the Function URL without the
header gets a 403, exactly like the API.

**Public-access permissions.** A `NONE` Function URL needs *two* resource-based statements:
`lambda:InvokeFunctionUrl` (auto-created by `aws_lambda_function_url`) **and**, since October 2025,
`lambda:InvokeFunction` (invoked-via-function-url). Missing the second returns AWS's own `403 Forbidden`
*before the handler runs*. The pinned aws provider (5.100) predates the `invoked_via_function_url`
argument, so that second statement is created **out of band** via the runbook — the same pattern as the
SSM origin secret, keeping the provider-version gap out of the Terraform. Public invoke is safe here: the
gate is the in-handler `X-Origin-Secret` check, and a direct invoke with no header returns 403.

**The Cloudflare side is a Worker** (`cloudflare/worker.js`), not a plain Transform Rule. A reverse-proxy
Worker bound to `loonvault.cloudsecuritypractice.com/*` does the edge work in code: it **allowlists the
exact paths/methods** (the site's `/`, `/index.html`, `/docs.html`, `/assets/*`, `/content/*`), enforces
request hygiene (method, body, traversal/encoding, header-size, canonical-host checks), **injects
`X-Origin-Secret`**, rewrites the request to `ORIGIN_HOST` (the Function URL host), and **drops the
inbound `Host` header** so the Function URL receives its own. The secret is a Cloudflare **encrypted
Worker secret** (`ORIGIN_SECRET`), not a plaintext variable. The Worker is committed for version control
but **deployed manually** (copy-paste into the Worker editor — no `wrangler`/CI for the edge). This is a
strict superset of the Transform-Rule approach: same header injection, plus edge-level allowlisting.

**Security headers.** Because the Lambda builds the full response, it serves a strict, app-owned
security-header set on every object: a tight **Content-Security-Policy** (the frontend is first-party,
zero-dependency, same-origin, so `default-src 'self'; script-src 'self'`; no `unsafe-inline`/`-eval`;
no third-party origins), **HSTS**, `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY` /
`frame-ancestors 'none'`, `Referrer-Policy: no-referrer`, and a restrictive `Permissions-Policy`. A
few Function-URL-managed headers (`Content-Length`, `Date`, `Connection`, `Transfer-Encoding`) cannot
be overridden, none of which are security headers. Cloudflare can additionally enforce these at the
edge (defense in depth), but the origin is authoritative.

**Secret handling.** A **dedicated** site origin secret (separate from the API's, for independent blast
radius and rotation) lives in **SSM Parameter Store (SecureString)** — consistent with the API origin
secret. The Lambda reads it at cold start and caches it in memory; rotation means rotating the SSM
value and updating Cloudflare's injected header value (propagation bounded by the cache TTL). The
secret value never lives in code or in the edge.

**Consequences.**
- The **site bucket becomes private** (no public-read; only the Lambda execution role can `GetObject`).
  It now *passes* the OPA storage policy — so `infra/frontend` no longer needs a blanket OPA-gate
  exclusion for the *site* bucket (the **snapshots** bucket stays public and remains the exception).
- A small compute layer enters the always-on path. The Lambda is a ~50-line static-file server
  (path → S3 key, content-type, `Cache-Control`). With Cloudflare caching set via `Cache-Control`, the
  Lambda is invoked only on cache misses, so cost and cold-starts are negligible at PoC traffic.
- Function URL sync responses cap at **6 MB** — fine for this site (HTML/JS/Markdown/woff2 are all far
  smaller).
- End-to-end HTTPS and a strict, verifiable security-header posture — an upgrade over the HTTP-only S3
  website endpoint that `Full (strict)` could not have validated.

**Relationship to existing decisions.** Extends [ADR-0012](0012-lean-static-frontend-from-markdown.md)
(the static site) by replacing its public-S3-website hosting with a private bucket behind a Lambda
Function URL. Mirrors the API origin-protection model (`plan.md`, "Origin protection" — `X-Origin-Secret`
in SSM, validated at the origin). Keeps the always-on / ephemeral split of
[ADR-0007](0007-split-ephemeral-backend-from-always-on-frontend.md): the site Lambda + bucket are
always-on; the backend is unaffected.
