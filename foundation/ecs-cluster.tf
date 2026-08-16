# One shared cluster, not one per system — ECS clusters are free (billing
# is per-task, not per-cluster), so the only question is operational
# clarity. A shared cluster keeps Module 8's FIS experiments simpler (one
# place to target tasks in either system) and matches the shared-VPC
# precedent from Module 2.

# Container Insights is a variable, defaulting OFF. The default keeps the near-$0 idle contract
# (Insights bills per observed metric + log ingestion, per-task); flip to "enhanced" for real
# per-task CPU/mem/restart/OOM visibility in an environment where that telemetry is worth the spend.
# The self-hosted Prometheus (foundation/observability.tf) covers APPLICATION metrics; Insights is
# the only source of TASK-level resource signals, since Fargate exposes no node exporter.
variable "container_insights" {
  description = "ECS Container Insights: disabled (default, $0) | enabled | enhanced. 'enhanced' adds per-task telemetry at a per-metric cost."
  type        = string
  default     = "disabled"

  validation {
    condition     = contains(["disabled", "enabled", "enhanced"], var.container_insights)
    error_message = "container_insights must be one of: disabled, enabled, enhanced."
  }
}

resource "aws_ecs_cluster" "platform" {
  name = "chaosforge-platform"

  setting {
    name  = "containerInsights"
    value = var.container_insights
  }
}

# Two namespaces (not one shared) — both systems reuse names like "postgres"/"redis"; would collide.
# Plain Cloud Map, not Service Connect — no per-task Envoy sidecar overhead needed at this scale.
resource "aws_service_discovery_private_dns_namespace" "chaosforge" {
  name = "chaosforge.internal"
  vpc  = aws_vpc.platform.id
}

resource "aws_service_discovery_private_dns_namespace" "rpe" {
  name = "rpe.internal"
  vpc  = aws_vpc.platform.id
}
