# A lean static frontend with live, same-origin Markdown rendering

The always-on frontend is a **lean, hand-written static site** (HTML/CSS/JS, no framework, no npm
toolchain). A landing page is hand-written HTML; a **docs viewer** renders the repo's canonical
Markdown **live in the browser** — fetched **same-origin** and converted to HTML by a **first-party,
zero-dependency renderer**. It is hosted on **S3 static website hosting** in `ca-central-1` behind
**Cloudflare**, uses **`ui-sans-serif`** as the primary font (monospace, self-hosted JetBrains Mono,
for code only). This reverses `plan.md`'s original "Next.js/TypeScript static site" decision.

> An earlier draft of this ADR proposed *build-time* Markdown→HTML rendering. We pivoted to **live
> client-side rendering** before deploy, to support browsing many docs (this PoC publishes 17) and to
> let content update by re-syncing a `.md` (no HTML rebuild). The security analysis below is why it is
> done **same-origin with a first-party renderer** rather than the obvious React + GitHub-raw shape.

**Why lean static, not Next.js.** The frontend is a *content* site — a project summary, a live
indicators panel, and a viewer over the project's docs. It needs no component framework, router, SSR,
or hydration runtime. Next.js would add an npm/TypeScript toolchain and a dependency tree — which is
also a **software-composition-analysis surface** (`npm audit`, npm Dependabot, supply-chain risk)
this project would then have to secure, for no functional gain. Two project facts settle it: the goal
is to **finish quickly**, and the stated preference is **native/built-in over frameworks**.

**Content is rendered live, in the browser, from same-origin Markdown.** The canonical content lives
as Markdown in the repo (`docs/threat-model.md`, the ADRs, `policies/COMPLIANCE.md`, …). Rather than
copy it into HTML (which drifts) or pre-render it, the `build-frontend` step simply **publishes the
curated `.md` files into the site bucket** alongside a small `manifest.json`. The docs viewer
(`docs.html` + `viewer.js`) fetches the manifest, then fetches the selected `.md` and renders it
client-side. So content updates need only a fast `.md` re-sync — no HTML rebuild — and the viewer
scales to as many docs as the manifest lists.

**Why same-origin, and not fetching Markdown from GitHub at runtime.** Fetching from
`raw.githubusercontent.com` is tempting ("always current") but it makes the public site depend on a
third party *at view time*, widens the CSP (`connect-src` to githubusercontent), leaks visitor
metadata to that third party, and removes content integrity (you can't pin a dynamic fetch with SRI).
**Same-origin** fetch of `.md` deployed with the site keeps a **strict same-origin CSP**, no
third-party runtime dependency, and ships content integrity with the deploy. The cost — content
updates require a re-sync rather than being instant — is acceptable for a portfolio.

**Why a first-party renderer, and not React/`ReactMarkdown` or a vendored Markdown library.** A
client-side Markdown renderer is the one place a content site usually pulls in dependencies (React +
the remark/unified ecosystem, or `marked` + a sanitizer). For a **security** portfolio that is exactly
the wrong signal: it adds a dependency tree to the public face of a project whose thesis is *minimal,
audited attack surface*. Instead the renderer (`assets/md-renderer.js`) is **~150 lines of first-party
vanilla JS with zero dependencies** — nothing to audit, and the strictest CSP (`script-src 'self'`,
no third-party `connect-src`) applies. It is XSS-safe by construction: all text is HTML-escaped, only
a fixed set of tags is emitted, code spans are isolated, and link hrefs are scheme-checked (no
`javascript:`/`data:`). It renders the subset the docs use (headings with anchor ids, lists, GFM pipe
tables, fenced code, blockquotes, inline). The accepted limitation is that exotic Markdown isn't
supported — fine, because we control the source docs.

**Assets are self-hosted; no third-party CDNs.** The body font is the system `ui-sans-serif` stack;
code uses self-hosted JetBrains Mono (OFL-1.1, vendored `.woff2` + license under `assets/fonts/`) — no
font CDN. A security portfolio site should not model a third-party runtime dependency it doesn't
control.

**Hosting: S3 origin, Cloudflare edge.** The static files **and the published `.md` docs** live in a
public-read S3 bucket configured for static website hosting (`infra/frontend/site.tf`), with Cloudflare
providing DNS, CDN, WAF, DDoS and **TLS** (the S3 website endpoint is HTTP-only). Hosting on AWS keeps
the public face *inside* the architecture being demonstrated — covered by the region-lock SCP, fronted
by the same Cloudflare origin-protection model as the API, and resilient via the public S3 snapshots
fallback ([ADR-0004](0004-s3-snapshots-for-frontend-resilience.md)).

**The one piece of stateful JavaScript.** The landing page's live-indicators panel (`assets/app.js`)
calls the ephemeral API (`GET /series/{code}`) and **falls back to the public S3 snapshots** when the
backend is down (ADR-0004). The docs viewer is otherwise just fetch-and-render.

**Consequences.**
- Reverses the `plan.md` "Next.js/TypeScript" decision (that file is updated to match).
- The deployed artifact is static HTML + first-party JS + same-origin `.md` → a strict, demonstrable
  CSP; zero third-party/runtime dependencies; nothing in the public site to `npm audit`.
- Content updates require re-syncing the `.md` to the bucket (`just deploy-frontend`), not a rebuild.
- `build-frontend` (stdlib Python, no pip) assembles `frontend/dist/` (static files + published docs +
  manifest); `frontend/dist/` is git-ignored.
- The public-read site bucket is a **deliberate exception** to the "no public S3" stance — the same
  exception the OPA storage policy carves out by excluding `infra/frontend` from the plan-gate (see
  `policies/README.md` "Scope"), mirroring the snapshots bucket's SSE-S3 rationale ([ADR-0005](0005-single-cmk-for-phase-1-resources.md)).
- The first-party renderer supports only a Markdown subset; the source docs stay within it.

**Relationship to existing decisions.** Builds on the ephemeral-backend / always-on-frontend split
([ADR-0007](0007-split-ephemeral-backend-from-always-on-frontend.md)) and the snapshots-resilience
model ([ADR-0004](0004-s3-snapshots-for-frontend-resilience.md)).
