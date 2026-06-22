package patterns.storage_test

import data.patterns.storage
import rego.v1

_plan(rc) := {"resource_changes": [rc]}

_policy_plan(pol) := {"resource_changes": [{
	"address": "aws_s3_bucket_policy.p",
	"type": "aws_s3_bucket_policy",
	"change": {"actions": ["create"], "after": {"policy": json.marshal(pol)}},
}]}

# --- rule 1: BPA flags ---

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

# --- rule 2: public ACL ---

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

# --- rule 3: bucket must have a BPA (gap #1) ---

test_bucket_without_bpa_denied if {
	count(storage.deny) == 1 with input as {
		"configuration": {"root_module": {"resources": [{
			"address": "aws_s3_bucket.lonely",
			"type": "aws_s3_bucket",
			"expressions": {},
		}]}},
		"resource_changes": [{
			"address": "aws_s3_bucket.lonely",
			"type": "aws_s3_bucket",
			"change": {"actions": ["create"], "after": {"bucket": "lonely-bucket"}},
		}],
	}
}

test_bucket_with_bpa_allowed if {
	count(storage.deny) == 0 with input as {
		"configuration": {"root_module": {"resources": [
			{"address": "aws_s3_bucket.ok", "type": "aws_s3_bucket", "expressions": {}},
			{
				"address": "aws_s3_bucket_public_access_block.ok",
				"type": "aws_s3_bucket_public_access_block",
				"expressions": {"bucket": {"references": ["aws_s3_bucket.ok.id", "aws_s3_bucket.ok"]}},
			},
		]}},
		"resource_changes": [
			{
				"address": "aws_s3_bucket.ok", "type": "aws_s3_bucket",
				"change": {"actions": ["create"], "after": {"bucket": "ok-bucket"}},
			},
			{
				"address": "aws_s3_bucket_public_access_block.ok",
				"type": "aws_s3_bucket_public_access_block",
				"change": {"actions": ["create"], "after": {
					"block_public_acls": true,
					"ignore_public_acls": true,
					"block_public_policy": true,
					"restrict_public_buckets": true,
				}},
			},
		],
	}
}

# --- rule 4: public bucket policy (gap #2) ---

test_public_bucket_policy_denied if {
	count(storage.deny) == 1 with input as _policy_plan({
		"Version": "2012-10-17",
		"Statement": [{
			"Effect": "Allow", "Principal": "*",
			"Action": "s3:GetObject", "Resource": "arn:aws:s3:::b/*",
		}],
	})
}

test_principal_aws_wildcard_array_denied if {
	count(storage.deny) == 1 with input as _policy_plan({
		"Version": "2012-10-17",
		"Statement": [{
			"Effect": "Allow",
			"Principal": {"AWS": ["partner-principal", "*"]},
			"Action": "s3:GetObject", "Resource": "arn:aws:s3:::b/*",
		}],
	})
}

test_deny_to_everyone_allowed if {
	count(storage.deny) == 0 with input as _policy_plan({
		"Version": "2012-10-17",
		"Statement": [{
			"Effect": "Deny", "Principal": "*",
			"Action": "s3:*", "Resource": "arn:aws:s3:::b/*",
			"Condition": {"Bool": {"aws:SecureTransport": "false"}},
		}],
	})
}

test_conditioned_public_allow_allowed if {
	count(storage.deny) == 0 with input as _policy_plan({
		"Version": "2012-10-17",
		"Statement": [{
			"Effect": "Allow", "Principal": "*",
			"Action": "s3:GetObject", "Resource": "arn:aws:s3:::b/*",
			"Condition": {"StringEquals": {"aws:SourceVpc": "vpc-123"}},
		}],
	})
}

test_service_principal_allow_allowed if {
	count(storage.deny) == 0 with input as _policy_plan({
		"Version": "2012-10-17",
		"Statement": [{
			"Effect": "Allow",
			"Principal": {"Service": "cloudtrail.amazonaws.com"},
			"Action": "s3:PutObject", "Resource": "arn:aws:s3:::b/*",
		}],
	})
}
