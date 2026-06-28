#!/usr/bin/env bash
#
# setup-org-cloudtrail.sh
# ---------------------------------------------------------------------------
# Stands up a PERSISTENT, ORGANIZATION-WIDE CloudTrail in the AWS Organizations
# MANAGEMENT account, encrypted with a dedicated KMS CMK and delivered to a
# locked-down S3 bucket. Member accounts (incl. the Workloads OU) cannot modify,
# delete, or read it — which is exactly why ADR-0010's apply runner depends on it.
#
# Run this on YOUR terminal, authenticated as an admin of the MANAGEMENT account
# (the org's payer/root account). It is idempotent-ish: safe to re-run; steps that
# already exist are detected and skipped.
#
# Config comes from the ENVIRONMENT — nothing secret (or account-specific) is baked
# into this file, so it commits cleanly and no AWS account ID ever lands in git
# history. Only MGMT_ACCOUNT_ID is required; the rest have sane defaults.
#
#   MGMT_ACCOUNT_ID   (required)  org management/payer account ID, 12 digits
#   AWS_REGION        home region for trail + bucket          (default ca-central-1)
#   S3_BUCKET_NAME    log bucket                              (default loonvault-org-cloudtrail-root)
#   ORG_ID            o-xxxx       (default: auto-detected via describe-organization)
#   TRAIL_NAME                                                (default loonvault-org-trail)
#   KMS_ALIAS                                          (default alias/loonvault-org-cloudtrail)
#   RETENTION_DAYS    S3 log expiry                           (default 400)
#   ENABLE_DATA_EVENTS  log S3/Lambda data events             (default true)
#                       (KMS ops are management events, always logged)
#
# Usage:
#   MGMT_ACCOUNT_ID=<ACCOUNT_ID> ./scripts/setup-org-cloudtrail.sh
#   MGMT_ACCOUNT_ID=<ACCOUNT_ID> ENABLE_DATA_EVENTS=false ./scripts/setup-org-cloudtrail.sh
#
# DEBUGGING: every AWS call is traced with its full command line and exit code
# (see run() below), and any unhandled failure prints the line + exit code via the
# ERR trap. Paste the full output to debug a failed run.
#
# NOTE ON SCOPE: an *organization* trail automatically logs ALL accounts in the
# org. AWS provides no way to limit one trail to a single OU, so this trail covers
# the whole org (management account + every member, including the Workloads OU).
# That is the AWS-recommended posture and satisfies the ADR-0010 requirement.
#
# NOTE ON IaC: the canonical home for this is Terraform in infra/org/. This CLI
# script is a fast bootstrap / prototype; port it to infra/org when ready (and bump
# the `org Terraform resource count` in scripts/verify-docs.sh per CLAUDE.md).
# ---------------------------------------------------------------------------

set -euo pipefail

# ---- debug tracing ---------------------------------------------------------
# run() echoes the command and its exit code to STDERR before/after executing.
# Because diagnostics go to stderr, a command's real stdout can still be captured:
#   KEY_ID=$(run aws kms create-key ... --query KeyMetadata.KeyId --output text)
# Probe commands whose failure is normal (describe-key / head-bucket / get-trail)
# are handled separately below so their expected "not found" errors aren't mistaken
# for real failures — they print "-> <probe> exit N" instead.
run() {
  printf '  $ %s\n' "$*" >&2
  local rc=0
  LAST_CMD="$*"
  "$@" || rc=$?
  printf '  -> exit %d\n' "$rc" >&2
  return "$rc"
}
LAST_CMD=""

# Report the exit code of any unhandled failure before the script exits. For an AWS
# call, the exact command + its exit code are in the "$ ... / -> exit" block above;
# we echo the last-run command here too so the cause is unambiguous.
trap 'rc=$?; printf "\n!! FAILED (exit %d). Last command: %s\n   (see the $/-> trace above for the failing AWS call)\n" "$rc" "${LAST_CMD:-$BASH_COMMAND}" >&2' ERR


# ---- config from environment (see header for descriptions) ----------------
MGMT_ACCOUNT_ID="${MGMT_ACCOUNT_ID:-}"
AWS_REGION="${AWS_REGION:-ca-central-1}"
S3_BUCKET_NAME="${S3_BUCKET_NAME:-}"
ORG_ID="${ORG_ID:-}"
TRAIL_NAME="${TRAIL_NAME:-loonvault-org-trail}"
KMS_ALIAS="${KMS_ALIAS:-alias/loonvault-org-cloudtrail}"
RETENTION_DAYS="${RETENTION_DAYS:-400}"
ENABLE_DATA_EVENTS="${ENABLE_DATA_EVENTS:-true}"


