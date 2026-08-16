# Per-SG coverage gate for R1, against resolved plan JSON (SG ids concrete).
# STATUS: written, NOT yet exercised against real plan output — needs SGs already existing
# (unknowns from a from-clean plan break the matching). Validate before relying on it.
#   terraform -chdir=chaosforge plan -out=tf.plan <vars...> && terraform show -json tf.plan > plan.json
#   conftest test --policy policy/s3_egress_plan.rego plan.json

package main

import future.keywords.contains
import future.keywords.if
import future.keywords.in

resources := input.planned_values.root_module.resources

# SG ids referenced by any ECS service (post-resolution these are concrete "sg-..." strings).
task_sg_ids contains sg if {
	some r in resources
	r.type == "aws_ecs_service"
	some nc in r.values.network_configuration
	some sg in nc.security_groups
}

# SG ids that DO have a 443 prefix-list egress rule.
covered_sg_ids contains sg if {
	some r in resources
	r.type == "aws_vpc_security_group_egress_rule"
	r.values.prefix_list_id
	r.values.from_port <= 443
	r.values.to_port >= 443
	sg := r.values.security_group_id
}

deny contains msg if {
	some sg in task_sg_ids
	not sg in covered_sg_ids
	msg := sprintf("R1: task security group %v has no S3 prefix-list egress on 443 — Fargate cannot pull image layers. Add an aws_vpc_security_group_egress_rule (audit F1/F2).", [sg])
}
