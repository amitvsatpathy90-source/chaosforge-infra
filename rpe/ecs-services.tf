# Same on-demand mechanic as chaosforge/ecs-services.tf: desired_count
# defaults to 0. Same caveat: EFS and the NAT Gateway still bill
# regardless of this being 0 — see chaosforge/ecs-services.tf's note and
# Module 9.
variable "desired_count" {
  description = "Task count for every RPE ECS service. 0 = provisioned but not running (default); bump to start a session."
  type        = number
  default     = 0
}

resource "aws_ecs_service" "rpe_data" {
  for_each        = local.rpe_data_containers
  name            = "rpe-${each.key}"
  cluster         = data.terraform_remote_state.foundation.outputs.ecs_cluster_id
  task_definition = aws_ecs_task_definition.rpe_data[each.key].arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  # Stop-then-start, never start-then-stop — same reasoning as chaosforge/ecs-services.tf. These
  # tasks mount a shared EFS access point as their data directory (postgres PGDATA, redpanda's log
  # dir, redis AOF). ECS's service defaults (100/200) would run the replacement task alongside the
  # old one on a task-definition change, opening a two-writer window on a shared filesystem.
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  network_configuration {
    subnets         = local.private_subnet_ids
    security_groups = [local.rpe_stateful_services[each.key].sg_id]
  }

  service_registries {
    registry_arn = aws_service_discovery_service.rpe[each.key].arn
  }
}

locals {
  rpe_app_security_groups = {
    detection = aws_security_group.detection.id
    relay     = aws_security_group.relay.id
    alert     = aws_security_group.alert.id
    triage    = aws_security_group.triage.id
  }
}

resource "aws_ecs_service" "rpe_app" {
  for_each        = local.rpe_app_services
  name            = "rpe-${each.key}"
  cluster         = data.terraform_remote_state.foundation.outputs.ecs_cluster_id
  task_definition = aws_ecs_task_definition.rpe_app[each.key].arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = local.private_subnet_ids
    security_groups = [local.rpe_app_security_groups[each.key]]
  }

  # Module 6: all four registered — Prometheus scrapes each by name (Module 4's "nothing queries
  # relay/alert/triage" stopped being true the moment the observability stack landed).
  service_registries {
    registry_arn = aws_service_discovery_service.rpe[each.key].arn
  }
}
