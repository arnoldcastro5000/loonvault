---
title: "Phase 3 — Detection and docs"
status: open
labels: [ready-for-agent]
created: 2026-06-07
---

## Problem Statement

After Phase 2, LoonVault has a functioning, secured data platform: encrypted storage, least-privilege IAM, TLS at every hop, a protected admin plane, and a shift-left CI pipeline. But the security story is asserted rather than evidenced. Only one detection rule is wired — the Phase 0 CloudTrail-disabled alert that protects the audit trail itself. Five of the six detection signals described in plan.md do not fire. There is no threat model, no OSFI mapping, no incident response plan, and no compliance evidence that a hiring manager can inspect without reading Terraform code.

The frontend's Posture and Compliance sections — the primary entry points for anyone evaluating the project — show placeholder content. The README does not exist. The third-party sub-service register is incomplete. The cloud exit strategy has not been written.

Phase 3 closes the gap between a built system and a documented, evidenced, portfolio-ready artefact.

---

## Solution

Phase 3 delivers two parallel workstreams:

**Detection pipeline**: wire the five remaining detection rules (root account usage, console sign-in without MFA, IAM policy widened, security group rule changed, AccessDenied spike) into the live AWS environment. All six rules are now active. Verify each rule fires against a test event. Add a CloudWatch alarm on anomalous `GetSecretValue` volume as a secondary secrets-exfiltration signal.

**Documentation and evidence**: author every documentation deliverable — STRIDE threat model, security controls inventory, OSFI B-13/E-23 mapping matrix, GC Cloud Guardrails mapping matrix, data classification exercise, incident response plan, cloud exit strategy, third-party sub-service register (finalised), architecture diagram, and README. Run Prowler against the deployed stack, remediate all Critical and High findings, and capture the report as a repo artefact. Populate the frontend Posture and Compliance sections with the authored content.

Phase 3 verification gate: Prowler produces a report with no unacknowledged Critical/High findings; a test event triggers an end-to-end detection alert; all four Posture and Compliance sub-pages have real content.

---

## User Stories

### Detection pipeline — EventBridge rules

1. As the platform, I want an EventBridge rule that sends an SNS alert on any CloudTrail event where `userIdentity.type` is `Root`, so that any use of the root account — expected to be zero — is immediately visible to the developer.
2. As the platform, I want an EventBridge rule that sends an SNS alert on any CloudTrail event where `eventSource` is `signin.amazonaws.com` and `additionalEventData.MFAUsed` is `No`, so that a console sign-in that bypassed MFA is detected within seconds of the event.
3. As the platform, I want an EventBridge rule that sends an SNS alert on any CloudTrail event where `eventName` is one of `PutUserPolicy`, `AttachRolePolicy`, `AttachUserPolicy`, `CreatePolicy`, or `PutRolePolicy`, so that any attempt to widen IAM permissions is caught immediately — including changes made manually in the console.
4. As the platform, I want an EventBridge rule that sends an SNS alert on any CloudTrail event where `eventName` is `AuthorizeSecurityGroupIngress` or `RevokeSecurityGroupIngress`, so that any modification to security group ingress rules — potentially bypassing the OPA-enforced SG-to-SG constraint — is surfaced immediately.
5. As the platform, I want all four EventBridge detection rules (stories 1–4) to use the single existing SNS topic from Phase 0 and to include a distinguishing `detail-type` in the event so that the email alert subject identifies which rule fired, so that the developer does not need to read CloudTrail JSON to triage an alert.

### Detection pipeline — metric filter and secondary alarms

6. As the platform, I want a CloudWatch Logs metric filter on the CloudTrail log group that counts `AccessDenied` errors, with a CloudWatch Alarm triggering an SNS alert when the count exceeds 5 occurrences in a 5-minute window, so that a burst of access-denied responses — the fingerprint of a compromised credential enumerating permissions — is detected as a rate signal rather than a single event.
7. As the platform, I want a CloudWatch Alarm on anomalous `GetSecretValue` call volume on the DB credential secret — alerting when calls from outside the expected Lambda execution role ARNs are recorded in CloudTrail — so that a principal attempting to extract the database credential outside the normal Lambda invocation path is detected.

### SNS and alerting

8. As the developer, I want the SNS topic to have my developer email address subscribed so that all detection alerts arrive in my inbox, and I want the subscription confirmed before the Phase 3 verification gate, so that the alert path is end-to-end verified and not assumed.

