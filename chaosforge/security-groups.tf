# Explicit minimal egress per SG via singular aws_vpc_security_group_*_rule resources (required -
# this root also attaches a rule to rpe/'s detection SG, which it doesn't own).
# Ports verified against source: gateway 8080, CP 8081, exec 8082, postgres 5432, redpanda 9092, redis 6379.

resource "aws_security_group" "alb" {
  name_prefix = "chaosforge-alb-"
  vpc_id      = local.vpc_id
  description = "Public-facing ALB. Only fronts the Edge Gateway - RPE has no public HTTP surface."
}

resource "aws_security_group" "edge_gateway" {
  name_prefix = "chaosforge-edge-gateway-"
  vpc_id      = local.vpc_id
  description = "Edge Gateway - the sole public ingress (mtls-rules.md)."
}

resource "aws_security_group" "control_plane" {
  name_prefix = "chaosforge-control-plane-"
  vpc_id      = local.vpc_id
  description = "Control Plane - ingress only from Edge Gateway (public JWT path) and Execution Service (mTLS /internal path)."
}

# No ingress from outside the VPC. Cross-system probe rule (both halves) is at bottom of file - ADR-0401.
resource "aws_security_group" "execution_service" {
  name_prefix = "chaosforge-execution-"
  vpc_id      = local.vpc_id
  description = "Execution Service - no ingress from outside the VPC."
}

# ── Data layer - split by resource, not one shared blob, so each ingress
# rule states exactly who talks to what on which port. ────────────────────

resource "aws_security_group" "postgres" {
  name_prefix = "chaosforge-postgres-"
  vpc_id      = local.vpc_id
  description = "chaosforge_cp + chaosforge_exec databases. Ingress from CP and Exec only."
}

resource "aws_security_group" "redpanda" {
  name_prefix = "chaosforge-redpanda-"
  vpc_id      = local.vpc_id
  description = "Kafka API. Ingress from CP (producer, outbox relay) and Exec (consumer) only."
}

resource "aws_security_group" "redis" {
  name_prefix = "chaosforge-redis-"
  vpc_id      = local.vpc_id
  description = "L2 cache (ADR-0504). Ingress from Control Plane only - Exec does not use Redis; Gateway is L1-Caffeine-only by rule (gateway-rules.md)."
}

# ── Ingress ─────────────────────────────────────────────────────────────

resource "aws_vpc_security_group_ingress_rule" "alb_from_internet_https" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "Public HTTPS ingress. TLS terminates at the ALB (ACM cert required - see alb.tf)."
}

# :80 reaches only the redirect listener, which 301s to :443. It never forwards to a target.
resource "aws_vpc_security_group_ingress_rule" "alb_from_internet_http_redirect" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  description       = "Public HTTP ingress, redirect-to-HTTPS only. No traffic is served over cleartext."
}

resource "aws_vpc_security_group_ingress_rule" "edge_gateway_from_alb" {
  security_group_id            = aws_security_group.edge_gateway.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
}

# ALB-less mode: gateway's public IP serves plain HTTP on 8080 (no TLS). No safe world-open
# value - 0.0.0.0/0 refused outright since a bearer JWT would cross the wire in cleartext.
# Enforces network isolation security invariants.
variable "gateway_ingress_cidr" {
  description = "CIDR allowed to reach the edge-gateway public IP on 8080 when enable_alb = false. Must be your own address, e.g. 203.0.113.7/32."
  type        = string
  default     = null

  validation {
    condition     = var.enable_alb || (var.gateway_ingress_cidr != null && var.gateway_ingress_cidr != "0.0.0.0/0")
    error_message = "ALB-less mode exposes the edge-gateway on a public IP over plain HTTP. Set gateway_ingress_cidr to your own address (e.g. \"203.0.113.7/32\"); 0.0.0.0/0 is refused, because a bearer JWT would cross the internet in cleartext to a world-open port."
  }
}

resource "aws_vpc_security_group_ingress_rule" "edge_gateway_public" {
  count             = var.enable_alb ? 0 : 1
  security_group_id = aws_security_group.edge_gateway.id
  cidr_ipv4         = var.gateway_ingress_cidr
  from_port         = 8080
  to_port           = 8080
  ip_protocol       = "tcp"
  description       = "Direct public ingress in ALB-less mode - plain HTTP, so scoped to the operator own CIDR"
}

