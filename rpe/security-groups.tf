# Bare SG shells, all rules as separate aws_vpc_security_group_*_rule resources (same style as
# chaosforge/security-groups.tf). RPE has zero public HTTP surface. Ports verified against source:
# detection 8080, triage 8081, relay 8082, alert 8083, postgres 5432, redis 6379, redpanda 9092.
# Inter-service comms Kafka-only (ADR-17) - no ingress between the four app SGs.

resource "aws_security_group" "detection" {
  name_prefix = "rpe-detection-"
  vpc_id      = local.vpc_id
  description = "rpe-detection-service. No ingress except the cross-system steady-state probe rule below."
}

resource "aws_security_group" "relay" {
  name_prefix = "rpe-relay-"
  vpc_id      = local.vpc_id
  description = "rpe-relay-service. Outbox poller + Kafka producer only - no ingress."
}

resource "aws_security_group" "alert" {
  name_prefix = "rpe-alert-"
  vpc_id      = local.vpc_id
  description = "rpe-alert-service. Kafka consumer only - no ingress."
}

resource "aws_security_group" "triage" {
  name_prefix = "rpe-triage-"
  vpc_id      = local.vpc_id
  description = "rpe-triage-agent. Kafka consumer + outbound LLM call only - no ingress."
}

resource "aws_security_group" "postgres" {
  name_prefix = "rpe-postgres-"
  vpc_id      = local.vpc_id
  description = "CNPG Postgres - outbox/processed_alerts/triaged_alerts. Ingress from all four services (each owns disjoint tables/schemas, ADR-17 SS3.4/SS5.2)."
}

resource "aws_security_group" "redis" {
  name_prefix = "rpe-redis-"
  vpc_id      = local.vpc_id
  description = "Hot-path dedup/velocity/z-score/geo state (detection), agent tool lookups (triage). Ingress from detection and triage only - relay and alert never touch Redis."
}

resource "aws_security_group" "redpanda" {
  name_prefix = "rpe-redpanda-"
  vpc_id      = local.vpc_id
  description = "Kafka API. Ingress from all four services (each produces and/or consumes)."
}

# ── Ingress ─────────────────────────────────────────────────────────────

resource "aws_vpc_security_group_ingress_rule" "postgres_from_services" {
  for_each = {
    detection = aws_security_group.detection.id
    relay     = aws_security_group.relay.id
    alert     = aws_security_group.alert.id
    triage    = aws_security_group.triage.id
  }
  security_group_id            = aws_security_group.postgres.id
  referenced_security_group_id = each.value
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "redis_from_services" {
  # Triage also uses Redis (TriageTools.java, TriagedVerdictPublisher.java), not just detection -
  # Restricted ingress boundary for cross-service communication.
  for_each = {
    detection = aws_security_group.detection.id
    triage    = aws_security_group.triage.id
  }
  security_group_id            = aws_security_group.redis.id
  referenced_security_group_id = each.value
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "redpanda_from_services" {
  for_each = {
    detection = aws_security_group.detection.id
    relay     = aws_security_group.relay.id
    alert     = aws_security_group.alert.id
    triage    = aws_security_group.triage.id
  }
  security_group_id            = aws_security_group.redpanda.id
  referenced_security_group_id = each.value
  from_port                    = 9092
  to_port                      = 9092
  ip_protocol                  = "tcp"
}

# ── Cross-system: ChaosForge's steady-state probe - both halves declared in
# chaosforge/security-groups.tf (ADR-0401). Do not re-add a remote-state read of chaosforge/ here.

# ── Egress ──────────────────────────────────────────────────────────────

locals {
  rpe_task_security_groups = {
    detection = aws_security_group.detection.id
    relay     = aws_security_group.relay.id
    alert     = aws_security_group.alert.id
    triage    = aws_security_group.triage.id
  }

  # All task-backing SGs (app + data tier) for baseline DNS/ECR/S3 egress. Separate from
  # rpe_task_security_groups to avoid granting unwanted postgres<->redpanda cross-egress. R1 fix:
  # data-tier SGs previously had no egress at all, not even DNS/ECR.
  all_task_security_groups = merge(
    local.rpe_task_security_groups,
    { for k, v in local.rpe_stateful_services : k => v.sg_id }
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

resource "aws_vpc_security_group_egress_rule" "services_to_postgres" {
  for_each                     = local.rpe_task_security_groups
  security_group_id            = each.value
  referenced_security_group_id = aws_security_group.postgres.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "services_to_redpanda" {
  for_each                     = local.rpe_task_security_groups
  security_group_id            = each.value
  referenced_security_group_id = aws_security_group.redpanda.id
  from_port                    = 9092
  to_port                      = 9092
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "redis_consumers_egress" {
  for_each = {
    detection = aws_security_group.detection.id
    triage    = aws_security_group.triage.id
  }
  security_group_id            = each.value
  referenced_security_group_id = aws_security_group.redis.id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
}

# ── Lab IdP stub (foundation/jwks-stub.tf) - ADR-0404. Runtime dep only: services boot and 401
# (fail-closed) without it, not crashloop. Egress declared here, one-way foundation->child read.
resource "aws_vpc_security_group_egress_rule" "services_to_jwks_stub" {
  for_each                     = local.rpe_task_security_groups
  security_group_id            = each.value
  referenced_security_group_id = local.jwks_stub_security_group_id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
  description                  = "JWKS fetch at boot - jwks-stub.observability.internal (ADR-19 decoder construction)"
}

# ── Prometheus scrape ingress (Module 6) ─────────────────────────────────
# Same pattern as chaosforge/security-groups.tf. These scrapes will show DOWN until the RPE IdP
# follow-up lands (ADR-19 fail-closed - the services themselves don't boot without an issuer);
# the L4 path is wired now so the IdP is the only remaining piece.
resource "aws_vpc_security_group_ingress_rule" "scrape_from_prometheus" {
  for_each = {
    detection = { sg = aws_security_group.detection.id, port = 8080 }
    relay     = { sg = aws_security_group.relay.id, port = 8082 }
    alert     = { sg = aws_security_group.alert.id, port = 8083 }
    triage    = { sg = aws_security_group.triage.id, port = 8081 }
  }
  security_group_id            = each.value.sg
  referenced_security_group_id = data.terraform_remote_state.foundation.outputs.prometheus_security_group_id
  from_port                    = each.value.port
  to_port                      = each.value.port
  ip_protocol                  = "tcp"
  description                  = "Prometheus /actuator/prometheus scrape (JWT-gated at the app, ADR-19)"
}

# Resolved (was an open gap through Module 3): rpe-triage-agent calls
# OpenAI's real hosted API (spring.ai.openai, model gpt-4o-mini - verified
# against application.yml, not assumed), not a self-hosted model. The NAT
# Gateway added earlier in Module 4 (foundation/network.tf) provides the
# routing; this is the SG-level permission, scoped to triage only - no
# other RPE service gets general internet egress.
resource "aws_vpc_security_group_egress_rule" "triage_to_internet_https" {
  security_group_id = aws_security_group.triage.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "OpenAI API (ADR-15) - only RPE service with general internet egress"
}
