# Compliance

Primary framework: **OSFI B-13** (Technology & Cyber Risk). Secondary: OSFI E-23 (third-party
risk), GC Cloud Guardrails, CIS. The mapping below is curated; the policy-gate coverage matrix
is **generated from the policy metadata** so it can't drift from what is actually enforced.

## OSFI B-13 control mapping

| Principle | LoonVault control |
|---|---|
| Identity & access management | Cloudflare Access + MFA; CF Access JWT validated at origin; least-privilege IAM per Lambda; credential-free CI |
| Data security (at rest) | CMK on S3 / RDS / Secrets Manager; annual rotation |
| Data security (in transit) | TLS 1.2 everywhere; Cloudflare Full-strict; `sslmode=verify-full` |
| Infrastructure security | Private subnets; SG-to-SG only; region-lock SCP; gateway VPC endpoints |
| Threat & vulnerability mgmt | OPA gate + Checkov + Semgrep + SCA + secret scanning; Prowler |
| Security monitoring & response | Org-wide CloudTrail; EventBridge → CloudWatch → SNS |
| Change management | IaC (Terraform); CI gates; pre-deploy policy gate |
| E-23 third-party risk | Third-party sub-service register; cloud exit strategy |

## Policy-as-code coverage (generated)

Each OPA policy is annotated with the control it enforces; this matrix is generated from that
metadata by `scripts/gen-compliance-matrix.sh`.

<!-- include policies/COMPLIANCE.md -->

## Attack blocked — evidence

The pre-deploy gate is demonstrated blocking a change that opens SSH to the internet and creates a
public S3 bucket (attack/defense scenario #4):

```
DENY  aws_security_group_rule.ssh_world — administrative port (22/3389) open to the internet
DENY  aws_s3_bucket.leak — bucket has no public-access-block
DENY  aws_s3_bucket_policy.leak — bucket policy grants public access with no condition
```

[Full captured evidence on GitHub →](https://github.com/arnoldcastro5000/loonvault/tree/main/docs/demo/policy-gate)
