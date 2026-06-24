# Crown-jewel demo: OPA policy gate blocks an attack (scenario #4)

This is the attack-and-defense demonstration for **scenario #4** in `plan.md` (tagged the
"crown jewel"): a change that opens **SSH to the entire internet** and creates a **public S3
bucket** is **blocked before deploy** by the OPA/conftest policy gate.

## What `run.sh` does
1. Generates two throwaway Terraform configs in a temp dir:
   - **bad**: `0.0.0.0/0:22` ingress, an S3 bucket with no Block Public Access, and a public
     bucket policy (`Principal: "*"`).
   - **good**: the compliant counterpart (SG-to-SG DB ingress, a bucket *with* BPA).
2. Runs `terraform init` + `plan` + `show -json` for each.
3. Runs the **real** policy gate (`scripts/policy-report.sh`) on each plan.
4. Writes the captured output + per-run JSON artifact to `docs/demo/policy-gate/`.

The configs use a **mock AWS provider** (`skip_*` flags + fake keys), so the demo is **plan-only
and never touches a real AWS account**. `terraform init` needs network (provider download) but
**no AWS credentials**. The insecure HCL is generated at runtime and never committed.

## Run it
```bash
# needs terraform + conftest on PATH (see policies/README.md for the pinned conftest install)
bash demo/policy-gate/run.sh
```
Expected result: the **bad** case is **DENIED** with 3 violations (each tagged with its OSFI B-13 /
GC Guardrail control); the **good** case **PASSES**. Both produce a JSON evidence artifact.

Then commit the generated files under `docs/demo/policy-gate/` as portfolio evidence.

Inspect the generated HCL without running the gate:
```bash
bash demo/policy-gate/run.sh --generate-only /tmp/demo && ls -R /tmp/demo
```