# ---- derive + validate ----------------------------------------------------
: "${MGMT_ACCOUNT_ID:?set MGMT_ACCOUNT_ID (e.g. MGMT_ACCOUNT_ID=<ACCOUNT_ID> $0)}"
[ -z "$S3_BUCKET_NAME" ] && S3_BUCKET_NAME="loonvault-org-cloudtrail-root"

echo ">> Verifying you are authenticated as the management account..."
CALLER_ACCT=$(run aws sts get-caller-identity --query Account --output text)
if [ "$CALLER_ACCT" != "$MGMT_ACCOUNT_ID" ]; then
  echo "ERROR: current credentials are for account $CALLER_ACCT, not the management account $MGMT_ACCOUNT_ID" >&2
  exit 1
fi

if [ -z "$ORG_ID" ]; then
  echo ">> Auto-detecting Organization ID..."
  ORG_ID=$(run aws organizations describe-organization --query 'Organization.Id' --output text)
fi
echo "   Org ID: $ORG_ID"

TRAIL_ARN="arn:aws:cloudtrail:${AWS_REGION}:${MGMT_ACCOUNT_ID}:trail/${TRAIL_NAME}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo ">> Config:"
echo "   region=$AWS_REGION  bucket=$S3_BUCKET_NAME  trail=$TRAIL_NAME"
echo "   kms_alias=$KMS_ALIAS  retention=${RETENTION_DAYS}d  data_events=$ENABLE_DATA_EVENTS"
echo


# ---- 1. Enable trusted access for CloudTrail in Organizations --------------
# Prerequisite: the org must have ALL FEATURES enabled (a one-time setup). LoonVault
# already does — it attaches an SCP (infra/org), which requires all features — so we
# do NOT run `aws organizations enable-all-features` here (it kicks off a member
# approval handshake and is not safely idempotent). If you ever run this against a
# fresh org without all features, enable it first.
echo ">> [1/7] Enabling CloudTrail trusted access in Organizations..."
run aws organizations enable-aws-service-access \
  --service-principal cloudtrail.amazonaws.com || true


# ---- 2. Create the KMS CMK (encrypts log files; mgmt-account read only) ----
echo ">> [2/7] Creating/locating KMS CMK..."
probe_rc=0
KEY_ARN=$(aws kms describe-key --key-id "$KMS_ALIAS" --query KeyMetadata.Arn --output text 2>/dev/null) || probe_rc=$?
echo "  -> describe-key probe exit $probe_rc" >&2
if [ "$probe_rc" -eq 0 ]; then
  echo "   Alias $KMS_ALIAS already exists -> $KEY_ARN"
else
  cat > "$WORKDIR/kms-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Id": "loonvault-org-cloudtrail-cmk",
  "Statement": [
    {
      "Sid": "EnableRootAdmin",
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::${MGMT_ACCOUNT_ID}:root" },
      "Action": "kms:*",
      "Resource": "*"
    },
    {
      "Sid": "AllowCloudTrailEncryptLogs",
      "Effect": "Allow",
      "Principal": { "Service": "cloudtrail.amazonaws.com" },
      "Action": "kms:GenerateDataKey*",
      "Resource": "*",
      "Condition": {
        "StringEquals": { "aws:SourceArn": "${TRAIL_ARN}" },
        "StringLike": { "kms:EncryptionContext:aws:cloudtrail:arn": "arn:aws:cloudtrail:*:${MGMT_ACCOUNT_ID}:trail/*" }
      }
    },
    {
      "Sid": "AllowCloudTrailDecryptLogs",
      "Effect": "Allow",
      "Principal": { "Service": "cloudtrail.amazonaws.com" },
      "Action": "kms:Decrypt",
      "Resource": "*",
      "Condition": {
        "StringEquals": { "aws:SourceArn": "${TRAIL_ARN}" },
        "StringLike": { "kms:EncryptionContext:aws:cloudtrail:arn": "arn:aws:cloudtrail:*:${MGMT_ACCOUNT_ID}:trail/*" }
      }
    },
    {
      "Sid": "AllowCloudTrailDescribeKey",
      "Effect": "Allow",
      "Principal": { "Service": "cloudtrail.amazonaws.com" },
      "Action": "kms:DescribeKey",
      "Resource": "*"
    },
    {
      "Sid": "AllowMgmtAccountDecryptLogs",
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::${MGMT_ACCOUNT_ID}:root" },
      "Action": [ "kms:Decrypt", "kms:ReEncryptFrom" ],
      "Resource": "*",
      "Condition": {
        "StringEquals": { "kms:CallerAccount": "${MGMT_ACCOUNT_ID}" },
        "StringLike": { "kms:EncryptionContext:aws:cloudtrail:arn": "arn:aws:cloudtrail:*:${MGMT_ACCOUNT_ID}:trail/*" }
      }
    }
  ]
}
EOF
  KEY_ID=$(run aws kms create-key \
    --description "LoonVault org CloudTrail log encryption" \
    --policy "file://$WORKDIR/kms-policy.json" \
    --tags TagKey=project,TagValue=loonvault \
    --query KeyMetadata.KeyId --output text)
  run aws kms create-alias --alias-name "$KMS_ALIAS" --target-key-id "$KEY_ID"
  run aws kms enable-key-rotation --key-id "$KEY_ID"
  KEY_ARN=$(run aws kms describe-key --key-id "$KEY_ID" --query KeyMetadata.Arn --output text)
  echo "   Created CMK -> $KEY_ARN"
