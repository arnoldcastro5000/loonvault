#!/usr/bin/env bash
#
# policy-report.sh — evaluate a Terraform plan against the OPA/conftest policies
# AND retain the result as a per-run validation artifact (compliance evidence).
#
# This is the single "evaluate + record" step shared by the pre-push hook, the
# `just` plan/apply gate, and (later) the ADR-0010 apply runner. AWS's pattern-based
# policy-as-code guidance recommends retaining validation artifacts so policy
# results travel with the change record for audit, rather than vanishing into logs.
#
# The artifact (policy-reports/<stack>-<utc>-<sha>.json) records: the run (time,
# stack, git commit, policy version, tool), the evaluated scope, the pass/fail
# result, and the raw conftest output. Records on BOTH pass and fail.
#
# Usage:  scripts/policy-report.sh <stack> <plan.json>
# Exit:   0 if the gate passes, non-zero if any policy denies (so callers block).
# Requires: conftest, jq, git.
set -euo pipefail

STACK="${1:-}"
PLAN_JSON="${2:-}"
[ -n "$STACK" ] && [ -n "$PLAN_JSON" ] || {
	echo "usage: $0 <stack> <plan.json>" >&2
	exit 2
}
[ -f "$PLAN_JSON" ] || {
	echo "ERROR: plan JSON not found: $PLAN_JSON" >&2
	exit 2
}
command -v conftest >/dev/null || {
	echo "ERROR: conftest not found — see policies/README.md for the pinned install." >&2
	exit 2
}

REPO_ROOT="$(git rev-parse --show-toplevel)"
POLICY_DIR="$REPO_ROOT/policies"
REPORT_DIR="$REPO_ROOT/policy-reports"

# Evaluate (capture JSON + exit code; conftest exits non-zero on a denial).
set +e
raw="$(conftest test --all-namespaces -p "$POLICY_DIR" "$PLAN_JSON" -o json)"
rc=$?
set -e

# Guard against non-JSON output (e.g., a conftest setup error).
if ! printf '%s' "$raw" | jq empty >/dev/null 2>&1; then
	raw='[{"namespace":"_error","successes":0,"failures":[{"msg":"conftest produced no parseable JSON output"}]}]'
	[ "$rc" -eq 0 ] && rc=1
fi

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fnts="$(date -u +%Y%m%dT%H%M%SZ)"
commit="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
policy_version="$(git rev-parse HEAD:policies 2>/dev/null || echo unknown)"
conftest_version="$(conftest --version 2>/dev/null | awk '/Conftest/{print $2; exit}')"
result="$([ "$rc" -eq 0 ] && echo pass || echo fail)"

mkdir -p "$REPORT_DIR"
out="$REPORT_DIR/${STACK}-${fnts}-${commit}.json"

jq -n \
	--arg ts "$ts" --arg stack "$STACK" --arg commit "$commit" \
	--arg polver "$policy_version" --arg tool "conftest ${conftest_version:-unknown}" \
	--arg scope "infra/$STACK plan (terraform show -json)" \
	--arg result "$result" --argjson conftest "$raw" \
	'{
	  run: { timestamp: $ts, stack: $stack, git_commit: $commit, policy_version: $polver, tool: $tool },
	  scope: $scope,
	  result: $result,
	  conftest: $conftest
	}' >"$out"

if [ "$result" = "pass" ]; then
	echo "policy gate PASS ($STACK) — artifact: ${out#"$REPO_ROOT"/}"
else
	echo "policy gate FAIL ($STACK) — artifact: ${out#"$REPO_ROOT"/}" >&2
	printf '%s' "$raw" | jq -r '.[].failures[]?.msg' 2>/dev/null | sed 's/^/  - /' >&2 || true
fi

exit "$rc"