### Prowler compliance scanning

9. As the developer, I want Prowler run against the deployed LoonVault stack targeting GC Cloud Guardrails checks and the CIS AWS Foundations Benchmark, so that the controls built for OSFI B-13 are verified against a prescriptive external standard and any gaps surface before the documentation claims compliance.
10. As the developer, I want all Prowler Critical and High findings reviewed and either remediated or explicitly accepted with written justification, so that the portfolio does not assert controls that Prowler contradicts.
11. As the developer, I want the Prowler HTML and JSON output saved to `docs/prowler/` in the repo as a timestamped artefact, so that hiring managers can inspect the raw compliance evidence without needing AWS access.
12. As the developer, I want a summary of Prowler findings (pass/fail counts per check, accepted-risk entries) included on the Compliance > GC Cloud Guardrails page, so that the evidence is surfaced on the frontend without requiring the reader to parse the raw JSON.

### Architecture diagram

13. As the developer, I want an architecture diagram authored in a text-based format (Mermaid) covering all trust boundaries, data flows, security control annotations, and principal identities, so that the diagram is version-controlled alongside the infrastructure and stays in sync as the design evolves.
14. As the developer, I want the architecture diagram exported as an SVG and embedded in the README and on the Home page of the frontend, so that a hiring manager gets a full-system view immediately on landing.

### STRIDE threat model

15. As the developer, I want a STRIDE threat model document authored covering every component in the LoonVault architecture — API Gateway, Lambda authorizer, Ingest/Transform/Read/Admin Lambdas, RDS, S3 raw zone, S3 frontend bucket, Cloudflare edge, Secrets Manager, CloudTrail — with at least one concrete threat per STRIDE category per component, so that the threat model is exhaustive rather than illustrative.
16. As the developer, I want each threat in the STRIDE document to include: the affected component, the threat description, the control that mitigates it, the residual risk if the control were absent, and the detection rule that would surface a successful exploit (where one exists), so that the model demonstrates end-to-end security thinking and not just threat enumeration.
17. As the developer, I want the STRIDE threat model saved to `docs/threat-model.md` in the repo so it is the version-controlled source of truth that the frontend Posture > Threat Model page renders, so that the model can be updated without restructuring the site.

### Security controls inventory

18. As the developer, I want a security controls inventory document authored that lists every control implemented in LoonVault, organised by domain (Identity, Network, Data, Secrets, Detection/Response, Governance/Shift-left, Edge, Account), so that the full control surface is visible in one place.
19. As the developer, I want each control entry in the inventory to include: what it protects, how it is implemented, the OSFI B-13 principle it satisfies, and any GC Cloud Guardrail it covers, so that the inventory doubles as the cross-reference between technical implementation and regulatory obligations — and so that the Posture > Security Controls page and the Compliance pages share a single authoritative source.

### OSFI B-13 / E-23 mapping

20. As the developer, I want a formal OSFI B-13 / E-23 mapping matrix authored covering all three B-13 domains (Governance and Risk Management, Technology Operations and Resilience, Cyber Security) and the E-23 third-party risk requirements, with each row mapping a principle to the specific LoonVault control and evidence pointer (Terraform resource, Prowler check, or artefact), so that the Compliance > OSFI page demonstrates regulatory alignment at the control level rather than by assertion.
21. As the developer, I want the OSFI mapping to explicitly address E-23 third-party risk obligations — including the third-party sub-service register, data residency enforcement via SCP, and the cloud exit strategy — so that the portfolio shows awareness of the July 2025 E-23 effective date and its implications for AWS-hosted financial services.

### GC Cloud Guardrails mapping

22. As the developer, I want a GC Cloud Guardrails mapping document authored covering at minimum GR04, GR05, GR06, GR07, and GR11 — each entry naming the LoonVault control, the Prowler check that verifies it, and the Prowler result from the Phase 3 scan — so that the Compliance > GC Cloud Guardrails page presents machine-verified compliance evidence, not self-assertion.
23. As the developer, I want the GC Cloud Guardrails mapping to include the interview framing for why I built against GC Cloud Guardrails as a secondary verification layer — that it is a prescriptive federal baseline that the OSFI controls satisfy simultaneously, demonstrating compliance breadth — so that the page itself answers the question an interviewer would ask.

### Data classification exercise

