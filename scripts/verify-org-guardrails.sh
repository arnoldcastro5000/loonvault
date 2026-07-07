#!/usr/bin/env bash
#
# verify-org-guardrails.sh
# ---------------------------------------------------------------------------
# READ-ONLY verification of the org-level guardrails after running
# scripts/setup-org-cloudtrail.sh and `just org-apply` + move-account (ADR-0009,
# ADR-0010, runbook "Org guardrails"). Changes nothing; safe to run any time.
#
# Verifies:
#   1. mgmt profile is authenticated as the org management account
#   2. workloads profile is a different (member) account
#   3. org trail exists: organization-wide, multi-region, log validation, CMK
#   4. org trail is logging with no delivery errors
#   5. log objects are landing in the delivery bucket
#   6. the region-lock SCP exists
#   7. the SCP is attached to the Workloads OU
#   8. the workloads account lives in the Workloads OU
#   9. region lock BITES: an API call in another region is explicitly denied
#  10. home region still works from the workloads account
#
# Config comes from the ENVIRONMENT — nothing account-specific is baked in, so
# this commits cleanly (no AWS account ID ever lands in git history).
#
#   MGMT_PROFILE        AWS profile for the management account   (default loonvault)
#   WORKLOADS_PROFILE   AWS profile for the workloads account    (default loonvault-prod)
#   AWS_REGION          home region                              (default ca-central-1)
#   DENY_TEST_REGION    region expected to be denied             (default us-east-2)
#   TRAIL_NAME                                                   (default loonvault-org-trail)
#   S3_BUCKET_NAME      org trail log bucket                     (default loonvault-org-cloudtrail-root)
#   SCP_NAME                                                     (default loonvault-region-lock)
#   OU_NAME                                                      (default Workloads)
#
# Usage:
#   ./scripts/verify-org-guardrails.sh
# ---------------------------------------------------------------------------

set -euo pipefail

MGMT_PROFILE="${MGMT_PROFILE:-loonvault}"
WORKLOADS_PROFILE="${WORKLOADS_PROFILE:-loonvault-prod}"
AWS_REGION="${AWS_REGION:-ca-central-1}"
DENY_TEST_REGION="${DENY_TEST_REGION:-us-east-2}"
TRAIL_NAME="${TRAIL_NAME:-loonvault-org-trail}"
S3_BUCKET_NAME="${S3_BUCKET_NAME:-loonvault-org-cloudtrail-root}"
SCP_NAME="${SCP_NAME:-loonvault-region-lock}"
OU_NAME="${OU_NAME:-Workloads}"

PASS=0; FAIL=0; ERRORS=()

check() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf "  PASS  %s\n" "$label"
    (( PASS++ )) || true
  else
    printf "  FAIL  %s  (got: %s, want: %s)\n" "$label" "$actual" "$expected"
    ERRORS+=("$label")
    (( FAIL++ )) || true
  fi
}

mgmt() { aws --profile "$MGMT_PROFILE" --region "$AWS_REGION" "$@"; }

echo "=== org guardrail verification (read-only) ==="
echo

# ── 1-2. Identities ───────────────────────────────────────────────────────────
echo "--- Identities ---"
MGMT_ACCT=$(mgmt sts get-caller-identity --query Account --output text)
ORG_MGMT_ACCT=$(mgmt organizations describe-organization \
  --query Organization.MasterAccountId --output text)
check "mgmt profile ($MGMT_PROFILE) is the org management account" \
  "$MGMT_ACCT" "$ORG_MGMT_ACCT"

WORKLOADS_ACCT=$(aws --profile "$WORKLOADS_PROFILE" --region "$AWS_REGION" \
  sts get-caller-identity --query Account --output text)
if [[ "$WORKLOADS_ACCT" != "$MGMT_ACCT" ]]; then
  check "workloads profile ($WORKLOADS_PROFILE) is a member account" "member" "member"
else
  check "workloads profile ($WORKLOADS_PROFILE) is a member account" \
    "same-as-mgmt" "member"
fi

