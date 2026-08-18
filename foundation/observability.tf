# Shared observability stack (Module 6): one Prometheus + one Grafana, derived images pinned to
# chaosforge's compose versions (prom v2.55.1, grafana 11.3.0). Managed alternatives rejected on
# cost (AMG $9/user/mo). Lives in foundation/ so both systems grant scrape ingress one-way. See
# README "Known deviations" (tracing not deployed).

variable "observability_desired_count" {
  description = "0 = provisioned, not running (default). Bump to 1 alongside the app stacks for a session."
  type        = number
  default     = 0
}

variable "grafana_ingress_cidr" {
  description = "CIDR allowed to reach Grafana's public IP on 3000. Recommend your own IP/32. Grafana requires the admin password either way (anonymous access is OFF in AWS - unlike local, this has a public IP)."
  type        = string
  default     = "0.0.0.0/0"
}

# ── Images ────────────────────────────────────────────────────────────────

resource "aws_ecr_repository" "observability" {
  for_each             = toset(["prometheus", "grafana"])
  name                 = "observability/${each.value}"
  image_tag_mutability = "MUTABLE" # derived-from-upstream tags, same convention as the data mirrors

  image_scanning_configuration {
    scan_on_push = true
  }
}

# ── Service discovery ─────────────────────────────────────────────────────

resource "aws_service_discovery_private_dns_namespace" "observability" {
  name = "observability.internal"
  vpc  = aws_vpc.platform.id
}