24. As the developer, I want a data classification exercise document that classifies all LoonVault data elements (BoC Valet observations, derived Pressure Metrics, DB connection strings, Secrets Manager secrets, API tokens, CloudTrail logs, VPC Flow Logs, Lambda environment variables) as Protected B financial information — and documents the rationale for applying Protected B to publicly available BoC Valet data in a Canadian financial institution context — so that the exercise demonstrates classification-driven security design, not just technical capability.
25. As the developer, I want the data classification document to explicitly map each Protected B classification decision to the control it drives (CMK encryption → data at rest; TLS 1.2 + `sslmode=verify-full` → data in transit; least-privilege Postgres roles → access control; 2-year CloudWatch Logs retention → audit obligations under Protected B), so that the portfolio demonstrates the governance link between classification and control selection.

### Incident response plan

26. As the developer, I want a lightweight incident response plan authored covering the six detection scenarios in plan.md — CloudTrail disabled, no-MFA sign-in, root account usage, IAM policy widened, AccessDenied spike, SG rule changed — with a standard response flow (Detect → Classify → Contain → Eradicate → Recover → Post-incident) for each, so that the portfolio demonstrates operational security awareness alongside the technical build.
27. As the developer, I want the IR plan to document the OSFI B-13 breach notification timeline obligations — including the 72-hour initial notification requirement — and the escalation path from SNS alert to documented incident, so that the compliance section of the portfolio is operationally grounded.
28. As the developer, I want the IR plan to include a "destroy and rebuild" scenario — the steps to execute `just destroy` + `just apply` in response to a confirmed compromise — documenting it as the ultimate containment option for an ephemeral infrastructure stack, so that the portfolio's IaC-first philosophy is reflected in the incident response posture.

### Cloud exit strategy

29. As the developer, I want a cloud exit strategy document authored that covers: a service-by-service migration path for all entries in the third-party sub-service register, the data export procedure for each storage layer (RDS pg_dump, S3 sync, Secrets Manager export), the DNS cut-over procedure, and the estimated migration timeline, so that OSFI E-23 third-party risk obligations for exit planning are explicitly satisfied.
30. As the developer, I want the Secrets Manager export path explicitly documented in the cloud exit strategy — `aws secretsmanager get-secret-value --secret-id <name>` — as called out in plan.md, so that the most operationally sensitive export step is not omitted.
31. As the developer, I want the cloud exit strategy to document the `just destroy` sequence and the order in which resources must be removed (KMS CMKs last, after dependent resources are destroyed) to prevent accidental data loss during an AWS exit, so that the exit is executable by any team member without tribal knowledge.

### Third-party sub-service register (finalise)

32. As the developer, I want every AWS service used in the final LoonVault architecture logged in the third-party sub-service register with criticality classification and exit path, so that the register is complete and accurate at the end of Phase 3.
33. As the developer, I want Cloudflare services (CDN, WAF, Zero-Trust Access) added to the sub-service register with criticality (HIGH — the entire edge layer; outage takes down public API, frontend, and admin plane) and exit path (Route 53 + AWS WAF as replacement, documented as production upgrade path), so that the register covers the non-AWS dependencies as required by OSFI E-23.
34. As the developer, I want the sub-service register to note the data residency implication for each service — whether the SCP enforces `ca-central-1`, whether Cloudflare's processing locations are relevant — so that the register supports the E-23 data residency obligation and not just the exit path.

### README

35. As the developer, I want a README authored at the repo root covering: project overview and goals, architecture summary with the diagram, security features by domain, how to deploy (`just apply` and `just deploy-frontend`), how to destroy (`just destroy`), and a guide to the attack-and-defense demonstrations, so that any hiring manager or technical reviewer can understand the full scope of the project from the repo landing page.
36. As the developer, I want the README to include an honest residual risks section — surfacing the single points of failure (Cloudflare dependency, single-AZ RDS, single account) and the production upgrade path for each — so that the portfolio demonstrates mature security thinking rather than claiming the design is production-complete.

### Frontend content population — Posture section

37. As a hiring manager, I want the Posture > Threat Model page on the frontend to display the STRIDE threat model in full — all components, all threats, controls, and residual risks — so that the security depth of the design is visible without reading `docs/threat-model.md` in the repo.
38. As a hiring manager, I want the Posture > Security Controls page to display the security controls inventory organised by domain, so that I can scan the full control surface in one page and click through to source if I want implementation detail.