# ── 3-5. Org CloudTrail ───────────────────────────────────────────────────────
echo "--- Org CloudTrail ---"
TRAIL_JSON=$(mgmt cloudtrail get-trail --name "$TRAIL_NAME" \
  --query 'Trail.[IsOrganizationTrail,IsMultiRegionTrail,LogFileValidationEnabled,KmsKeyId]' \
  --output text 2>/dev/null || echo "MISSING MISSING MISSING MISSING")
read -r IS_ORG IS_MULTI HAS_VALIDATION KMS_KEY <<< "$TRAIL_JSON"
check "trail $TRAIL_NAME is an organization trail" "$IS_ORG" "True"
check "trail is multi-region" "$IS_MULTI" "True"
check "trail has log file validation" "$HAS_VALIDATION" "True"
check "trail log files are CMK-encrypted" \
  "$([[ "$KMS_KEY" == arn:aws:kms:* ]] && echo cmk || echo none)" "cmk"

read -r IS_LOGGING DELIVERY_ERR <<< "$(mgmt cloudtrail get-trail-status \
  --name "$TRAIL_NAME" \
  --query '[IsLogging, LatestDeliveryError || `none`]' --output text)"
check "trail is logging" "$IS_LOGGING" "True"
check "no delivery errors" "$DELIVERY_ERR" "none"

LOG_OBJECTS=$(mgmt s3api list-objects-v2 --bucket "$S3_BUCKET_NAME" \
  --prefix "AWSLogs/" --max-items 1 --query 'length(Contents || `[]`)' --output text)
check "log objects present in s3://$S3_BUCKET_NAME/AWSLogs/" "$LOG_OBJECTS" "1"

# ── 6-8. Region-lock SCP wiring ───────────────────────────────────────────────
echo "--- Region-lock SCP ---"
SCP_ID=$(mgmt organizations list-policies --filter SERVICE_CONTROL_POLICY \
  --query "Policies[?Name=='${SCP_NAME}'].Id | [0]" --output text)
check "SCP $SCP_NAME exists" \
  "$([[ "$SCP_ID" == p-* ]] && echo exists || echo missing)" "exists"

ROOT_ID=$(mgmt organizations list-roots --query 'Roots[0].Id' --output text)
OU_ID=$(mgmt organizations list-organizational-units-for-parent \
  --parent-id "$ROOT_ID" \
  --query "OrganizationalUnits[?Name=='${OU_NAME}'].Id | [0]" --output text)
check "OU $OU_NAME exists under root" \
  "$([[ "$OU_ID" == ou-* ]] && echo exists || echo missing)" "exists"

ATTACHED=$(mgmt organizations list-policies-for-target --target-id "$OU_ID" \
  --filter SERVICE_CONTROL_POLICY \
  --query "Policies[?Id=='${SCP_ID}'] | length(@)" --output text 2>/dev/null || echo 0)
check "SCP attached to $OU_NAME OU" "$ATTACHED" "1"

PARENT_ID=$(mgmt organizations list-parents --child-id "$WORKLOADS_ACCT" \
  --query 'Parents[0].Id' --output text)
check "workloads account lives in the $OU_NAME OU" "$PARENT_ID" "$OU_ID"

# ── 9-10. Region lock live test (Phase-0 gate) ────────────────────────────────
echo "--- Region lock live test (from $WORKLOADS_PROFILE) ---"
DENY_OUT=$(aws --profile "$WORKLOADS_PROFILE" ec2 describe-vpcs \
  --region "$DENY_TEST_REGION" 2>&1) && DENY_RC=0 || DENY_RC=$?
if [[ "$DENY_RC" -ne 0 && "$DENY_OUT" == *"explicit deny"* ]]; then
  check "$DENY_TEST_REGION is explicitly denied" "denied" "denied"
elif [[ "$DENY_RC" -ne 0 ]]; then
  check "$DENY_TEST_REGION is explicitly denied" "failed-but-not-explicit-deny" "denied"
else
  check "$DENY_TEST_REGION is explicitly denied" "ALLOWED" "denied"
fi

if aws --profile "$WORKLOADS_PROFILE" ec2 describe-vpcs \
     --region "$AWS_REGION" >/dev/null 2>&1; then
  check "$AWS_REGION still works" "allowed" "allowed"
else
  check "$AWS_REGION still works" "DENIED" "allowed"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
  printf 'FAILED: %s\n' "${ERRORS[@]}"
  exit 1
fi
