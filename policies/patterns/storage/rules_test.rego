package patterns.storage_test

import data.patterns.storage
import rego.v1

_plan(rc) := {"resource_changes": [rc]}

test_bpa_all_true_allowed if {
	count(storage.deny) == 0 with input as _plan({
		"address": "aws_s3_bucket_public_access_block.good",
		"type": "aws_s3_bucket_public_access_block",
		"change": {"actions": ["create"], "after": {
			"block_public_acls": true,
			"ignore_public_acls": true,
			"block_public_policy": true,
			"restrict_public_buckets": true,
		}},
	})
}

test_bpa_missing_flag_denied if {
	count(storage.deny) == 1 with input as _plan({
		"address": "aws_s3_bucket_public_access_block.bad",
		"type": "aws_s3_bucket_public_access_block",
		"change": {"actions": ["create"], "after": {
			"block_public_acls": true,
			"ignore_public_acls": false,
			"block_public_policy": true,
			"restrict_public_buckets": true,
		}},
	})
}

test_public_acl_denied if {
	count(storage.deny) == 1 with input as _plan({
		"address": "aws_s3_bucket_acl.bad",
		"type": "aws_s3_bucket_acl",
		"change": {"actions": ["create"], "after": {"acl": "public-read"}},
	})
}

test_private_acl_allowed if {
	count(storage.deny) == 0 with input as _plan({
		"address": "aws_s3_bucket_acl.good",
		"type": "aws_s3_bucket_acl",
		"change": {"actions": ["create"], "after": {"acl": "private"}},
	})
}
