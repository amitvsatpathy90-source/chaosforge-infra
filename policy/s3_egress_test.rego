package main_test

import rego.v1
import data.main

# This test calls:
#   policy/s3_egress.rego -> main.deny
#
# Input represents:
#   - an ECS service exists
#   - NO S3 egress rule exists
#
# Expected business result:
#   main.deny produces 1 message
test_denies_when_no_s3_egress_rule if {
	msgs := main.deny with input as [{
		"contents": {
			"resource": {
				"aws_ecs_service": {
					"main": [{}]
				}
			}
		}
	}]

	count(msgs) == 1
}


# This test calls:
#   policy/s3_egress.rego -> main.deny
#
# Input represents:
#   - an ECS service exists
#   - an S3 prefix-list egress rule exists
#   - the rule covers port 443
#
# Expected business result:
#   main.deny produces 0 messages
test_passes_when_s3_egress_rule_present if {
	msgs := main.deny with input as [{
		"contents": {
			"resource": {
				"aws_ecs_service": {
					"main": [{}]
				},
				"aws_vpc_security_group_egress_rule": {
					"s3_image_layers": [
						{
							"prefix_list_id": "pl-1234",
							"from_port": 443,
							"to_port": 443
						}
					]
				}
			}
		}
	}]

	count(msgs) == 0
}
