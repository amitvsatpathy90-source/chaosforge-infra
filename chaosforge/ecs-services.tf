# desired_count 0 by default — apply alone does not spend on compute. ALB/NAT/EFS still bill
# regardless; true zero-cost needs `terraform destroy`, not just scaling to 0.
variable "desired_count" {
  description = "Task count for every chaosforge ECS service. 0 = provisioned but not running (default); bump to start a session."
  type        = number
  default     = 0
}

resource "aws_ecs_service" "chaosforge_data" {
  for_each        = local.chaosforge_data_containers
  name            = "chaosforge-${each.key}"
  cluster         = data.terraform_remote_state.foundation.outputs.ecs_cluster_id
  task_definition = aws_ecs_task_definition.chaosforge_data[each.key].arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  # 0/100 forces stop-then-start (never start-then-stop) — avoids a two-writer window against
  # the shared EFS data directory (Fargate local persistent storage topology).
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  network_configuration {
    subnets         = local.private_subnet_ids
    security_groups = [local.chaosforge_stateful_services[each.key].sg_id]
  }

  service_registries {
    registry_arn = aws_service_discovery_service.chaosforge[each.key].arn
  }
}

resource "aws_ecs_service" "control_plane" {
  name            = "chaosforge-control-plane"
  cluster         = data.terraform_remote_state.foundation.outputs.ecs_cluster_id
  task_definition = aws_ecs_task_definition.chaosforge_app["control-plane"].arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = local.private_subnet_ids
    security_groups = [aws_security_group.control_plane.id]
  }

  service_registries {
    registry_arn = aws_service_discovery_service.chaosforge["control-plane"].arn
  }
}

resource "aws_ecs_service" "execution_service" {
  name            = "chaosforge-execution-service"
  cluster         = data.terraform_remote_state.foundation.outputs.ecs_cluster_id
  task_definition = aws_ecs_task_definition.chaosforge_app["execution-service"].arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = local.private_subnet_ids
    security_groups = [aws_security_group.execution_service.id]
  }

  service_registries {
    registry_arn = aws_service_discovery_service.chaosforge["execution-service"].arn
  }
}

resource "aws_ecs_service" "edge_gateway" {
  name            = "chaosforge-edge-gateway"
  cluster         = data.terraform_remote_state.foundation.outputs.ecs_cluster_id
  task_definition = aws_ecs_task_definition.chaosforge_app["edge-gateway"].arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  # Two ingress modes (Module 5.5 — see alb.tf):
  #   enable_alb=false (default): task in the PUBLIC subnet with its own public IP — ~$0 idle,
  #     IPv4 bills only while the task runs. The gateway still does JWT auth; the SG still gates
  #     ingress to gateway_ingress_cidr.
  #   enable_alb=true: task in the private subnet behind the ALB — the production-shaped posture.
  network_configuration {
    subnets          = var.enable_alb ? local.private_subnet_ids : local.public_subnet_ids
    security_groups  = [aws_security_group.edge_gateway.id]
    assign_public_ip = !var.enable_alb
  }

  dynamic "load_balancer" {
    for_each = var.enable_alb ? [1] : []
    content {
      target_group_arn = aws_lb_target_group.edge_gateway[0].arn
      container_name   = "edge-gateway"
      container_port   = 8080
    }
  }

  # Module 6: registered so Prometheus can resolve edge-gateway.chaosforge.internal — scrape
  # traffic only; client ingress is still the ALB/public IP.
  service_registries {
    registry_arn = aws_service_discovery_service.chaosforge["edge-gateway"].arn
  }

  depends_on = [aws_lb_listener.edge_gateway_https, aws_lb_listener.edge_gateway_http_redirect]
}
