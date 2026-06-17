## verify-docs.sh

`scripts/verify-docs.sh` runs in CI (`docs-drift` job) and locally via `just verify-docs`. It asserts that documented claims match the actual repo state. Fail = documentation has drifted from reality.

**Hardcoded counts — update these when you change the thing they guard:**

| What changed | File to update | Variable/label |
|---|---|---|
| Added/removed a CI job/workflow | `scripts/verify-docs.sh` | `check "CI job count" "$CI_JOBS" "7"` (counts jobs across all `.github/workflows/*.yml`) |
| Added/removed a gitleaks rule | `scripts/verify-docs.sh` | `check "gitleaks custom rule count" ...` (expected: 8) |
| Added/removed a trufflehog detector | `scripts/verify-docs.sh` | `check "trufflehog custom detector count" ...` (expected: 8) |
| Added/removed a resource in `infra/bootstrap/main.tf` | `scripts/verify-docs.sh` | `check "bootstrap Terraform resource count" ...` (expected: 9) |
| Added/removed a resource in `infra/org/main.tf` | `scripts/verify-docs.sh` | `check "org Terraform resource count" ...` (expected: 3) |

**Other checks (no hardcoded count, but still fail if broken):**

- CI is split into per-component workflows under `.github/workflows/` (`terraform`, `sast`, `secrets`, `lint`, `supply-chain`, `dependency-review`, `docs-drift`) — one job each. `sast` scans the working tree (shallow checkout); `secrets` scans full git history (`fetch-depth: 0`)
- All `uses:` actions in `.github/workflows/` must be SHA-pinned — no bare `@v1.2.3`
- Specific tool versions must appear in the CI workflows (gitleaks, tflint, trufflehog, actionlint)
- Required files must exist: `docs/threat-model.md`, `CONTEXT.md`, `plan.md`, `docs/devcontainer.md`, `docs/runbook.md`, `docs/adr/0001-*`, `docs/adr/0002-*`
- `.devcontainer/validate.sh` must still reference `docs/devcontainer.md` (keeps the spec and its validator linked)
- `CONTEXT.md` must mention all three Pressure Metrics by name
- `infra/main/` must not exist (phase gate — update when that changes)

## Agent skills

### Issue tracker

Issues live as local markdown files under `.scratch/`. See `docs/agents/issue-tracker.md`.

### Triage labels

Default canonical label vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context repo — one `CONTEXT.md` + `docs/adr/` at the root. See `docs/agents/domain.md`.
