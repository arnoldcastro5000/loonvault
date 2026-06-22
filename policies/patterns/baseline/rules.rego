# METADATA
# title: Allowed configuration — region lock
# description: |
#   The AWS provider must target ca-central-1. This is defense-in-depth: the
#   region-lock SCP (infra/org) is the authoritative control; this rule catches a
#   literal mis-region in the provider config before apply.
# custom:
#   pattern: allowed-configuration
#   severity: high
#   controls:
#     osfi_b13: "Cyber Security – Infrastructure security"
#     gc_guardrail: "GR05"
package patterns.baseline

import data.shared
import rego.v1

allowed_region := "ca-central-1"

deny contains msg if {
	provs := object.get(object.get(input, "configuration", {}), "provider_config", {})
	some prov in provs
	prov.name == "aws"
	region := object.get(object.get(prov, "expressions", {}), "region", {})
	cv := object.get(region, "constant_value", "")
	cv != ""
	cv != allowed_region
	msg := shared.message(
		sprintf("provider.%s", [prov.name]),
		sprintf("region %q is not the allowed %q (SCP is authoritative; this is defense-in-depth)", [cv, allowed_region]),
		"Cyber Security – Infrastructure security",
		"GR05",
	)
}