fi


# ---- 3. Create + lock down the S3 log bucket ------------------------------
echo ">> [3/7] Creating/locating S3 log bucket..."
probe_rc=0
aws s3api head-bucket --bucket "$S3_BUCKET_NAME" 2>/dev/null || probe_rc=$?
echo "  -> head-bucket probe exit $probe_rc" >&2
if [ "$probe_rc" -eq 0 ]; then
  echo "   Bucket $S3_BUCKET_NAME already exists."
else
  if [ "$AWS_REGION" = "us-east-1" ]; then
    run aws s3api create-bucket --bucket "$S3_BUCKET_NAME" --region us-east-1
  else
    run aws s3api create-bucket --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" \
      --create-bucket-configuration "LocationConstraint=${AWS_REGION}"
  fi
  echo "   Created bucket $S3_BUCKET_NAME"
fi

echo "   - blocking all public access"
run aws s3api put-public-access-block --bucket "$S3_BUCKET_NAME" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

echo "   - enabling versioning"
run aws s3api put-bucket-versioning --bucket "$S3_BUCKET_NAME" \
  --versioning-configuration Status=Enabled

echo "   - default SSE-KMS with the CloudTrail CMK"
cat > "$WORKDIR/sse.json" <<EOF
{ "Rules": [ {
  "ApplyServerSideEncryptionByDefault": { "SSEAlgorithm": "aws:kms", "KMSMasterKeyID": "${KEY_ARN}" },
  "BucketKeyEnabled": true
} ] }
EOF
run aws s3api put-bucket-encryption --bucket "$S3_BUCKET_NAME" \
  --server-side-encryption-configuration "file://$WORKDIR/sse.json"

echo "   - lifecycle: expire logs after ${RETENTION_DAYS} days"
cat > "$WORKDIR/lifecycle.json" <<EOF
{ "Rules": [ {
  "ID": "expire-cloudtrail-logs",
  "Status": "Enabled",
  "Filter": { "Prefix": "AWSLogs/" },
  "Expiration": { "Days": ${RETENTION_DAYS} },
  "NoncurrentVersionExpiration": { "NoncurrentDays": 30 }
} ] }
EOF
run aws s3api put-bucket-lifecycle-configuration --bucket "$S3_BUCKET_NAME" \
  --lifecycle-configuration "file://$WORKDIR/lifecycle.json"