### Frontend content population — Compliance section

39. As a hiring manager, I want the Compliance > OSFI page to display the OSFI B-13 / E-23 mapping matrix in full — principles, controls, and evidence pointers — so that the regulatory alignment is visible without domain knowledge of the OSFI standard itself.
40. As a hiring manager, I want the Compliance > GC Cloud Guardrails page to display the GC Cloud Guardrails mapping with Prowler evidence — pass/fail per guardrail, scan timestamp, accepted-risk entries — so that the compliance verification is machine-evidenced and not self-asserted.

### Frontend content population — Home update

41. As a hiring manager, I want the Home page updated with the architecture diagram and a final outcomes summary — what was built, what threats it mitigates, which frameworks it maps to — so that the project's security purpose is immediately clear on the first page visited.

### Phase 3 verification gate

42. As the developer, I want the Prowler scan to complete with a report saved to `docs/prowler/` and no unacknowledged Critical or High findings, so that the compliance claim is machine-evidenced before the Phase 3 build is called complete.
43. As the developer, I want to trigger a test event for each of the five new detection rules and confirm an SNS alert email is received for each within 60 seconds, so that the end-to-end detection path (CloudTrail event → EventBridge → SNS → email) is verified working and not assumed.
44. As the developer, I want all four Posture and Compliance sub-pages (Threat Model, Security Controls, OSFI, GC Cloud Guardrails) to display real authored content (no placeholders), so that the always-on portfolio face is complete before Phase 4 begins.
45. As the developer, I want all CI gates (`just --fmt --check`, Checkov, betterleaks, Semgrep, pip-audit, `npm audit`, Ruff, ESLint, tflint, regal, actionlint, Socket.dev, zizmor, Dependency Review, `terraform validate`) to pass on every push and PR, and the pre-push OPA/Conftest hook to pass against the Phase 3 `terraform plan` output, so that detection rule infrastructure and any TypeScript content changes are verified clean before `just apply` is run from the terminal.

---

## Implementation Decisions

### Detection rules — EventBridge vs CloudWatch metric filter

Five of the six detection rules use EventBridge pattern matching directly against CloudTrail events delivered to the default event bus. This is appropriate for single-occurrence signals: one root login, one no-MFA sign-in, one IAM policy change. The pattern is deterministic — one matching event always produces one SNS publish — and there is no state to manage.

The AccessDenied spike uses a CloudWatch Logs metric filter because EventBridge has no memory across events. Detecting a spike requires counting `AccessDenied` occurrences over a time window, which requires: (1) CloudTrail log delivery to CloudWatch Logs (already configured in Phase 0), (2) a metric filter incrementing a counter on each `AccessDenied` record, (3) a CloudWatch Alarm with a threshold of >5 in 5 minutes, (4) the alarm's action publishing to the SNS topic. EventBridge cannot express this — it would fire on every individual `AccessDenied` event, producing noise rather than signal.

### SNS topic design

A single SNS topic receives all detection alerts. Each EventBridge rule sets the SNS message `Subject` to a distinct string identifying the rule (e.g., "LoonVault: Root account usage detected") so that the email alert is identifiable without reading the JSON body. This avoids topic-per-rule sprawl at the cost of filtering complexity that does not exist at LoonVault's alert volume.

### Detection rule Terraform placement

All five new detection rules (EventBridge + CloudWatch metric filter) are provisioned in a new `detection/` Terraform module. This module depends on the existing `cloudtrail/` module (SNS topic ARN, CloudWatch log group name) and is applied as part of the Phase 3 `terraform apply`. No new IAM roles are required — EventBridge and CloudWatch Alarms publish to SNS using AWS service principals, not execution roles.

### Prowler invocation

Prowler is run from the developer's local terminal using the developer's AWS credentials (same pattern as `terraform apply`). It is not run in GitHub Actions — Prowler requires read-level AWS access across many services (`SecurityHub`, `IAM`, `S3`, `RDS`, `CloudTrail`, etc.) and producing those credentials in CI contradicts the terminal-only apply posture.

Invocation: `just scan` (wraps `prowler aws --checks gc_guardrails cis_level2_aws` or equivalent check suite). Output saved to `docs/prowler/<date>-report.html` and `docs/prowler/<date>-report.json`. The JSON is committed to the repo; the HTML is linked from the Compliance page.

