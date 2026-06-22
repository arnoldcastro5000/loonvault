# METADATA
# title: Storage exposure restriction
# description: |
#   Every S3 bucket must block public access: it must have a public-access-block
#   with all four flags enabled, must not carry a public ACL, and must not have a
#   bucket policy that grants access to everyone (Principal "*") without a
#   restricting condition.
# custom:
#   pattern: exposure-restriction
#   severity: high
#   controls:
#     osfi_b13: "Cyber Security – Data security (at rest)"
#     gc_guardrail: "GR06"
package patterns.storage

import data.shared
import rego.v1

osfi := "Cyber Security – Data security (at rest)"

bpa_flags := ["block_public_acls", "ignore_public_acls", "block_public_policy", "restrict_public_buckets"]

public_acls := {"public-read", "public-read-write", "authenticated-read"}

# 1. every Block Public Access flag must be true
deny contains msg if {
	some r in shared.managed("aws_s3_bucket_public_access_block")
	some flag in bpa_flags
	object.get(r.after, flag, false) != true
	msg := shared.message(r.address, sprintf("BPA flag %q must be true", [flag]), osfi, "GR06")
}

# 2. a bucket ACL must not be public
deny contains msg if {
	some r in shared.managed("aws_s3_bucket_acl")
	acl := object.get(r.after, "acl", "")
	acl in public_acls
	msg := shared.message(r.address, sprintf("S3 ACL %q grants public access", [acl]), osfi, "GR06")
}

# 3. every bucket must HAVE a public-access-block. Checking only the flags of an
#    existing BPA (rule 1) misses the real exposure: a bucket created with no BPA
#    at all. Correlation uses the plan's `configuration` references, so it works
#    even when bucket names are computed. (Root-module resources only.)
deny contains msg if {
	input.configuration
	some r in shared.managed("aws_s3_bucket")
	not r.address in _buckets_with_bpa
	msg := shared.message(r.address, "bucket has no public-access-block", osfi, "GR06")
}

# 4. a bucket policy must not grant public (Principal "*") access without a
#    restricting condition. A protective `Deny` to "*", a service principal, or an
#    `Allow` narrowed by a Condition are all fine and are not flagged.
deny contains msg if {
	some r in shared.managed("aws_s3_bucket_policy")
	policy_str := object.get(r.after, "policy", "")
	policy_str != ""
	policy := json.unmarshal(policy_str)
	some stmt in _statements(policy)
	stmt.Effect == "Allow"
	_principal_is_public(stmt)
	not stmt.Condition
	msg := shared.message(r.address, "bucket policy grants public access with no condition", osfi, "GR06")
}

# --- helpers ---

_buckets_with_bpa contains addr if {
	some res in input.configuration.root_module.resources
	res.type == "aws_s3_bucket_public_access_block"
	some ref in res.expressions.bucket.references
	addr := _ref_address(ref)
}

# "aws_s3_bucket.raw.id" -> "aws_s3_bucket.raw"
_ref_address(ref) := sprintf("%s.%s", [parts[0], parts[1]]) if {
	parts := split(ref, ".")
	count(parts) >= 2
}

_statements(policy) := policy.Statement if is_array(policy.Statement)

_statements(policy) := [policy.Statement] if is_object(policy.Statement)

_principal_is_public(stmt) if stmt.Principal == "*"

_principal_is_public(stmt) if stmt.Principal.AWS == "*"

_principal_is_public(stmt) if {
	some p in stmt.Principal.AWS
	p == "*"
}
