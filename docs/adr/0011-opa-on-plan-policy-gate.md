# OPA-on-plan policy gate: pre-deploy compliance-as-code for Terraform

LoonVault adds an **Open Policy Agent (OPA) / conftest policy gate** that evaluates every
Terraform change **before it deploys**, against the JSON form of the plan (`terraform show -json`).
It is the **preventive / pre-deploy layer** of a layered governance model, and — because each rule
is annotated with the compliance control it enforces — the policies double as **compliance-as-code
evidence**, not just security checks. This ADR records the design; the implementation shipped across
PRs #27 (policies + tests), #28 (compliance matrix), #29 (S3 hardening), #30 (enforcement wiring),
#31 (validation artifacts), and #32/#33 (the scenario-#4 demo + evidence).

**Why OPA, and why on the *plan*.** Checkov already catches generic IaC misconfiguration. OPA's job
is the **LoonVault-specific invariants Checkov cannot express** — chiefly "RDS ingress must be
security-group-to-security-group, never a CIDR block" (`plan.md`, `infra/loonvault/networking.tf`).
Evaluating the **plan JSON** rather than the raw HCL is deliberate: the plan is the *resolved* result
(after variables, modules, and provider defaults), so a bad value hidden behind a variable still
shows up. The cost of that choice is the credential chicken-and-egg below.

**Input contract.** Rules read `terraform show -json` output. Resources come from
`.resource_changes[]` where `.change.actions` includes `create` or `update` (deletes / no-ops / reads
are ignored, so the gate judges only the post-apply desired state, via `.change.after`). Two rules
need more than `after`: the region rule reads
`.configuration.provider_config.aws.expressions.region.constant_value`, and the "every bucket has a
public-access-block" rule correlates buckets to their BPA through
`.configuration.root_module.resources[].expressions.bucket.references` (so it works even when bucket
names are computed). This contract is also what ADR-0010's apply runner consumes.

