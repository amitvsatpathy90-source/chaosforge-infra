# <key>.rpe.internal. Kafka-only inter-service (ADR-17), so registration is for the Prometheus
# scraper (all four services), not for siblings, internal ingress only.

locals {
  rpe_discoverable_services = [
    "postgres",
    "redis",
    "redpanda",
    "detection", # also resolved by ChaosForge's steady-state probe (C20)
    "relay",
    "alert",
    "triage",
  ]
}

resource "aws_service_discovery_service" "rpe" {
  for_each = toset(local.rpe_discoverable_services)
  name     = each.value

  dns_config {
    namespace_id = data.terraform_remote_state.foundation.outputs.rpe_service_discovery_namespace_id
    dns_records {
      ttl  = 10
      type = "A"
    }
    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}
