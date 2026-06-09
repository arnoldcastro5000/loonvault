---
title: "Phase 4 — Attack & Defense + blog + polish"
status: open
labels: [ready-for-agent]
created: 2026-06-07
---

## Problem Statement

After Phase 3, LoonVault is fully built, documented, and evidenced — but only to a reader willing to read Terraform code, compliance matrices, and Markdown files. The security controls are real; what is missing is proof that they work under adversarial conditions, visible to a hiring manager who spends 10 minutes on the repo.

Phase 4 answers the question every security interviewer will ask: "Show me." Six attack scenarios must be demonstrably blocked or detected on the live system, with evidence a non-technical reader can follow. The blog post provides the narrative entry point — the document that ties architecture, controls, and demonstrations into a coherent story and surfaces the project through search and professional networks.

Phase 4 builds no new infrastructure. Its deliverables are evidence artefacts and narrative content layered on top of the secure system built in Phases 0–3.

---

## Solution

Phase 4 delivers three parallel workstreams:

**Attack & Defense demonstrations**: execute all six core attack scenarios against the live deployed system, recording the blocked or detected outcome for each. Each scenario is documented with the attacker's goal, the exact tool and command used, the defending control, the evidence artefact, and a blast radius analysis for the case where the control were absent.

**Blog post**: publish a single long-form post tying the project's architecture, threat model, and attack demonstrations together. The target audience is security engineers and hiring managers at Canadian financial institutions. The post is the primary discovery path for the project and the narrative entry point for readers who arrive cold.

**Portfolio polish**: update the README, frontend Home page, and any documentation that changed during Phase 4 to reflect the final state of the project. Ensure all six attack-demo artefacts are committed to `docs/attack-demos/`.

Phase 4 verification gate: all six attack scenarios have a committed evidence artefact; the blog post is published and linked from the README and frontend; Phase 4 understanding gate questions can be answered cold.

---

## User Stories

### Attack & Defense — methodology

1. As the developer, I want a `docs/attack-demos/README.md` documenting the prerequisites, required tools, and reproduction steps for all six scenarios, so that the demonstrations are reproducible by any reviewer with AWS access without tribal knowledge.
2. As the developer, I want each scenario documented with five fields — attacker goal, attack command/tool, defending control, evidence artefact, blast radius if the control were absent — so that the documentation satisfies the Phase 4 understanding gate and doubles as interview preparation material.

### Scenario 1 — API request flood

3. As the developer, I want to demonstrate that flooding `https://api-loonvault.cloudsecuritypractice.com/series/CPI` with concurrent requests produces HTTP 429 responses from Cloudflare before any request reaches API Gateway, so that the edge rate-limit control is evidenced under realistic load.
4. As the developer, I want to demonstrate that requests which pass the Cloudflare rate limit are independently throttled by API Gateway with HTTP 429, so that the two-layer defense-in-depth — edge rate limit and origin throttle — is evidenced and neither layer is a single point of failure for availability protection.
5. As the developer, I want the flood demonstration recorded using `hey` (or equivalent HTTP load tool) showing the per-status-code breakdown of responses, clearly distinguishing which layer returned the 429s, so that the evidence artefact proves both layers are active independently.

### Scenario 2 — SQLi / malicious payload

6. As the developer, I want to demonstrate that a SQL injection payload in the series name path segment (e.g. `'; DROP TABLE series_observations; --`) returns HTTP 403 from Cloudflare WAF before reaching Lambda, so that the edge WAF managed rules are evidenced as the first line of defense against injection.
7. As the developer, I want to demonstrate that sending the same SQLi payload directly to the API Gateway URL (bypassing Cloudflare) does not corrupt the database — the Read Lambda uses parameterized queries — so that the defense-in-depth principle is evidenced: WAF at the edge, parameterized queries at the origin.
8. As the developer, I want both sub-scenarios — WAF block at Cloudflare and parameterized query safety at the origin — captured in a single annotated demonstration that includes a database query confirming no rows were affected, so that the layered SQLi defense is visible end-to-end.

