package patterns.networking_test

import data.patterns.networking
import rego.v1

_plan(rc) := {"resource_changes": [rc]}

test_open_ssh_standalone_denied if {
	count(networking.deny) == 1 with input as _plan({
		"address": "aws_security_group_rule.bad_ssh",
		"type": "aws_security_group_rule",
		"change": {"actions": ["create"], "after": {
			"type": "ingress",
			"from_port": 22,
			"to_port": 22,
			"protocol": "tcp",
			"cidr_blocks": ["0.0.0.0/0"],
			"ipv6_cidr_blocks": [],
		}},
	})
}

test_sg_to_sg_ssh_allowed if {
	count(networking.deny) == 0 with input as _plan({
		"address": "aws_security_group_rule.good_ssh",
		"type": "aws_security_group_rule",
		"change": {"actions": ["create"], "after": {
			"type": "ingress",
			"from_port": 22,
			"to_port": 22,
			"protocol": "tcp",
			"cidr_blocks": [],
			"ipv6_cidr_blocks": [],
			"source_security_group_id": "sg-123",
		}},
	})
}

test_inline_open_rdp_denied if {
	count(networking.deny) == 1 with input as _plan({
		"address": "aws_security_group.bad",
		"type": "aws_security_group",
		"change": {"actions": ["create"], "after": {"ingress": [{
			"from_port": 3389,
			"to_port": 3389,
			"cidr_blocks": ["0.0.0.0/0"],
			"ipv6_cidr_blocks": [],
		}]}},
	})
}

test_vpc_ingress_open_ssh_denied if {
	count(networking.deny) == 1 with input as _plan({
		"address": "aws_vpc_security_group_ingress_rule.bad",
		"type": "aws_vpc_security_group_ingress_rule",
		"change": {"actions": ["create"], "after": {
			"from_port": 22,
			"to_port": 22,
			"ip_protocol": "tcp",
			"cidr_ipv4": "0.0.0.0/0",
		}},
	})
}

test_db_cidr_ingress_denied if {
	count(networking.deny) == 1 with input as _plan({
		"address": "aws_security_group_rule.bad_db",
		"type": "aws_security_group_rule",
		"change": {"actions": ["create"], "after": {
			"type": "ingress",
			"from_port": 5432,
			"to_port": 5432,
			"protocol": "tcp",
			"cidr_blocks": ["10.0.0.0/16"],
			"ipv6_cidr_blocks": [],
		}},
	})
}

test_db_sg_to_sg_allowed if {
	count(networking.deny) == 0 with input as _plan({
		"address": "aws_security_group_rule.good_db",
		"type": "aws_security_group_rule",
		"change": {"actions": ["create"], "after": {
			"type": "ingress",
			"from_port": 5432,
			"to_port": 5432,
			"protocol": "tcp",
			"cidr_blocks": [],
			"ipv6_cidr_blocks": [],
			"source_security_group_id": "sg-app",
		}},
	})
}

test_deleting_resource_ignored if {
	count(networking.deny) == 0 with input as _plan({
		"address": "aws_security_group_rule.deleting",
		"type": "aws_security_group_rule",
		"change": {"actions": ["delete"], "after": null},
	})
}
