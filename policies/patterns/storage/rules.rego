# METADATA
# title: Storage exposure restriction
# description: |
#   S3 buckets must enforce all four Block Public Access settings and must not
#   carry a public ACL.
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

# every Block Public Access flag must be true
deny contains msg if {
	some r in shared.managed("aws_s3_bucket_public_access_block")
	some flag in bpa_flags
	object.get(r.after, flag, false) != true
	msg := shared.message(r.address, sprintf("S3 Block Public Access flag %q must be true", [flag]), osfi, "GR06")
}

# a bucket ACL must not be public
deny contains msg if {
	some r in shared.managed("aws_s3_bucket_acl")
	acl := object.get(r.after, "acl", "")
	acl in public_acls
	msg := shared.message(r.address, sprintf("S3 ACL %q grants public access", [acl]), osfi, "GR06")
}