### Documentation authoring and frontend rendering

All documentation artefacts (threat model, security controls inventory, OSFI mapping, GC Cloud Guardrails mapping, data classification, IR plan, cloud exit strategy) are authored as Markdown files under `docs/`. The Next.js frontend renders them as static pages using a Markdown processor (e.g. `next-mdx-remote` or `remark`). This keeps the source of truth in Markdown — readable and diff-able in the repo — and the frontend as a rendered view.

The `docs/` directory is the authoritative source. Updates to documentation are made in `docs/`, and the frontend picks them up on the next `just deploy-frontend`. No content is authored directly in Next.js components.

### Architecture diagram tooling

The architecture diagram is authored in Mermaid (text-based, version-controlled). A Mermaid CLI export (`mmdc`) produces an SVG for embedding in the README and on the Home page. Mermaid source lives in `docs/architecture.mmd`. The exported SVG lives in `docs/architecture.svg`.

Mermaid is chosen over draw.io (XML, poor diffs), Excalidraw (JSON, poor diffs), or a PNG (binary, no diffs). A text-based diagram that evolves with the codebase is stronger portfolio evidence than a static PNG produced once and forgotten.

### Data classification scheme

The Government of Canada Protected classification scheme is used (Unclassified → Protected A → Protected B → Protected C), not a custom scheme. This is deliberate: LoonVault targets financial-services employers in Canada, and using the GC scheme allows the exercise to reference the same framework as OSFI E-23 data categorisation guidance.

Expected classifications: all data elements at Protected B — BoC Valet observations and derived Pressure Metrics (Protected B financial information: publicly available but classified at the level a Canadian financial institution applies to economic data used in risk and credit decisions), DB connection strings and Secrets Manager secrets (Protected B: compromise enables direct data access), CloudTrail logs and VPC Flow Logs (Protected B: reveal infrastructure topology and access patterns), Lambda environment variables (Protected B: contain references to secret ARNs and configuration).

### Incident response plan scope

The IR plan is lightweight and POC-appropriate. It does not attempt to reproduce a full enterprise CSIRT playbook. Scope: six response procedures (one per detection scenario), a breach notification timeline referencing OSFI B-13 Section 5 obligations, and the `terraform destroy` nuclear option. No ticketing system, no RACI, no external communication templates — these are documented as production gaps rather than omitted silently.

### Third-party sub-service register scope

Every AWS service in the architecture is logged: Lambda, RDS, S3 (two buckets — raw zone and frontend), SQS, Secrets Manager, SSM Parameter Store, KMS, API Gateway v2, EventBridge, CloudTrail, CloudWatch (Logs + Alarms), SNS, AWS Organizations, IAM. Cloudflare is logged as a non-AWS third party. GitHub (Actions, repo hosting) is logged for completeness. Each entry includes: criticality (HIGH / MEDIUM / LOW), availability dependency (does the API fail if this service is unavailable?), data residency (`ca-central-1` or global), and exit path.

---

## Testing Decisions

**What makes a good test for Phase 3**: detection rules have a binary observable outcome — either the SNS email arrives within 60 seconds or it does not. Good tests push a synthetic event matching each rule's pattern and assert on the email receipt. Documentation completeness is verified by checklist — each document is reviewed against the content requirements in the user stories. Prowler is its own verification mechanism; a clean Prowler report with no unacknowledged findings is the test.

### Seam 1 — OPA/Conftest (established in Phase 0, unchanged)

No new OPA policies needed for Phase 3. The detection module introduces only EventBridge rules, CloudWatch alarms, and SNS subscriptions — no new S3 buckets, KMS CMKs, or security groups.

### Seam 2 — Checkov (established in Phase 0, unchanged)

Checkov fires on the new `detection/` module resources. Expected: clean pass (EventBridge rules, CloudWatch alarms, and SNS subscriptions have minimal Checkov coverage; any flagged misconfiguration in the SNS topic encryption policy is addressed at this point).

### Seam 5 — Detection rule verification (requires deployed stack, manual)

Each of the five new EventBridge rules is verified by pushing a synthetic test event using `aws events put-events` with a crafted payload that matches the rule's event pattern. The CloudWatch metric filter is verified using `aws cloudwatch set-alarm-state` to force the alarm into `ALARM` state and confirm SNS fires.

