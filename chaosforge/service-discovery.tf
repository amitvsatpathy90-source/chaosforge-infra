# DNS: <key>.chaosforge.internal. edge-gateway registered for Prometheus scraping only —
# client traffic still enters via ALB/public IP.

locals {
  chaosforge_discoverable_services = [
    "edge-gateway",
    "control-plane",
    "execution-service",
    "postgres",
    "redis",
    "redpanda",
  ]
}

resource "aws_service_discovery_service" "chaosforge" {
  for_each = toset(local.chaosforge_discoverable_services)
  name     = each.value

  dns_config {
    namespace_id = data.terraform_remote_state.foundation.outputs.chaosforge_service_discovery_namespace_id
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
