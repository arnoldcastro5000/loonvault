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
  if grep -qF "$str" .github/workflows/ci.yml; then
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
check "gitleaks custom rule count" "$GITLEAKS_RULES" "7"

TRUFFLEHOG_DETECTORS=$(grep -c '^  - name:' .trufflehog.yml || true)
check "trufflehog custom detector count" "$TRUFFLEHOG_DETECTORS" "7"

# ── CI workflow ───────────────────────────────────────────────────────────────
echo
echo "--- CI workflow ---"

CI_JOBS=$(awk '/^jobs:/{p=1} p && /^  [a-zA-Z]/{count++} END{print count}' \
  .github/workflows/ci.yml)
# NOTE: If you add or remove a CI job, update this expected value.
check "CI job count" "$CI_JOBS" "6"

UNPINNED=$(grep -E '^\s+uses:\s+' .github/workflows/ci.yml \
  | grep -v '@[0-9a-f]\{40\}' \
  | wc -l | tr -d ' ')
check "all Actions SHA-pinned (no bare @vX.Y.Z)" "$UNPINNED" "0"

_ci_has "gitleaks version v8.30.1 in ci.yml"   "v8.30.1"
_ci_has "tflint version v0.63.1 in ci.yml"     "v0.63.1"
_ci_has "trufflehog version v3.95.5 in ci.yml" "v3.95.5"
_ci_has "actionlint version v1.7.12 in ci.yml" "v1.7.12"

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
  "docs/adr/0001-single-data-source-boc-valet.md" \
  "docs/adr/0002-two-tier-data-model.md"
do
  check "file exists: $f" "$f" "" "exists"
done

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
