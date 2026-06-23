# A lean static frontend, rendered from repo Markdown, hosted on S3 behind Cloudflare

The always-on frontend is built as a **lean, hand-written static site** (HTML/CSS/JS, no
framework, no npm toolchain). Its content pages (everything except the landing page) are authored
as **Markdown sourced from the repo's own docs** and rendered to static HTML **at build time**. It
is hosted on **S3 static website hosting** in `ca-central-1` with **Cloudflare** in front, and uses
**self-hosted JetBrains Mono** for a minimalist monospace look. This reverses `plan.md`'s original
"Next.js/TypeScript static site" decision.

**Why lean static, not Next.js.** The frontend is a *content* site — a project summary, a security
posture page, a compliance page, and one small live-data panel. It does not need a component
framework, a router, SSR, or a hydration runtime. Choosing Next.js would add an npm/TypeScript
toolchain and a JavaScript dependency tree — which is also a **software-composition-analysis surface**
(`npm audit`, Dependabot for npm, supply-chain risk) that this project would then have to secure and
maintain, for no functional gain. Two project facts settle it: the goal is to **finish the PoC
quickly**, and the stated preference is **native/built-in over frameworks**. Plain static files have
zero build dependencies, are trivially auditable ("view source"), and host anywhere.

**Content comes from the repo's Markdown, rendered at build time.** The canonical content already
lives as Markdown in the repo (`docs/threat-model.md`, `policies/COMPLIANCE.md`, ADRs). Hand-copying
that into HTML would guarantee drift. Instead, the content pages are thin Markdown files under
`frontend/content/` that **transclude named sections** of the canonical docs (e.g. *"include
`docs/threat-model.md` § Threat Actor Profiles"*), plus a little web framing. A small native build
script (`just build-frontend`) resolves the includes, extracts the named sections, and renders them
to static HTML with a shared template; `just deploy-frontend` then syncs the output to S3. So the
**content is single-source-of-truth from the repo** (no drift), but each page is *shaped* for the web
(curated sections, a table of contents, native `<details>` for depth, styled tables) rather than a
raw document dump. The **landing page stays hand-written HTML** because it carries the custom hero and
the live-data panel.

**Why build-time rendering — not client-side, and not fetching Markdown from GitHub at runtime.**
Two alternatives were considered and rejected:
- *Client-side rendering* (ship HTML shells that `fetch` a `.md` and render it in-browser with a
  Markdown library + sanitizer). Rejected: it adds a JavaScript runtime dependency, weakens the
  Content-Security-Policy (the renderer must be allowed to inject HTML), and leaves the content out of
  the served HTML (worse for "view source" and SEO). For a site whose entire purpose is to present a
  *security posture*, modelling a clean, strict-CSP, minimal-JS static page is part of the message.
- *Fetching Markdown from GitHub at runtime* (`raw.githubusercontent.com`). Rejected for the same
  reason it's tempting — it sounds like "single source of truth," but it makes the public site depend
  on a third party at view time and punches a hole in the CSP. Build-time reading of the **same repo
  Markdown** gives identical single-source-of-truth with none of that runtime coupling.

The objection that this "reintroduces a build step" is acknowledged but minor: what the lean-static
decision was avoiding is a *framework toolchain* (Next.js/npm), not a one-file Markdown-to-HTML
script. A trivial native build step honours the spirit of the decision.

**Assets are self-hosted; no third-party CDNs.** JetBrains Mono is vendored as `.woff2` under
`frontend/assets/fonts/` and loaded via `@font-face` (with a `ui-monospace, …, monospace` fallback) —
not pulled from a font CDN. A security portfolio site should not model a third-party runtime
dependency it doesn't control, and self-hosting keeps the CSP strict and the rendering identical for
every visitor. The theme is deliberately minimalist: monospace throughout, generous whitespace,
hairline borders, a restrained palette.

**Hosting: S3 origin, Cloudflare edge.** The static files live in a public-read S3 bucket configured
for static website hosting (`infra/frontend/site.tf`), with Cloudflare providing DNS, CDN, WAF, DDoS,
and — importantly — **TLS**, because the S3 website endpoint is HTTP-only. Hosting on AWS (rather than
GitHub Pages / Netlify) is deliberate: it keeps the public face *inside* the same architecture being
demonstrated — covered by the region-lock SCP, fronted by the same Cloudflare origin-protection model
as the API, and resilient via the public S3 **snapshots** fallback ([ADR-0004](0004-s3-snapshots-for-frontend-resilience.md)).

**The one piece of JavaScript.** The landing page's live-indicators panel (`frontend/assets/app.js`)
calls the ephemeral API (`GET /series/{code}`) and **falls back to the public S3 snapshots** when the
backend is down (ADR-0004). It is the site's only script, kept external (no inline JS) so a strict CSP
can be applied at the Cloudflare edge.

**Consequences.**
- Reverses the `plan.md` "Next.js/TypeScript" decision (that file is updated to match).
- A small Markdown-to-HTML build step returns; whoever deploys needs a Markdown tool
  (e.g. `python -m markdown` or `pandoc`) available. `deploy-frontend` becomes build-then-sync.
- The deployed artifact is pure static HTML → strict CSP, good "view source"/SEO, no runtime JS
  dependency beyond the single live-data panel.
- Content pages cannot drift from the canonical docs (they *are* the canonical docs, section-sliced).
- The public-read site bucket is a **deliberate exception** to the "no public S3" stance — the same
  exception the OPA storage policy carves out by excluding `infra/frontend` from the plan-gate (see
  `policies/README.md` "Scope"), mirroring the snapshots bucket's SSE-S3 rationale ([ADR-0005](0005-single-cmk-for-phase-1-resources.md)).
- **Implementation phasing:** the initial frontend PR ships the lean static site with hand-written
  HTML content pages; the Markdown-transclusion build step and the JetBrains Mono theme are the agreed
  next increment (this ADR records the decided direction).

**Relationship to existing decisions.** Builds on the ephemeral-backend / always-on-frontend split
([ADR-0007](0007-split-ephemeral-backend-from-always-on-frontend.md)) and the snapshots-resilience
model ([ADR-0004](0004-s3-snapshots-for-frontend-resilience.md)); the public site bucket lives under
the frontend stack alongside snapshots.