| Rule | Test method | Expected outcome |
|---|---|---|
| Root account usage | `put-events` with `userIdentity.type: Root` | SNS email within 60s |
| No-MFA sign-in | `put-events` with `source: aws.signin`, `MFAUsed: No` | SNS email within 60s |
| IAM policy widened | `put-events` with `eventName: AttachRolePolicy` | SNS email within 60s |
| SG rule changed | `put-events` with `eventName: AuthorizeSecurityGroupIngress` | SNS email within 60s |
| AccessDenied spike | `set-alarm-state --state-value ALARM` | SNS email within 60s |

EventBridge `TestEventPattern` is used in development to validate each pattern expression against sample payloads before deploying — this catches pattern syntax errors without requiring live CloudTrail events.

### Seam 6 — Prowler compliance scan (requires deployed stack, manual)

Prowler run produces a report. Pass criteria: zero unacknowledged Critical or High findings. Any finding not remediated must have a written acceptance entry in `docs/prowler/accepted-risks.md` with justification. The Phase 3 gate is blocked until this is satisfied.

### Seam 7 — Documentation completeness review (human, manual)

Each documentation artefact is reviewed against the requirements in the corresponding user story before the Phase 3 gate closes. The review checklist:

- STRIDE document: all components covered, all six STRIDE categories per component, each threat has a control and a residual risk
- OSFI mapping: all B-13 principles present, E-23 section present, each entry has an evidence pointer
- GC Cloud Guardrails: GR04, GR05, GR06, GR07, GR11 covered with Prowler check references
- Data classification: all data elements classified, Protected B delta section present
- IR plan: all six detection scenarios have a procedure, breach notification timeline present
- Cloud exit strategy: Secrets Manager export path present, `just destroy` sequence present
- Third-party register: all services logged, criticality and exit path for each
- README: deployment instructions present, architecture diagram embedded, residual risks section present

---

## Out of Scope

- **Attack-and-defense demonstration clips** — Phase 4. Detection rules are wired and tested with synthetic events in Phase 3; recorded attack demonstrations are Phase 4 work.
- **Blog post** — Phase 4.
- **Auto-remediation (mini-SOAR)** — stretch goal. The IR plan documents `just destroy` as the manual containment option; automated remediation via EventBridge → Lambda is a Phase 4+ stretch.
- **GuardDuty / Security Hub / AWS Config** — short evidence-burst tools only, not core architecture (budget constraint). If enabled for evidence gathering, disable after screenshot capture.
- **S3 Object Lock** — stretch goal from plan.md.
- **SBOM generation** — stretch goal from plan.md (Semgrep SAST and pip-audit SCA are core; SBOM output is the remaining stretch item).
- **Statistics Canada as a data source** — locked out by ADR-0001.
- **Attack scenario #7 (integrity tamper)** — stretch goal.
- **Multi-account AWS Organizations** — documented as a production upgrade path in the README's residual risks section; not implemented.

---

## Further Notes

- **Detection rule ordering on apply**: the `detection/` module must be applied after the `cloudtrail/` module (CloudWatch log group and SNS topic ARN must exist). This dependency is expressed via resource reference in Terraform, not a hardcoded ARN, so Terraform resolves the apply order correctly within a single `terraform apply`.
- **SNS subscription confirmation**: the developer email subscription to the SNS topic requires a one-time confirmation click in the subscription confirmation email. This must be done before the Phase 3 verification gate — an unconfirmed subscription will not receive alerts.
- **Prowler accepted-risk entries**: any Prowler finding accepted rather than remediated must document: finding ID, severity, why it cannot be remediated (typically: budget constraint or POC-appropriate tradeoff), and the compensating control if one exists. This discipline distinguishes "we know about this" from "we missed it."
- **Documentation currency**: the documentation artefacts authored in Phase 3 are accurate at the end of Phase 3. If Phase 4 changes the architecture, update the affected documents. The STRIDE model in particular must reflect the attack-and-defense scenarios added in Phase 4.
- **Phase 3 understanding gate** (from plan.md): before starting Phase 4, be able to answer without notes — STRIDE: each letter with a concrete LoonVault threat; the detection pipeline end-to-end, including why EventBridge cannot detect the AccessDenied spike; what OSFI B-13 is and how ≥3 principles map to controls built; the difference between B-13 (technology/cyber risk) and E-23 (third-party risk); what Prowler checks and what a finding means; why the data was classified as it was and what would change at Protected B.
