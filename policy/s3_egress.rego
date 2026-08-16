# conftest gate for R1 (Fargate needs S3 egress to pull image layers). Run with --combine:
#   conftest test --parser hcl2 --combine --policy policy/s3_egress.rego chaosforge/*.tf
# PRESENCE gate only, not per-SG coverage — asserts a root with ECS services also declares an
# S3-prefix-list egress rule; can't prove every SG is covered. Use s3_egress_plan.rego for that.

package main

import future.keywords.contains
import future.keywords.if
import future.keywords.in

# --combine input shape: [ {path: "...", contents: {resource: {...}}}, ... ]
# hcl2 parser shape: resource.<type>.<name> is a LIST of block bodies, so iterate the instances
# rather than index by name (indexing a list by a string name returns undefined -> always-empty set
# -> an always-red gate; that bug was caught by the with-fix fixture during verification).
runs_ecs_tasks if {
	some f in input
	f.contents.resource.aws_ecs_service
}

s3_layer_egress contains name if {
	some f in input
	some name, instances in f.contents.resource.aws_vpc_security_group_egress_rule
	some body in instances
	body.prefix_list_id
	body.from_port <= 443
	body.to_port >= 443
}

deny contains msg if {
	runs_ecs_tasks
	count(s3_layer_egress) == 0
	msg := "R1: this root runs Fargate tasks but declares no aws_vpc_security_group_egress_rule with a prefix_list_id (S3) on 443. ECR serves image layers from S3 over the gateway endpoint; with the provider's default-egress removal every task SG is deny-all-egress, so image pulls time out (CannotPullContainerError). Add the S3-prefix-list egress rule (audit F1/F2), keyed on local.all_task_security_groups."
}
