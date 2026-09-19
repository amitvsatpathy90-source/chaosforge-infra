package main_test

import data.main
import rego.v1

# This test calls:
#   policy/s3_egress_plan.rego -> main.deny
#
# Input represents:
#   - ECS service uses security group sg-edge
#   - S3 egress rule exists, but belongs to sg-other
#
# Expected business result:
#   sg-edge is not covered -> main.deny produces 1 message
test_denies_uncovered_sg if {
	msgs := main.deny with input as {
		"planned_values": {"root_module": {
			"resources": [
				{
					"type": "aws_ecs_service",
					"values": {
						"network_configuration": [
							{
								"security_groups": [
									"sg-edge",
								],
							},
						],
					},
				},
				{
					"type": "aws_vpc_security_group_egress_rule",
					"values": {
						"security_group_id": "sg-other",
						"prefix_list_id": "pl-1234",
						"from_port": 443,
						"to_port": 443,
					},
				},
			],
		}},
	}

	count(msgs) == 1
}

# This test calls:
#   policy/s3_egress_plan.rego -> main.deny
#
# Input represents:
#   - ECS service uses security group sg-edge
#   - S3 egress rule belongs to sg-edge
#   - the rule covers port 443
#
# Expected business result:
#   sg-edge is covered -> main.deny produces 0 messages
test_passes_when_covered if {
	msgs := main.deny with input as {
		"planned_values": {
			"root_module": {
				"resources": [
					{
						"type": "aws_ecs_service",
						"values": {
							"network_configuration": [
								{
									"security_groups": [
										"sg-edge",
									],
								},
							],
						},
					},
					{
						"type": "aws_vpc_security_group_egress_rule",
						"values": {
							"security_group_id": "sg-edge",
							"prefix_list_id": "pl-1234",
							"from_port": 443,
							"to_port": 443,
						},
					},
				],
			},
		},
	}

	count(msgs) == 0
}
