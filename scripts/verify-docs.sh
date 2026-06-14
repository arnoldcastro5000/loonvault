#!/usr/bin/env bash
set -euo pipefail

# Run from repo root. Checks verifiable claims in docs against built assets.

PASS=0; FAIL=0; ERRORS=()

check() {
  local label="$1" actual="$2" expected="$3" op="${4:-eq}"
  local result="PASS"
  case "$op" in
    eq)         [[ "$actual" == "$expected" ]] || result="FAIL" ;;
    neq)        [[ "$actual" != "$expected" ]] || result="FAIL" ;;
    exists)     [[ -e "$actual" ]]             || result="FAIL" ;;
    not_exists) [[ ! -e "$actual" ]]           || result="FAIL" ;;
  esac
  if [[ "$result" == "PASS" ]]; then
    printf "  PASS  %s\n" "$label"
    (( PASS++ )) || true
  else
    printf "  FAIL  %s  (got: %s, want: %s)\n" "$label" "$actual" "$expected"
    ERRORS+=("$label")
    (( FAIL++ )) || true
  fi
}

_ci_has() {
  local label="$1" str="$2"
  if grep -qrF "$str" .github/workflows/; then
    check "$label" "found" "found"
  else
    check "$label" "NOT FOUND" "found"
  fi
}

echo "=== docs-drift verification ==="
echo

# ── Secret scanning config ────────────────────────────────────────────────────
echo "--- Secret scanning ---"
GITLEAKS_RULES=$(grep -c '^\[\[rules\]\]' .gitleaks.toml || true)
check "gitleaks custom rule count" "$GITLEAKS_RULES" "8"

TRUFFLEHOG_DETECTORS=$(grep -c '^  - name:' .trufflehog.yml || true)
check "trufflehog custom detector count" "$TRUFFLEHOG_DETECTORS" "8"

# ── CI workflow ───────────────────────────────────────────────────────────────
echo
echo "--- CI workflow ---"

# One job per component workflow file. Count top-level jobs across all of them.
CI_JOBS=$(awk 'FNR==1{p=0} /^jobs:/{p=1} p && /^  [a-zA-Z]/{count++} END{print count}' \
  .github/workflows/*.yml)
# NOTE: If you add or remove a CI workflow/job, update this expected value.
check "CI job count" "$CI_JOBS" "7"

UNPINNED=$(grep -rE '^\s+uses:\s+' .github/workflows/ \
  | { grep -v '@[0-9a-f]\{40\}' || true; } \
  | wc -l | tr -d ' ')
check "all Actions SHA-pinned (no bare @vX.Y.Z)" "$UNPINNED" "0"

_ci_has "gitleaks version v8.30.1 in CI workflows"   "v8.30.1"
_ci_has "tflint version v0.63.1 in CI workflows"     "v0.63.1"
_ci_has "trufflehog version v3.95.5 in CI workflows" "v3.95.5"
_ci_has "actionlint version v1.7.12 in CI workflows" "v1.7.12"

# ── Terraform ─────────────────────────────────────────────────────────────────
echo
echo "--- Terraform ---"

TF_BOOTSTRAP=$(grep -c '^resource "' infra/bootstrap/main.tf || true)
check "bootstrap Terraform resource count" "$TF_BOOTSTRAP" "9"

TF_ORG=$(grep -c '^resource "' infra/org/main.tf || true)
check "org Terraform resource count" "$TF_ORG" "2"

# ── Phase gate ────────────────────────────────────────────────────────────────
echo
echo "--- Phase gates ---"
# Flip this to 'exists' (and update label) when Phase 1 begins.
check "infra/main/ does not exist (Phase 1 not started)" "infra/main" "" "not_exists"

# ── Required files ────────────────────────────────────────────────────────────
echo
echo "--- Required files ---"
for f in \
  "docs/threat-model.md" \
  "CONTEXT.md" \
  "plan.md" \
  "docs/devcontainer.md" \
  "docs/runbook.md" \
  "docs/adr/0001-single-data-source-boc-valet.md" \
  "docs/adr/0002-two-tier-data-model.md"
do
  check "file exists: $f" "$f" "" "exists"
done

# docs/devcontainer.md is the spec that .devcontainer/validate.sh checks against
check ".devcontainer/validate.sh references devcontainer.md" \
  "$(grep -c 'docs/devcontainer.md' .devcontainer/validate.sh || true)" "0" "neq"

# ── Domain model ──────────────────────────────────────────────────────────────
echo
echo "--- Domain model (CONTEXT.md) ---"
for metric in "Real M2" "Yield Curve Spread" "Bank Credit Growth Rate"; do
  FOUND=$(grep -cF "$metric" CONTEXT.md || true)
  check "CONTEXT.md mentions Pressure Metric: $metric" "$FOUND" "0" "neq"
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
  echo
  echo "Failed checks:"
  for e in "${ERRORS[@]}"; do
    printf "  - %s\n" "$e"
  done
  exit 1
fi
exit 0
