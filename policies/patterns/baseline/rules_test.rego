package patterns.baseline_test

import data.patterns.baseline
import rego.v1

_provider(region) := {"configuration": {"provider_config": {"aws": {
	"name": "aws",
	"expressions": {"region": {"constant_value": region}},
}}}}

test_wrong_region_denied if {
	count(baseline.deny) == 1 with input as _provider("us-east-1")
}

test_correct_region_allowed if {
	count(baseline.deny) == 0 with input as _provider("ca-central-1")
}
