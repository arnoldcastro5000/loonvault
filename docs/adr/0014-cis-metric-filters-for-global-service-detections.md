# Global-service detections as CIS metric-filter alarms, not us-east-1 EventBridge rules

Detection rules 2 (console sign-in without MFA), 3 (root usage), and 4 (IAM policy changes)
are implemented as **CloudWatch Logs metric-filter alarms in ca-central-1**, using the CIS AWS
Foundations Benchmark filter patterns verbatim — not as EventBridge rules. This ADR records why,
because the original design (EventBridge rules for all single-occurrence signals) was wrong in a
way that only surfaced when two other controls collided.

**The collision.** EventBridge delivers events from global services — IAM, STS, and console
sign-in — **only to the us-east-1 event bus** (AWS EventBridge troubleshooting guide: "events
from API calls from global services are only available in that region"). Rules 2/3/4 as
originally deployed on the ca-central-1 bus could never match (issue 007). The AWS-documented
fix is to create the rules in us-east-1. But the region-lock SCP (ADR-0009) explicitly denies
non-`ca-central-1` actions for workloads-account principals, and `events:*` is not — and should
not be — in its exemption list. Our own guardrail forbids the vendor-recommended fix.

**Options considered.**
- *(a) us-east-1 EventBridge rules in the workloads account* — requires punching an `events:*`
  hole in the region-lock SCP. Rejected: weakens the headline guardrail to serve a secondary
  control.
- *(b) us-east-1 rules in the SCP-exempt management account, cross-account/cross-region routed*
  — works, but adds cross-account event-bus permissions, an IAM routing role, and puts workload
  alerting infrastructure in the account that is supposed to stay near-empty (ADR-0009).
  Rejected as disproportionate.
- *(c) CloudWatch Logs metric-filter alarms in ca-central-1* — **chosen.** The member trail is
  multi-region with `include_global_service_events`, so IAM/sign-in events already land in the
  ca-central-1 log group that rule 6 reads. Three metric filters + alarms replicate an existing
  in-repo pattern with zero new plumbing.

**Why (c) is canonical, not a workaround.** The CIS AWS Foundations Benchmark specifies exactly
these three detections as metric filters + alarms on a CloudTrail log group (CIS v1.4.0 controls
4.2, 4.3, 4.4), and Security Hub ships controls (CloudWatch.1, CloudWatch.3, CloudWatch.4) that
check for those **exact** filter patterns — they fail if terms are added or removed, so the
patterns are used verbatim and must not be "improved". A side benefit: Security Hub only credits
trails owned by the evaluated account in the evaluated region, which the member trail satisfies;
enabling Security Hub's CIS standard would score these controls PASS as-built.

**Consequences.**
- Alert latency on rules 2/3/4 is **~5–10 minutes** (CloudTrail → CW Logs delivery plus alarm
  evaluation) versus seconds on the EventBridge rules. Accepted for low-volume,
  any-occurrence-is-suspicious signals; recorded as Honest Residual Risk #9 in `plan.md`.
  Production fix: a delegated-admin security account outside the SCP's scope.
- Alarm emails carry the alarm name, not the event payload; triage requires a CloudWatch Logs
  Insights query against the log group (runbook).
- Rule 2 is **expected-but-logged** for IAM Identity Center sign-ins: federated `ConsoleLogin`
  events record `MFAUsed: No` (MFA happens at the IdP), so every SSO console login fires it.
  Same triage posture as rule 8; runbook "Expected alerts" documents it.
- Rule 9's tamper watch was extended to the new transport's suppression surface:
  `DeleteMetricFilter`, `DeleteAlarms`, `DisableAlarmActions` alongside the EventBridge
  operations.
- The detection pipeline is now 5 EventBridge rules + 4 metric-filter alarms; the "nine rules"
  framing and the per-rule table in `plan.md` §Detection Pipeline reflect this.