### Scenario 3 — Admin call without credentials

9. As the developer, I want to produce a formal recording of an unauthenticated `POST /admin/refresh/CPI` returning 403 from Cloudflare Access as a committed portfolio artefact, so that the zero-trust admin plane control has permanent evidence beyond the Phase 2 verification gate check.
10. As the developer, I want the recording to include a follow-up showing the same request succeeding with a valid CF Access session, so that the before/after demonstrates the control is a gate rather than a blanket block — the endpoint functions correctly for authorised principals.

### Scenario 4 — OPA/Checkov blocks bad PR (crown jewel)

11. As the developer, I want to demonstrate the OPA pre-push hook blocking a `terraform plan` that opens a security group to `0.0.0.0/0` on port 22, so that the shift-left control is evidenced at the earliest possible point in the pipeline — before the bad change reaches GitHub.
12. As the developer, I want to demonstrate that bypassing the pre-push hook with `--no-verify` on a test branch causes Checkov in GitHub Actions to independently catch the same misconfiguration and fail the CI run, so that the CI backstop layer is evidenced — bypassing the hook does not bypass the pipeline.
13. As the developer, I want the scenario captured as a two-part artefact: a terminal recording showing the OPA hook failure on the local push, and a GitHub Actions screenshot showing the Checkov failure — committed together, so that both blocking layers are visible in the same scenario package.
14. As the developer, I want the scenario documentation to explain how Rego evaluates the SG-to-SG policy rule against the plan JSON, where in the pipeline OPA runs versus Checkov, and what neither tool can catch (post-deploy drift — that is Prowler's responsibility), so that the scenario defence is fully explainable in an interview without notes.

### Scenario 5 — Direct bypass attempts

15. As the developer, I want to demonstrate that a direct `curl` to the raw API Gateway URL without the `X-Origin-Secret` header returns HTTP 403 from the Lambda authorizer, with the full response headers visible, so that the shared-secret origin protection is evidenced at the HTTP level.
16. As the developer, I want to demonstrate that `aws s3 ls s3://loonvault-raw/` returns `AccessDenied`, so that the Block Public Access + bucket policy control is evidenced against a direct S3 access attempt.
17. As the developer, I want to demonstrate that RDS is unreachable from outside the VPC by attempting a direct TCP connection to the RDS endpoint from a machine without VPC access and showing the connection timeout, so that the private subnet network isolation is evidenced at the network layer.
18. As the developer, I want the three sub-scenarios — API GW, S3, RDS — documented as a single "perimeter bypass" scenario showing each entry point is independently hardened, so that the depth of the network isolation story is clear to a reader examining the artefact.

### Scenario 6 — Detection

19. As the developer, I want to demonstrate an end-to-end detection scenario by calling `aws cloudtrail stop-logging` on the live trail, waiting for the SNS alert email within 60 seconds, and immediately calling `aws cloudtrail start-logging` to restore the audit trail, so that the detection pipeline is evidenced with a real CloudTrail event rather than a synthetic test.
20. As the developer, I want to demonstrate the AccessDenied spike detection by triggering 6+ rapid `AccessDenied` events against a resource the calling role cannot access, then confirming the CloudWatch metric filter alarm fires and the SNS email arrives within the alarm period, so that the rate-based detection is evidenced with a realistic credential-enumeration pattern.
21. As the developer, I want both detection demonstrations — CloudTrail-disabled and AccessDenied spike — captured with timestamps showing the event-to-alert latency, so that the responsiveness of the detection pipeline is a concrete metric in the artefact and not just a claim.

### Blast radius analysis

22. As the developer, I want a `docs/attack-demos/blast-radius.md` covering all six scenarios — for each: what an attacker achieves if the control were absent, which compensating layers remain, whether any scenario has no compensating layer (single point of failure), and the production upgrade path — so that the analysis directly answers the Phase 4 understanding gate requirement.
23. As the developer, I want the blast radius analysis to explicitly identify which scenarios are defended by more than one independent layer and which have a single point of failure, so that the honest assessment of residual risk is documented rather than glossed over.

### Blog post

24. As the developer, I want a blog post published covering: the motivation (why a security portfolio, why financial services, why OSFI B-13), the architecture and two-tier data model, the six attack-and-defense demonstrations with evidence, three key design tradeoffs (single account, single-AZ RDS, Cloudflare dependency), and a "what I would do differently in production" section, so that a hiring manager who reads the post has a complete picture of the project without opening the repo.
25. As the developer, I want the blog post to name OSFI B-13 explicitly and explain why it was chosen as the primary framework (governs technology and cyber risk at Canadian FRFIs), and to mention GC Cloud Guardrails as the secondary prescriptive verification layer, so that the financial-services relevance is immediately clear to a hiring manager at a Canadian institution.
26. As the developer, I want the blog post to embed or link to the architecture diagram, the Prowler report, and the OSFI B-13 mapping matrix, so that a reader who wants evidence can navigate directly from the post to the artefact without searching the repo.
27. As the developer, I want the blog post to link to the GitHub repo and the live frontend (`https://loonvault.cloudsecuritypractice.com`), so that the post drives discovery of the full portfolio artefact set.

### Portfolio polish

28. As the developer, I want the README updated to include a direct link to the blog post and inline links to each of the six attack-demo artefacts in `docs/attack-demos/`, so that the repo landing page is the complete navigation hub for the portfolio.
29. As the developer, I want the frontend Home page updated with a "See it in action" section linking to the blog post and the six attack-demo artefacts, so that the always-on frontend is a rich entry point for a hiring manager who arrives via the Cloudflare-proxied URL.
30. As the developer, I want the STRIDE threat model, OSFI mapping, and security controls inventory reviewed for currency and updated if Phase 4 demonstrations revealed any gap or change, so that the portfolio is internally consistent at completion.

### Phase 4 verification gate

31. As the developer, I want all six attack-demo artefacts committed to `docs/attack-demos/` — one evidence file per scenario — and linked from `docs/attack-demos/README.md` and `docs/attack-demos/blast-radius.md`, so that the complete demonstration set is version-controlled alongside the infrastructure.
32. As the developer, I want to confirm I can answer all Phase 4 understanding gate questions from plan.md without notes — attacker goal, exact control, blast radius if absent for each scenario; which scenarios have multiple defensive layers; how OPA Rego evaluates the SG-to-SG policy; what OPA cannot catch — so that the portfolio is interview-ready.
33. As the developer, I want the blog post live and linked from both the README and the frontend Home page, so that the portfolio has a narrative entry point that surfaces through search and professional networks.
34. As the developer, I want all CI gates to pass on the final push, so that the completed portfolio is in a clean, scannable state.

### Optional — Stretch goals (pull in if ahead of schedule)

35. *(Optional)* As the developer, I want to implement the auto-remediation mini-SOAR — an EventBridge rule that detects a security group opened to `0.0.0.0/0` and a remediation Lambda that automatically calls `ec2:RevokeSecurityGroupIngress` to close it — so that scenario #6 becomes a detect-and-respond demonstration rather than detection-only, and the SNS alert reads "detected and auto-remediated."
36. *(Optional)* As the developer, I want to demonstrate attack scenario #7 — an attacker tampers with a raw S3 object and the S3 versioning detects the modification via version comparison — so that the integrity story earns an explicit data-integrity framing in the portfolio.
37. *(Optional)* As the developer, I want to generate an SBOM from pip-audit and commit it to `docs/sbom.json`, so that a software bill of materials is available as a supply-chain transparency artefact alongside the Prowler report.

---

## Implementation Decisions

### Attack tool selection

Each scenario uses the simplest tool that produces unambiguous, reproducible evidence:

- **Scenario 1 (flood)**: `hey -n 500 -c 50 https://api-loonvault.cloudsecuritypractice.com/series/CPI` — Go-based HTTP load tool; prints per-status-code count including 429s, clearly attributable to Cloudflare (CF-RAY header present) vs. API GW (no CF-RAY).
- **Scenario 2 (SQLi)**: `curl -v` with a URL-encoded SQLi payload (`%27%3B%20DROP%20TABLE%20series_observations%3B%20--`). Separate `curl -v` to the raw API GW URL for the parameterized-query sub-scenario. `psql` count query confirming row count is unchanged.
- **Scenario 3 (admin without credentials)**: `curl -X POST https://api-loonvault.cloudsecuritypractice.com/admin/refresh/CPI` (no session cookie → 403 from CF Access); repeated with `Cookie: CF_Authorization=<jwt>` (valid session → 202 from admin Lambda).
- **Scenario 4 (OPA/Checkov)**: a `test/bad-sg-rule` git branch containing a deliberate `aws_security_group_rule` opening `0.0.0.0/0:22`. `git push` triggers the OPA pre-push hook failure locally; `git push --no-verify` triggers Checkov failure in GitHub Actions CI.
- **Scenario 5 (direct bypass)**: `curl -v https://<api-gw-id>.execute-api.ca-central-1.amazonaws.com/series/CPI` (no `X-Origin-Secret` → 403); `aws s3 ls s3://loonvault-raw/` (→ AccessDenied); `nc -zv <rds-endpoint> 5432` from outside VPC (→ timeout).
- **Scenario 6 (detection)**: `aws cloudtrail stop-logging --name loonvault-trail` (→ SNS alert within 60s) immediately followed by `aws cloudtrail start-logging --name loonvault-trail`. AccessDenied spike: `for i in {1..10}; do aws s3 ls s3://loonvault-raw/ 2>&1; done` with a role that lacks `s3:ListBucket`.

### Recording format

Terminal-based scenarios use `asciinema rec` to produce `.cast` files — text-based, exact commands visible, small file size, no re-encoding artefacts. An `.svg` export of each recording is committed alongside the `.cast` for inline GitHub rendering.

Scenarios requiring browser or console evidence (scenario 3 — CF Access 403 page; scenario 4 — GitHub Actions CI failure) use annotated PNG screenshots committed to `docs/attack-demos/`.

### Scenario 4 — `--no-verify` approach

The pre-push hook bypass is executed on the `test/bad-sg-rule` branch only. This branch is created for the demonstration and deleted after the artefact is captured — it is never merged to main. The commit message on the test branch explicitly states its demo purpose. The `--no-verify` bypass is intentional: it exists to demonstrate the CI backstop layer, not to skip safety checks on a real change.

### Scenario 6 — live CloudTrail stop-logging

Stopping the live CloudTrail trail briefly creates a real unlogged window. The stop-logging → receive SNS alert → start-logging sequence should complete in under 30 seconds to minimise exposure. The actual unlogged duration is noted in the scenario artefact as an evidence detail. If the SNS alert has not arrived within 60 seconds, re-enable the trail anyway and investigate the detection pipeline before reattempting.

### Blast radius framing

Each scenario's blast radius entry follows a consistent four-field structure:
- **Control absent**: what the attacker can reach or do
- **Compensating layers**: which other controls remain active
- **Single point of failure**: yes/no — does removing this control leave no alternative defence
- **Production upgrade path**: how the blast radius would shrink in a real deployment

This structure makes the analysis directly usable as interview preparation and maps directly to the Phase 4 understanding gate questions.

### Optional — auto-remediation architecture (story 35)

If the mini-SOAR stretch goal is pulled in:
- New EventBridge rule: pattern matches `AuthorizeSecurityGroupIngress` where source CIDR is `0.0.0.0/0`
- Remediation Lambda: calls `ec2:RevokeSecurityGroupIngress` to remove the offending rule; least-privilege IAM role scoped to the specific security group ARNs
- Lambda logs the revocation to CloudWatch and publishes a second SNS message: "LoonVault: open SG rule detected and auto-remediated"
- This transforms scenario #6 from a pure detection demonstration into a detect-and-respond demonstration — the SNS inbox shows both the alert and the remediation confirmation

### Blog post platform

The blog post platform is the developer's choice (Dev.to, Medium, personal site). The only requirement is that the post is publicly accessible and the URL is stable enough to embed in the README and frontend. The post content is the deliverable; the hosting platform is not specified in this PRD.

---

## Testing Decisions

**What makes a good artefact for Phase 4**: a binary observable outcome — blocked or not, alert received or not. Good evidence shows the exact command, the exact response, and a timestamp. A screenshot of a generic "403 Forbidden" page with no context is insufficient; a `curl -v` output with response headers is. An SNS email with a subject line identifying the rule and a timestamp within 60 seconds of the triggering event is the standard.

### Seam 4 — HTTP API integration tests (established in Phase 1, used for scenarios 2, 3, 5)

The live-stack integration seam from Phase 1 is the basis for scenarios 2, 3, and 5. No new seam is needed; the demonstrations are point-in-time manual executions against the deployed stack.

### Seam 5 — Detection rule verification (established in Phase 3, extended for scenario 6)

Scenario 6 extends the Phase 3 synthetic-event seam: `aws cloudtrail stop-logging` is a real adverse condition rather than a `put-events` injection. The standard (SNS email within 60 seconds) is the same.

### Scenario 4 — shift-left gate verification

- OPA pre-push hook: `conftest test --policy policies/ plan.json` against a plan containing the bad SG rule → policy violation output
- Checkov: `checkov -d .` against the test branch HCL → fails with `CKV_AWS_25` or equivalent
- GitHub Actions: CI run on the test branch shows red at the Checkov step — visible in the Actions tab screenshot

---

## Out of Scope

- **New production infrastructure** — Phase 4 deploys no new AWS resources, except the auto-remediation Lambda if stretch goal 35 is pulled in.
- **Additional Series or Pressure Metrics** — locked by ADR-0001 and Phase 2 scope.
- **Multi-account AWS Organizations** — documented as a production upgrade path; not implemented.
- **Video production or editing** — `asciinema` recordings and annotated screenshots are sufficient; no screen recording software, voiceover, or post-production is required.
- **Ongoing maintenance** — the portfolio is complete at Phase 4; post-interview updates are at the developer's discretion.

---

## Further Notes

- **Backend must be live for scenarios 1, 2, 3, 5, 6**: run `just apply` before the demonstration session; run `just destroy` when done. Phase 4 is the last time `just apply` is needed before interviews — plan to capture all six scenarios in a single session.
- **Test branch hygiene**: `test/bad-sg-rule` must be deleted after the demo artefact is captured. Leaving a branch with deliberately bad IaC in a public repo creates false signal for automated scanners and undermines the portfolio's security credibility.
- **CloudTrail stop-logging window**: minimise the unlogged window — stop, confirm SNS email received, start. Note the actual elapsed time in the artefact. If the alert has not arrived within 60 seconds, re-enable the trail regardless and debug the detection pipeline.
- **Interview readiness test**: before scheduling interviews, walk the architecture diagram cold and name the control at every trust boundary without hesitation. Any boundary that requires a pause to answer is the gap to close. The blast radius analysis document (`docs/attack-demos/blast-radius.md`) is the study guide for this exercise.
- **Phase 4 understanding gate** (from plan.md): for each scenario — attacker goal, exact control, blast radius if absent; which scenarios are multi-layer; how OPA Rego evaluates the SG-to-SG policy; what OPA cannot catch. These must be answerable without notes before the portfolio is considered complete.
