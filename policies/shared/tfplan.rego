# METADATA
# title: Terraform plan-JSON helpers
# description: Shared helpers for walking `terraform show -json` plan output.
package shared

import rego.v1

# managed(type) returns {address, after} for every resource of `type` that is
# being created or updated. Deletes, no-ops and reads are skipped so the policy
# only judges the post-apply desired state.
managed(resource_type) := [{"address": rc.address, "after": rc.change.after} |
	some rc in input.resource_changes
	rc.type == resource_type
	_is_managed(rc)
]

_is_managed(rc) if {
	some action in rc.change.actions
	action in {"create", "update"}
}

# as_array normalises a possibly-null value to an array.
as_array(x) := x if is_array(x)

as_array(x) := [] if not is_array(x)

# message builds a standard, compliance-annotated deny string carrying the
# OSFI B-13 principle and GC Cloud Guardrail the rule enforces ("-" if none).
message(address, problem, osfi, guardrail) := sprintf(
	"DENY [OSFI B-13: %s | GC %s] %s — %s",
	[osfi, guardrail, address, problem],
)