resource "aws_service_discovery_service" "prometheus" {
  name = "prometheus"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.observability.id
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

# ── Security groups ───────────────────────────────────────────────────────

resource "aws_security_group" "prometheus" {
  name_prefix = "observability-prometheus-"
  vpc_id      = aws_vpc.platform.id
  description = "Prometheus. No ingress except Grafana; egress VPC-wide (scrape targets live in chaosforge/rpe SGs whose IDs this state cannot reference without a circular read - targets are enumerated in prometheus.yml, the SG stays CIDR-scoped)."
}

resource "aws_security_group" "grafana" {
  name_prefix = "observability-grafana-"
  vpc_id      = aws_vpc.platform.id
  description = "Grafana. Public IP + admin password; ingress restricted to grafana_ingress_cidr."
}

resource "aws_vpc_security_group_ingress_rule" "prometheus_from_grafana" {
  security_group_id            = aws_security_group.prometheus.id
  referenced_security_group_id = aws_security_group.grafana.id
  from_port                    = 9090
  to_port                      = 9090
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "prometheus_vpc" {
  security_group_id = aws_security_group.prometheus.id
  cidr_ipv4         = var.vpc_cidr
  from_port         = 0
  to_port           = 65535
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "prometheus_dns" {
  security_group_id = aws_security_group.prometheus.id
  cidr_ipv4         = var.vpc_cidr
  from_port         = 53
  to_port           = 53
  ip_protocol       = "udp"
}

resource "aws_vpc_security_group_ingress_rule" "grafana_public" {
  security_group_id = aws_security_group.grafana.id
  cidr_ipv4         = var.grafana_ingress_cidr
  from_port         = 3000
  to_port           = 3000
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "grafana_to_prometheus" {
  security_group_id            = aws_security_group.grafana.id
  referenced_security_group_id = aws_security_group.prometheus.id
  from_port                    = 9090
  to_port                      = 9090
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "grafana_https_endpoints" {
  security_group_id            = aws_security_group.grafana.id
  referenced_security_group_id = aws_security_group.vpc_endpoints.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "grafana_dns" {
  security_group_id = aws_security_group.grafana.id
  cidr_ipv4         = var.vpc_cidr
  from_port         = 53
  to_port           = 53
  ip_protocol       = "udp"
}

# R1 fix: S3 Gateway endpoint has no ENI/SG, reached via prefix list only - required for image pulls.
# Every Fargate task foundation owns belongs in this map; add new tasks here, not a private copy.
locals {
  foundation_task_security_groups = {
    prometheus = aws_security_group.prometheus.id
    grafana    = aws_security_group.grafana.id
    jwks_stub  = aws_security_group.jwks_stub.id
  }
}

resource "aws_vpc_security_group_egress_rule" "s3_image_layers" {
  for_each          = local.foundation_task_security_groups
  security_group_id = each.value
  prefix_list_id    = aws_vpc_endpoint.s3.prefix_list_id
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "S3 gateway endpoint - ECR serves image layers from S3, not ecr.dkr (R1 fix)"
}

# ── mTLS material for scraping CP/Exec ────────────────────────────────────
# Prometheus's own internal-CA client identity (PEM - prometheus reads PEM, not .p12), generated
# by chaosforge's generate-certs.sh alongside the service keystores and copied here manually, same
# one-time step as chaosforge's mtls volume. ClientMount ONLY on the task role - prometheus reads
# certs, never writes.

resource "aws_efs_file_system" "observability_mtls" {
  creation_token = "observability-mtls"
  encrypted      = true
  tags           = { Name = "observability-mtls" }
}

resource "aws_efs_access_point" "observability_mtls" {
  file_system_id = aws_efs_file_system.observability_mtls.id

  posix_user {
    uid = 65534 # prom/prometheus runs as nobody
    gid = 65534
  }

  root_directory {
    path = "/obs-mtls"
    creation_info {
      owner_uid   = 65534
      owner_gid   = 65534
      permissions = "0755"
    }
  }

  tags = { Name = "observability-mtls" }
}

resource "aws_efs_mount_target" "observability_mtls" {
  for_each        = aws_subnet.private_chaosforge
  file_system_id  = aws_efs_file_system.observability_mtls.id
  subnet_id       = each.value.id
  security_groups = [aws_security_group.observability_efs.id]
}

resource "aws_security_group" "observability_efs" {
  name_prefix = "observability-efs-"
  vpc_id      = aws_vpc.platform.id
  description = "Mount targets for the prometheus mTLS-material volume."
}

resource "aws_vpc_security_group_ingress_rule" "efs_from_prometheus" {
  security_group_id            = aws_security_group.observability_efs.id
  referenced_security_group_id = aws_security_group.prometheus.id
  from_port                    = 2049
  to_port                      = 2049
  ip_protocol                  = "tcp"
}

# ── Grafana admin credential ──────────────────────────────────────────────

resource "random_password" "grafana_admin" {
  length  = 24
  special = false
}

resource "aws_ssm_parameter" "grafana_admin_password" {
  name  = "/observability/grafana-admin-password"
  type  = "SecureString"
  value = random_password.grafana_admin.result
}

# arch-audit F-02: was baked into the Prometheus image at build time (observability/build-push.sh),
# so a live bearer JWT sat in ECR layers that survive `terraform destroy`. Now injected at container
# start (entrypoint-prometheus.sh writes it to the file prometheus.yml's credentials_file reads).
# Default sentinel matches the RPE IdP follow-up's placeholder - targets show DOWN, not broken.
variable "prometheus_scrape_token" {
  description = "Bearer JWT with SCOPE_metrics:scrape for RPE's /actuator/prometheus (ADR-19). Mint with rpe/deploy/oauth/mint-jwt.sh --ttl 2592000. Default leaves rpe-* scrape targets DOWN, not broken."
  type        = string
  sensitive   = true
  default     = "idp-not-provisioned"
}

resource "aws_ssm_parameter" "prometheus_scrape_token" {
  name  = "/observability/prometheus-scrape-token"
  type  = "SecureString"
  value = var.prometheus_scrape_token
}

# ── IAM ───────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "obs_tasks_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "obs_execution" {
  name                 = "observability-execution"
  assume_role_policy   = data.aws_iam_policy_document.obs_tasks_assume.json
  permissions_boundary = aws_iam_policy.task_role_boundary.arn # R2 fix - see iam-task-role-boundary.tf
}

resource "aws_iam_role_policy_attachment" "obs_execution_managed" {
  role       = aws_iam_role.obs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "obs_execution_secrets" {
  statement {
    effect    = "Allow"
    actions   = ["ssm:GetParameters"]
    resources = [aws_ssm_parameter.grafana_admin_password.arn, aws_ssm_parameter.prometheus_scrape_token.arn]
  }
}

resource "aws_iam_role_policy" "obs_execution_secrets" {
  name   = "observability-execution-secrets"
  role   = aws_iam_role.obs_execution.id
  policy = data.aws_iam_policy_document.obs_execution_secrets.json
}

resource "aws_iam_role" "obs_task" {
  name                 = "observability-task"
  assume_role_policy   = data.aws_iam_policy_document.obs_tasks_assume.json
  permissions_boundary = aws_iam_policy.task_role_boundary.arn # R2 fix - see iam-task-role-boundary.tf
}

data "aws_iam_policy_document" "obs_task_efs" {
  statement {
    effect    = "Allow"
    actions   = ["elasticfilesystem:ClientMount"] # read-only - prometheus reads certs, never writes
    resources = [aws_efs_file_system.observability_mtls.arn]
  }
}

resource "aws_iam_role_policy" "obs_task_efs" {
  name   = "observability-task-efs"
  role   = aws_iam_role.obs_task.id
  policy = data.aws_iam_policy_document.obs_task_efs.json
}

# ── Logs / tasks / services ───────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "observability" {
  for_each          = toset(["prometheus", "grafana"])
  name              = "/observability/${each.value}"
  retention_in_days = 3
}

resource "aws_ecs_task_definition" "prometheus" {
  family                   = "observability-prometheus"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512 # compose mem_limit parity
  execution_role_arn       = aws_iam_role.obs_execution.arn
  task_role_arn            = aws_iam_role.obs_task.arn

  volume {
    name = "mtls"
    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.observability_mtls.id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.observability_mtls.id
        iam             = "ENABLED"
      }
    }
  }

  container_definitions = jsonencode([{
    name      = "prometheus"
    image     = "${aws_ecr_repository.observability["prometheus"].repository_url}:v2.55.1-obs2"
    essential = true
    # Compose-parity flags. TSDB is ephemeral task storage on purpose: 3d retention < session
    # length anyway, and destroy-per-session means history dies with the session regardless -
    # an EFS TSDB would be paying to persist data the workflow throws away.
    command      = ["--config.file=/etc/prometheus/prometheus.yml", "--storage.tsdb.retention.time=3d"]
    portMappings = [{ containerPort = 9090, protocol = "tcp" }]
    mountPoints  = [{ sourceVolume = "mtls", containerPath = "/mnt/mtls", readOnly = true }]
    # arch-audit F-02: entrypoint-prometheus.sh writes this to /etc/prometheus/scrape_token at
    # container start - command's args above still reach /bin/prometheus via the entrypoint's "$@".
    secrets = [
      { name = "PROM_SCRAPE_TOKEN", valueFrom = aws_ssm_parameter.prometheus_scrape_token.arn },
    ]
    healthCheck = {
      command     = ["CMD-SHELL", "wget -q -O- http://localhost:9090/-/healthy >/dev/null 2>&1 || exit 1"]
      interval    = 15
      timeout     = 5
      retries     = 5
      startPeriod = 10
    }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.observability["prometheus"].name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "prometheus"
      }
    }
  }])
}

resource "aws_ecs_task_definition" "grafana" {
  family                   = "observability-grafana"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.obs_execution.arn
  task_role_arn            = aws_iam_role.obs_task.arn

  container_definitions = jsonencode([{
    name         = "grafana"
    image        = "${aws_ecr_repository.observability["grafana"].repository_url}:11.3.0-obs1"
    essential    = true
    portMappings = [{ containerPort = 3000, protocol = "tcp" }]
    environment = [
      # Explicitly OFF - local compose enables anonymous Viewer, but local is loopback-only and
      # this task has a public IP. Deliberate divergence, documented in Dockerfile.grafana too.
      { name = "GF_AUTH_ANONYMOUS_ENABLED", value = "false" },
    ]
    secrets = [
      { name = "GF_SECURITY_ADMIN_PASSWORD", valueFrom = aws_ssm_parameter.grafana_admin_password.arn },
    ]
    healthCheck = {
      command     = ["CMD-SHELL", "wget -q -O- http://localhost:3000/api/health >/dev/null 2>&1 || exit 1"]
      interval    = 15
      timeout     = 5
      retries     = 5
      startPeriod = 15
    }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.observability["grafana"].name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "grafana"
      }
    }
  }])
}

resource "aws_ecs_service" "prometheus" {
  name            = "observability-prometheus"
  cluster         = aws_ecs_cluster.platform.id
  task_definition = aws_ecs_task_definition.prometheus.arn
  desired_count   = var.observability_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = [for s in aws_subnet.private_chaosforge : s.id]
    security_groups = [aws_security_group.prometheus.id]
  }

  service_registries {
    registry_arn = aws_service_discovery_service.prometheus.arn
  }
}

resource "aws_ecs_service" "grafana" {
  name            = "observability-grafana"
  cluster         = aws_ecs_cluster.platform.id
  task_definition = aws_ecs_task_definition.grafana.arn
  desired_count   = var.observability_desired_count
  launch_type     = "FARGATE"

  # Public subnet + public IP - the session's dashboard access path. IPv4 bills only while the
  # task runs; SG restricts to grafana_ingress_cidr; password auth on top (anonymous OFF).
  network_configuration {
    subnets          = [for s in aws_subnet.public : s.id]
    security_groups  = [aws_security_group.grafana.id]
    assign_public_ip = true
  }
}
