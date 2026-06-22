# LoonVault policy-as-code (OPA-on-plan)

Compliance-annotated [Open Policy Agent](https://www.openpolicyagent.org/) policies that gate
Terraform changes **before deploy**, evaluated against `terraform show -json` plan output. This is
the pre-deploy / preventive layer of LoonVault's layered governance (region-lock SCP = org
guardrail; Prowler = post-deploy verification). Each rule is tagged with the OSFI B-13 principle and
GC Cloud Guardrail it enforces — the policies double as **compliance evidence** (compliance-as-code).

Structure follows AWS's pattern-based policy-as-code guidance — organised by control *intent*, not
by service:

```
policies/
├── shared/tfplan.rego          # plan-JSON helpers + the deny-message format
├── patterns/
│   ├── networking/             # exposure restriction: public admin ports, DB SG-to-SG
│   ├── storage/                # exposure restriction: S3 public access
│   └── baseline/               # allowed configuration: region lock
├── fixtures/                   # sample plan JSON (compliant / violating)
└── tests/  (co-located *_test.rego in each pattern dir)
```

## Input contract

Rules read a Terraform plan in JSON:

```bash
terraform plan -out=tfplan.bin
terraform show -json tfplan.bin > tfplan.json
```

Resources are taken from `.resource_changes[]` where `.change.actions` includes `create` or
`update` (deletes/no-ops/reads are ignored). The region rule reads
`.configuration.provider_config.aws.expressions.region.constant_value`.

## Run

```bash
# unit-test the policies (no AWS credentials needed)
conftest verify -p policies

# evaluate a plan (all pattern namespaces)
conftest test --all-namespaces -p policies tfplan.json

# lint the Rego
regal lint policies/
```

## Rules (v1)

| Pattern | Rule | OSFI B-13 | GC |
|---|---|---|---|
| networking | No `0.0.0.0/0` / `::/0` ingress on admin ports 22/3389 | Cyber Security – Infrastructure security | — |
| networking | DB ingress (5432) must be SG-to-SG (no CIDR) | Cyber Security – Infrastructure security | — |
| storage | Every bucket has a BPA (all four flags true); no public ACL; no public bucket policy | Cyber Security – Data security (at rest) | GR06 |
| baseline | Provider region must be `ca-central-1` | Cyber Security – Infrastructure security | GR05 |