echo "   - applying CloudTrail delivery bucket policy (org + mgmt paths, TLS-only)"
cat > "$WORKDIR/bucket-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AWSCloudTrailAclCheck",
      "Effect": "Allow",
      "Principal": { "Service": "cloudtrail.amazonaws.com" },
      "Action": "s3:GetBucketAcl",
      "Resource": "arn:aws:s3:::${S3_BUCKET_NAME}",
      "Condition": { "StringEquals": { "aws:SourceArn": "${TRAIL_ARN}" } }
    },
    {
      "Sid": "AWSCloudTrailWriteOrg",
      "Effect": "Allow",
      "Principal": { "Service": "cloudtrail.amazonaws.com" },
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::${S3_BUCKET_NAME}/AWSLogs/${ORG_ID}/*",
      "Condition": {
        "StringEquals": {
          "s3:x-amz-acl": "bucket-owner-full-control",
          "aws:SourceArn": "${TRAIL_ARN}"
        }
      }
    },
    {
      "Sid": "AWSCloudTrailWriteMgmt",
      "Effect": "Allow",
      "Principal": { "Service": "cloudtrail.amazonaws.com" },
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::${S3_BUCKET_NAME}/AWSLogs/${MGMT_ACCOUNT_ID}/*",
      "Condition": {
        "StringEquals": {
          "s3:x-amz-acl": "bucket-owner-full-control",
          "aws:SourceArn": "${TRAIL_ARN}"
        }
      }
    },
    {
      "Sid": "DenyInsecureTransport",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::${S3_BUCKET_NAME}",
        "arn:aws:s3:::${S3_BUCKET_NAME}/*"
      ],
      "Condition": { "Bool": { "aws:SecureTransport": "false" } }
    }
  ]
}
EOF
run aws s3api put-bucket-policy --bucket "$S3_BUCKET_NAME" \
  --policy "file://$WORKDIR/bucket-policy.json"


# ---- 4. Create the organization trail -------------------------------------
echo ">> [4/7] Creating the organization trail..."
probe_rc=0
aws cloudtrail get-trail --name "$TRAIL_NAME" --region "$AWS_REGION" >/dev/null 2>&1 || probe_rc=$?
echo "  -> get-trail probe exit $probe_rc" >&2
if [ "$probe_rc" -eq 0 ]; then
  echo "   Trail $TRAIL_NAME already exists; updating settings."
  run aws cloudtrail update-trail \
    --name "$TRAIL_NAME" \
    --s3-bucket-name "$S3_BUCKET_NAME" \
    --is-organization-trail \
    --is-multi-region-trail \
    --enable-log-file-validation \
    --kms-key-id "$KEY_ARN" \
    --region "$AWS_REGION" >/dev/null
else
  run aws cloudtrail create-trail \
    --name "$TRAIL_NAME" \
    --s3-bucket-name "$S3_BUCKET_NAME" \
    --is-organization-trail \
    --is-multi-region-trail \
    --enable-log-file-validation \
    --kms-key-id "$KEY_ARN" \
    --region "$AWS_REGION" >/dev/null
  echo "   Created $TRAIL_NAME"
fi


# ---- 5. Event selectors (management + optional data events) ----------------
echo ">> [5/7] Configuring event selectors..."
if [ "$ENABLE_DATA_EVENTS" = "true" ]; then
  cat > "$WORKDIR/selectors.json" <<'EOF'
[
  { "Name": "Management events",
    "FieldSelectors": [ { "Field": "eventCategory", "Equals": ["Management"] } ] },
  { "Name": "S3 object data events",
    "FieldSelectors": [ { "Field": "eventCategory", "Equals": ["Data"] },
                        { "Field": "resources.type", "Equals": ["AWS::S3::Object"] } ] },
  { "Name": "Lambda function data events",
    "FieldSelectors": [ { "Field": "eventCategory", "Equals": ["Data"] },
                        { "Field": "resources.type", "Equals": ["AWS::Lambda::Function"] } ] }
]
EOF
  # NOTE: KMS is NOT a data-event resource type. KMS cryptographic operations
  # (Decrypt, GenerateDataKey, Encrypt, ...) are logged as MANAGEMENT events, so the
  # "Management events" selector above already captures them — no KMS data selector.
else
  cat > "$WORKDIR/selectors.json" <<'EOF'
[
  { "Name": "Management events",
    "FieldSelectors": [ { "Field": "eventCategory", "Equals": ["Management"] } ] }
]
EOF
fi
run aws cloudtrail put-event-selectors \
  --trail-name "$TRAIL_NAME" \
  --advanced-event-selectors "file://$WORKDIR/selectors.json" \
  --region "$AWS_REGION" >/dev/null


# ---- 6. Start logging ------------------------------------------------------
echo ">> [6/7] Starting logging..."
run aws cloudtrail start-logging --name "$TRAIL_NAME" --region "$AWS_REGION"


# ---- 7. Verify -------------------------------------------------------------
echo ">> [7/7] Status:"
run aws cloudtrail get-trail-status --name "$TRAIL_NAME" --region "$AWS_REGION" \
  --query '{IsLogging:IsLogging, LatestDeliveryError:LatestDeliveryError, LatestDeliveryTime:LatestDeliveryTime}'

echo
echo "Done. Organization trail '${TRAIL_NAME}' is active."
echo "  Trail ARN : ${TRAIL_ARN}"
echo "  Log bucket: s3://${S3_BUCKET_NAME}/AWSLogs/"
echo "  CMK       : ${KEY_ARN}"
echo
echo "Verify delivery (logs can take ~5-10 min for the first object):"
echo "  aws s3 ls s3://${S3_BUCKET_NAME}/AWSLogs/ --recursive | head"