**Pattern-based structure (AWS-aligned).** Following AWS's
[*Governing IaC using pattern-based policy as code*](https://aws.amazon.com/blogs/security/governing-infrastructure-as-code-using-pattern-based-policy-as-code/),
policies are organised by recurring **control intent**, not by service:
`policies/patterns/{networking,storage,baseline}/`, shared helpers in `policies/shared/`, tests and
fixtures co-located. Each rule carries an OPA `# METADATA` annotation tagging its **OSFI B-13**
principle and **GC Cloud Guardrail**, so the mapping lives with the enforcement and cannot drift.

| Pattern | Rule | OSFI B-13 | GC |
|---|---|---|---|
| networking (exposure restriction) | No `0.0.0.0/0` / `::/0` ingress on admin ports 22/3389 (covers inline `aws_security_group`, `aws_security_group_rule`, and `aws_vpc_security_group_ingress_rule`) | Cyber Security – Infrastructure security | — |
| networking | DB ingress (5432) must be SG-to-SG (no CIDR) | Cyber Security – Infrastructure security | — |
| storage (exposure restriction) | Every bucket has a BPA (all four flags true); no public ACL; no public bucket policy | Cyber Security – Data security (at rest) | GR06 |
| baseline (allowed config) | Provider region must be `ca-central-1` (defense-in-depth behind the SCP) | Cyber Security – Infrastructure security | GR05 |

**Layered governance model.** OPA-on-plan is one layer, mapped onto controls that already exist:

- **Org guardrail** — the region-lock **SCP** ([ADR-0009](0009-region-lock-scp-at-workloads-ou.md)):
  even full write access in the workloads account cannot act outside `ca-central-1`.
- **Pre-deploy preventive** — **this OPA gate**: blocks a non-compliant *change* before apply.
- **Post-deploy / runtime** — **Prowler** verifies live state and catches drift OPA cannot see.

AWS's native compliance-as-code path for the runtime layer is **AWS Config conformance packs**
(which ship framework mappings, e.g. NIST 800-53 / FedRAMP) feeding **AWS Audit Manager** for
evidence. That is the production-grade option and is the right answer at scale. LoonVault uses
**Prowler instead** for the PoC: Config carries continuous per-evaluation cost and assumes always-on
resources, which conflicts with the `< $10/mo` budget and the ephemeral `terraform destroy` backend
([ADR-0007](0007-split-ephemeral-backend-from-always-on-frontend.md)); Prowler is free and on-demand.
This is a conscious cost/posture trade-off, not an oversight.

**Enforcement points, and the credential-free-CI chicken-and-egg.** A *real* plan needs AWS
credentials, which CI deliberately never holds (`plan.md` locked decision: all credentialed Terraform
originates from the developer's terminal). So enforcement is split by where credentials live:

- **CI (`lint` job)** runs the **policy unit tests** (`conftest verify`) against synthetic fixtures.
  No credentials → it validates that the *policies* are correct (incl. the crown-jewel cases), not a
  live plan. Pinned: `conftest 0.56.0`, `opa 1.17.0`, `regal 0.41.1`.
- **The pre-push hook** (`.githooks/pre-push`) and **`just loonvault-plan`/`-apply`** run the gate
  against a **real** plan on the developer terminal, blocking on a denial. The hook **skips in the
  credential-free devcontainer** (`DEVCONTAINER=true`) so the GitHub-only agent can still push code;
  `SKIP_POLICY_GATE=1` / `git push --no-verify` are documented escape hatches.
- **The apply runner** (ADR-0010, future) re-runs the same gate before `apply` — the credentialed
  home this control has always needed.

So CI guarantees the rules work; the credentialed gate enforces them on real changes. This is the
honest version of the control rather than pretending CI can plan without credentials.

**Compliance-as-code: two evidence artifacts.** (1) `policies/COMPLIANCE.md` is **generated** from the
rule metadata by `scripts/gen-compliance-matrix.sh` and `--check`-enforced in CI — the **coverage**
matrix (which control each policy enforces), which cannot silently drift. (2) Every real-plan
evaluation writes a per-run **result** artifact to `policy-reports/` (git-ignored) via
`scripts/policy-report.sh`, recording the run, evaluated scope, **policy version** (the git tree-sha
of `policies/`), and the pass/fail result — so a verdict is pinned to the exact rules that produced
it. Coverage + per-run results together are the audit trail an OSFI reviewer expects. The scenario-#4
demo (`demo/policy-gate/`) captures committed sample pass/fail artifacts under `docs/demo/policy-gate/`.

**Validation against AWS guidance.** Checked via the AWS Knowledge MCP: the validate → plan →
`show -json` → evaluate sequence matches AWS's published CI/CD example; the rules map 1:1 to AWS
Config managed rules (`vpc-sg-port-restriction-check` defaults to 22/3389; `s3-account-level-public-
access-blocks` uses the same four flags), which also surfaced and closed two gaps (require a BPA on
*every* bucket; deny public bucket *policies*, not just ACLs — PR #29). The "test policies like
software" and "retain validation artifacts" recommendations are both implemented.

**Deliberate divergence — enforce now, not advisory-first.** AWS recommends a phased rollout that
**starts in advisory (warn) mode** before blocking, to absorb false-positive disruption across many
teams. LoonVault **enforces immediately** (the pre-push hook and apply gate fail closed). This is a
conscious decision, justified for *this* project: it is single-developer (no multi-team blast
radius), the rules were pre-validated 1:1 against AWS Config managed rules, the scope is limited to
the `loonvault` stack, and the escape hatches (`SKIP_POLICY_GATE`, `--no-verify`) cover emergencies.
If the policy library later grows or is shared, conftest's `warn` rules provide an advisory tier to
adopt the phased approach.

**Consequences.**

- The gate is scoped to the **`loonvault`** stack. `infra/frontend` is intentionally excluded: its
  snapshots bucket is a deliberate public-read exception
  ([ADR-0004](0004-s3-snapshots-for-frontend-resilience.md)) that the storage policy would correctly
  deny. Extending the gate to `frontend`/`bootstrap` first requires a documented per-bucket exception
  in the policy (e.g. an allowlist or a tag). This is the main open follow-up.
- `conftest` must be installed on the developer terminal for the pre-push hook (pinned install in
  `policies/README.md`); CI installs its own pinned copies.
- CI cannot evaluate a real plan (no credentials) — it tests the rules only. Real-plan enforcement
  depends on the terminal or the apply runner.
- This is the second of ADR-0010's two apply-runner prerequisites (the first, the org-level
  CloudTrail, is also done): the apply runner can now reuse both this gate and `policy-report.sh`.

**Relationship to existing decisions.** This realises the `plan.md` "OPA/Conftest pre-push" and
attack/defense **scenario #4** ("custom OPA + Checkov block the deploy", the crown jewel) and the
shift-left posture against AI-assisted development in the threat model (T-051): AI-generated Terraform
passes the same gate as human-written code, regardless of authorship.