resource "aws_vpc_security_group_ingress_rule" "cp_from_gateway" {
  security_group_id            = aws_security_group.control_plane.id
  referenced_security_group_id = aws_security_group.edge_gateway.id
  from_port                    = 8081
  to_port                      = 8081
  ip_protocol                  = "tcp"
  description                  = "Gateway to CP, public JWT path"
}

resource "aws_vpc_security_group_ingress_rule" "cp_from_exec" {
  security_group_id            = aws_security_group.control_plane.id
  referenced_security_group_id = aws_security_group.execution_service.id
  from_port                    = 8081
  to_port                      = 8081
  ip_protocol                  = "tcp"
  description                  = "Exec to CP, /internal path (mTLS; exec-cert-CN restricted in-app per ADR-0532)"
}

resource "aws_vpc_security_group_ingress_rule" "postgres_from_cp" {
  security_group_id            = aws_security_group.postgres.id
  referenced_security_group_id = aws_security_group.control_plane.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "postgres_from_exec" {
  security_group_id            = aws_security_group.postgres.id
  referenced_security_group_id = aws_security_group.execution_service.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "redpanda_from_cp" {
  security_group_id            = aws_security_group.redpanda.id
  referenced_security_group_id = aws_security_group.control_plane.id
  from_port                    = 9092
  to_port                      = 9092
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "redpanda_from_exec" {
  security_group_id            = aws_security_group.redpanda.id
  referenced_security_group_id = aws_security_group.execution_service.id
  from_port                    = 9092
  to_port                      = 9092
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "redis_from_cp" {
  security_group_id            = aws_security_group.redis.id
  referenced_security_group_id = aws_security_group.control_plane.id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
}

# ── Egress ──────────────────────────────────────────────────────────────
# Every task-bearing SG needs 443 to the VPC endpoints SG (ECR pull +
# CloudWatch Logs + Secrets Manager ride the task's own ENI in awsvpc mode)
# and DNS (53) to the VPC CIDR. Declared once via for_each rather than
# repeated per SG.

locals {
  # Every SG that backs a Fargate task ENI - app tier AND data tier. Originally app-tier-only
  # (edge_gateway/control_plane/execution_service); widened for R1 (audit finding) after tracing
  # the data-tier SGs and finding they had NO egress at all, not even DNS or ECR - postgres/
  # redis/redpanda couldn't pull their own images before this fix, a strictly worse gap than the
  # S3-layer-only problem R1 was originally scoped around.
  all_task_security_groups = merge(
    {
      edge_gateway      = aws_security_group.edge_gateway.id
      control_plane     = aws_security_group.control_plane.id
      execution_service = aws_security_group.execution_service.id
    },
    { for k, v in local.chaosforge_stateful_services : k => v.sg_id }
  )
}

resource "aws_vpc_security_group_egress_rule" "https_to_vpc_endpoints" {
  for_each                     = local.all_task_security_groups
  security_group_id            = each.value
  referenced_security_group_id = local.vpc_endpoints_security_group_id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

# ── Lab IdP stub (foundation/jwks-stub.tf) - ADR-0404. Runtime dep only: without it, services
# boot and 401 (fail-closed), not crashloop. Data tier excluded (no JWT surface).
resource "aws_vpc_security_group_egress_rule" "services_to_jwks_stub" {
  for_each = {
    edge_gateway      = aws_security_group.edge_gateway.id
    control_plane     = aws_security_group.control_plane.id
    execution_service = aws_security_group.execution_service.id
  }
  security_group_id            = each.value
  referenced_security_group_id = local.jwks_stub_security_group_id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
  description                  = "JWKS fetch at boot - jwks-stub.observability.internal (SecurityConfig decoder construction)"
}

resource "aws_vpc_security_group_egress_rule" "dns_udp" {
  for_each          = local.all_task_security_groups
  security_group_id = each.value
  cidr_ipv4         = local.vpc_cidr
  from_port         = 53
  to_port           = 53
  ip_protocol       = "udp"
}

resource "aws_vpc_security_group_egress_rule" "dns_tcp" {
  for_each          = local.all_task_security_groups
  security_group_id = each.value
  cidr_ipv4         = local.vpc_cidr
  from_port         = 53
  to_port           = 53
  ip_protocol       = "tcp"
}

# R1 fix: the S3 Gateway endpoint has no ENI/SG (unlike ecr.api/ecr.dkr above) - it's reached via
# prefix list only. ECR serves image layers from S3; without this every task in this root times
# out on CannotPullContainerError once past the manifest/auth handshake.
resource "aws_vpc_security_group_egress_rule" "s3_image_layers" {
  for_each          = local.all_task_security_groups
  security_group_id = each.value
  prefix_list_id    = local.s3_prefix_list_id
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "S3 gateway endpoint - ECR serves image layers from S3, not ecr.dkr (R1 fix)"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_edge_gateway" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.edge_gateway.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "edge_gateway_to_cp" {
  security_group_id            = aws_security_group.edge_gateway.id
  referenced_security_group_id = aws_security_group.control_plane.id
  from_port                    = 8081
  to_port                      = 8081
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "cp_to_postgres" {
  security_group_id            = aws_security_group.control_plane.id
  referenced_security_group_id = aws_security_group.postgres.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "cp_to_redpanda" {
  security_group_id            = aws_security_group.control_plane.id
  referenced_security_group_id = aws_security_group.redpanda.id
  from_port                    = 9092
  to_port                      = 9092
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "cp_to_redis" {
  security_group_id            = aws_security_group.control_plane.id
  referenced_security_group_id = aws_security_group.redis.id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
}

# Resolved (was open through Module 3): Ollama is deliberately NOT deployed to AWS (see README's
# "Known deviations" - it's opt-in even locally, exceeds the compose memory budget on purpose). CP's
# AI-authoring feature is unavailable in this deployment by decision, not by a forgotten SG hole.
# No egress rule needed here as a result.

resource "aws_vpc_security_group_egress_rule" "exec_to_cp" {
  security_group_id            = aws_security_group.execution_service.id
  referenced_security_group_id = aws_security_group.control_plane.id
  from_port                    = 8081
  to_port                      = 8081
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "exec_to_postgres" {
  security_group_id            = aws_security_group.execution_service.id
  referenced_security_group_id = aws_security_group.postgres.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "exec_to_redpanda" {
  security_group_id            = aws_security_group.execution_service.id
  referenced_security_group_id = aws_security_group.redpanda.id
  from_port                    = 9092
  to_port                      = 9092
  ip_protocol                  = "tcp"
}

# ── Prometheus scrape ingress (Module 6) ─────────────────────────────────
# The shared observability stack lives in foundation/ (its rationale there); each system grants
# scrape ingress on its own services, in its own state - same one-way read direction as everything
# else. CP/Exec scrapes arrive as mTLS (prometheus presents its own internal-CA client identity);
# this rule is the L4 half, the TLS handshake is the real gate.
resource "aws_vpc_security_group_ingress_rule" "scrape_from_prometheus" {
  for_each = {
    edge_gateway      = { sg = aws_security_group.edge_gateway.id, port = 8080 }
    control_plane     = { sg = aws_security_group.control_plane.id, port = 8081 }
    execution_service = { sg = aws_security_group.execution_service.id, port = 8082 }
  }
  security_group_id            = each.value.sg
  referenced_security_group_id = data.terraform_remote_state.foundation.outputs.prometheus_security_group_id
  from_port                    = each.value.port
  to_port                      = each.value.port
  ip_protocol                  = "tcp"
  description                  = "Prometheus /actuator/prometheus scrape"
}

# ── Cross-system: ChaosForge's steady-state probe (both halves declared here) - ADR-0401.
resource "aws_vpc_security_group_egress_rule" "exec_to_rpe_detection_actuator" {
  security_group_id            = aws_security_group.execution_service.id
  referenced_security_group_id = var.rpe_detection_security_group_id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
  description                  = "ChaosForge execution-service to RPE detection actuator (steady-state probe only, C20)"
}

resource "aws_vpc_security_group_ingress_rule" "rpe_detection_from_exec" {
  security_group_id            = var.rpe_detection_security_group_id
  referenced_security_group_id = aws_security_group.execution_service.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
  description                  = "ChaosForge execution-service to RPE detection actuator (steady-state probe only, C20)"
}
