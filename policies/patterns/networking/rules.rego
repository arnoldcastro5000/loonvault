# METADATA
# title: Network exposure restriction
# description: |
#   Administrative ports (SSH/RDP) must not be reachable from the internet, and
#   database ingress must be security-group-to-security-group (no CIDR). Covers
#   inline aws_security_group ingress, standalone aws_security_group_rule, and
#   the newer aws_vpc_security_group_ingress_rule.
# custom:
#   pattern: exposure-restriction
#   severity: critical
#   controls:
#     osfi_b13: "Cyber Security – Infrastructure security"
package patterns.networking

import data.shared
import rego.v1

admin_ports := {22, 3389}

db_ports := {5432}

open_cidrs := {"0.0.0.0/0", "::/0"}

osfi := "Cyber Security – Infrastructure security"

# --- 1. No public ingress to administrative ports (22/3389) ---

# standalone aws_security_group_rule
deny contains msg if {
	some r in shared.managed("aws_security_group_rule")
	r.after.type == "ingress"
	_covers(r.after, admin_ports)
	some cidr in _rule_cidrs(r.after)
	cidr in open_cidrs
	msg := shared.message(r.address, "administrative port (22/3389) open to the internet", osfi, "-")
}

# inline ingress on aws_security_group
deny contains msg if {
	some r in shared.managed("aws_security_group")
	some ing in shared.as_array(object.get(r.after, "ingress", []))
	_covers(ing, admin_ports)
	some cidr in _block_cidrs(ing)
	cidr in open_cidrs
	msg := shared.message(r.address, "administrative port (22/3389) open to the internet (inline ingress)", osfi, "-")
}

# aws_vpc_security_group_ingress_rule
deny contains msg if {
	some r in shared.managed("aws_vpc_security_group_ingress_rule")
	_covers(r.after, admin_ports)
	some cidr in _vpc_rule_cidrs(r.after)
	cidr in open_cidrs
	msg := shared.message(r.address, "administrative port (22/3389) open to the internet", osfi, "-")
}

# --- 2. Database ingress must be SG-to-SG (no CIDR) ---

deny contains msg if {
	some r in shared.managed("aws_security_group_rule")
	r.after.type == "ingress"
	_covers(r.after, db_ports)
	count(_rule_cidrs(r.after)) > 0
	msg := shared.message(r.address, "database ingress (5432) must be SG-to-SG, not CIDR-based", osfi, "-")
}

deny contains msg if {
	some r in shared.managed("aws_vpc_security_group_ingress_rule")
	_covers(r.after, db_ports)
	count(_vpc_rule_cidrs(r.after)) > 0
	msg := shared.message(r.address, "database ingress (5432) must be SG-to-SG, not CIDR-based", osfi, "-")
}

# --- helpers ---

# _covers is true if the rule's port range includes any of `ports`.
_covers(obj, ports) if {
	some p in ports
	_port_in_range(object.get(obj, "from_port", null), object.get(obj, "to_port", null), p)
}

_port_in_range(from_port, to_port, p) if {
	is_number(from_port)
	is_number(to_port)
	from_port <= p
	to_port >= p
}

_rule_cidrs(after) := array.concat(
	shared.as_array(object.get(after, "cidr_blocks", [])),
	shared.as_array(object.get(after, "ipv6_cidr_blocks", [])),
)

_block_cidrs(ing) := array.concat(
	shared.as_array(object.get(ing, "cidr_blocks", [])),
	shared.as_array(object.get(ing, "ipv6_cidr_blocks", [])),
)

_vpc_rule_cidrs(after) := [c |
	some key in ["cidr_ipv4", "cidr_ipv6"]
	c := object.get(after, key, null)
	is_string(c)
]
