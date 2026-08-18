# Shared lab JWKS stub for both systems (ADR-0404).
# desired_count=0 still BOOTS and 401s (fail-closed) - the old crashloop was the " " value failing Assert.hasText, not this.
# Idle $0; session ~$0.02/hr (256/512 Fargate floor) + shared ECR line.

variable "jwks_stub_desired_count" {
  description = "0 = provisioned, not running (default). Set to 1 so tokens validate (live sessions, scrapes)."
  type        = number
  default     = 0
}

# ── Image ─────────────────────────────────────────────────────────────────

resource "aws_ecr_repository" "jwks_stub" {
  name                 = "platform/jwks-stub"
  image_tag_mutability = "MUTABLE" # derived-from-upstream tag, same convention as observability/ and the data mirrors

  image_scanning_configuration {
    scan_on_push = true
  }
}

# ── Service discovery ─────────────────────────────────────────────────────

# Resolves VPC-wide as jwks-stub.observability.internal; both systems' subnets reach it.
resource "aws_service_discovery_service" "jwks_stub" {
  name = "jwks-stub"

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

# ── Security group ────────────────────────────────────────────────────────

resource "aws_security_group" "jwks_stub" {
  name_prefix = "platform-jwks-stub-"
  vpc_id      = aws_vpc.platform.id
  description = "Lab IdP stub. Ingress :80 CIDR-scoped to the VPC - this state cannot reference the six consumer SGs without a circular read (same constraint aws_security_group.prometheus documents), and a JWK Set is public key material by definition."
}

# CIDR-scoped: public key material only, no private key in image.
resource "aws_vpc_security_group_ingress_rule" "jwks_stub_from_vpc" {
  security_group_id = aws_security_group.jwks_stub.id
  cidr_ipv4         = var.vpc_cidr
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  description       = "JWKS fetch from both systems app tiers (rpe x4, chaosforge gateway + control-plane)"
}

resource "aws_vpc_security_group_egress_rule" "jwks_stub_https_endpoints" {
  security_group_id            = aws_security_group.jwks_stub.id
  referenced_security_group_id = aws_security_group.vpc_endpoints.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  description                  = "ECR manifest/auth via the interface endpoints (image layers ride the S3 rule in observability.tf)"
}

resource "aws_vpc_security_group_egress_rule" "jwks_stub_dns" {
  security_group_id = aws_security_group.jwks_stub.id
  cidr_ipv4         = var.vpc_cidr
  from_port         = 53
  to_port           = 53
  ip_protocol       = "udp"
}

# S3-prefix-list egress (R1) lives in local.foundation_task_security_groups (observability.tf).
# Add new foundation tasks to that map, not a private copy of the rule.

# ── IAM ───────────────────────────────────────────────────────────────────

# Execution role only - no task role; container makes no AWS API calls.
resource "aws_iam_role" "jwks_stub_execution" {
  name                 = "platform-jwks-stub"
  assume_role_policy   = data.aws_iam_policy_document.obs_tasks_assume.json
  permissions_boundary = aws_iam_policy.task_role_boundary.arn # R2 fix - see iam-task-role-boundary.tf
}

# Boundary already covers these actions (ecr pull + logs) - see iam-task-role-boundary.tf.
resource "aws_iam_role_policy_attachment" "jwks_stub_execution_managed" {
  role       = aws_iam_role.jwks_stub_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ── Logs / task / service ─────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "jwks_stub" {
  name              = "/platform/jwks-stub"
  retention_in_days = 3 # lab default, same as /observability/*
}

resource "aws_ecs_task_definition" "jwks_stub" {
  family                   = "platform-jwks-stub"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256 # Fargate's floor; nginx serving one ~800-byte file needs nothing more
  memory                   = 512
  execution_role_arn       = aws_iam_role.jwks_stub_execution.arn
  # No task_role_arn on purpose - see the IAM note above.

  container_definitions = jsonencode([{
    name         = "jwks-stub"
    image        = "${aws_ecr_repository.jwks_stub.repository_url}:1.27-alpine-idp1"
    essential    = true
    portMappings = [{ containerPort = 80, protocol = "tcp" }]

    # No E5 hardening (root user, writable FS): stock nginx needs it, container holds no secrets.

    # Healthcheck fetches the JWK Set itself - catches "up but serving 404".
    healthCheck = {
      command     = ["CMD-SHELL", "wget -q -O- http://localhost/.well-known/jwks.json >/dev/null 2>&1 || exit 1"]
      interval    = 15
      timeout     = 3
      retries     = 5
      startPeriod = 5
    }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.jwks_stub.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "jwks-stub"
      }
    }
  }])
}

resource "aws_ecs_service" "jwks_stub" {
  name            = "platform-jwks-stub"
  cluster         = aws_ecs_cluster.platform.id
  task_definition = aws_ecs_task_definition.jwks_stub.arn
  desired_count   = var.jwks_stub_desired_count
  launch_type     = "FARGATE"

  # Private subnets, no public IP: a JWK Set is public data, but there is no reason for it to
  # leave the VPC. Placed in the chaosforge subnet set (as prometheus is) purely because it has
  # to sit somewhere - private DNS resolves VPC-wide, so rpe's tasks reach it identically.
  network_configuration {
    subnets         = [for s in aws_subnet.private_chaosforge : s.id]
    security_groups = [aws_security_group.jwks_stub.id]
  }

  service_registries {
    registry_arn = aws_service_discovery_service.jwks_stub.arn
  }
}
