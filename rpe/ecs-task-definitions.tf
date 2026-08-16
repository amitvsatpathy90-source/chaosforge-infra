# Same caveats as chaosforge's task-definitions.tf: CPU/memory are reasoned
# starting points anchored to docker-compose.yml's own limits where they
# exist, not measured. RPE has no mTLS (its trust model is OAuth2 +
# SASL_SCRAM Kafka ACLs, ADR-19/ADR-20) — those aren't wired here; that's
# Module 5's job, same boundary as chaosforge's DB passwords.

# Module 7 fix — same IMMUTABLE-repo/:latest contradiction as chaosforge/variables.tf explains.
# CI pushes :<12-char-git-sha> (rpe repo's .github/workflows/ci.yml); required, no default.
variable "image_tag" {
  description = "Image tag for the four app services — the 12-char git SHA pushed by rpe's CI"
  type        = string
}

# Defaults to 3 days (lab, near-$0 — CloudWatch Logs bills per-GB); raise to 90+ for an audited
# environment. A variable rather than a hardcode because raising it is a real per-GB cost increase.
# Kept inline here rather than in a variables.tf, matching this root's existing convention of
# declaring variables next to where they are used.
variable "log_retention_days" {
  description = "CloudWatch Logs retention for the app + data task log groups. Default 3 (lab); 90+ for an audited environment."
  type        = number
  default     = 3
}

locals {
  rpe_log_retention_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "rpe" {
  for_each          = merge(local.rpe_stateful_services, local.rpe_app_services)
  name              = "/rpe/${each.key}"
  retention_in_days = local.rpe_log_retention_days
}

# ── Data-layer task definitions ────────────────────────────────────────

locals {
  rpe_data_containers = {
    postgres = {
      image       = "${aws_ecr_repository.data_mirror["postgres"].repository_url}:16.3"
      cpu         = 256
      memory      = 512
      port        = 5432
      command     = null
      environment = [{ name = "POSTGRES_USER", value = "rpe" }, { name = "POSTGRES_DB", value = "rpe" }]
      secrets     = [{ name = "POSTGRES_PASSWORD", valueFrom = aws_ssm_parameter.postgres_password.arn }]
      healthcheck = ["CMD-SHELL", "pg_isready -U rpe -d rpe"]
      mount_path  = "/var/lib/postgresql/data"
    }
    redis = {
      image       = "${aws_ecr_repository.data_mirror["redis"].repository_url}:7.2.5"
      cpu         = 256
      memory      = 512
      port        = 6379
      command     = ["redis-server", "--appendonly", "yes", "--appendfsync", "everysec", "--maxmemory", "96mb", "--maxmemory-policy", "volatile-lru", "--save", ""]
      environment = []
      secrets     = []
      healthcheck = ["CMD", "redis-cli", "ping"]
      mount_path  = "/data" # AOF persistence — matches local; protects Welford/dedup state across a mid-session task restart
    }
    redpanda = {
      image  = "${aws_ecr_repository.data_mirror["redpanda"].repository_url}:v24.1.11"
      cpu    = 512
      memory = 1024
      port   = 9092
      command = [
        "redpanda", "start", "--kafka-addr", "internal://0.0.0.0:9092,external://0.0.0.0:19092",
        # advertised address MUST be externally reachable — every RPE service resolves redpanda by
        # this Cloud Map name, not by compose's container-DNS "redpanda" or localhost.
        "--advertise-kafka-addr", "internal://redpanda.rpe.internal:9092,external://redpanda.rpe.internal:19092",
        "--pandaproxy-addr", "internal://0.0.0.0:8082,external://0.0.0.0:18082",
        "--advertise-pandaproxy-addr", "internal://redpanda.rpe.internal:8082,external://redpanda.rpe.internal:18082",
        "--schema-registry-addr", "internal://0.0.0.0:8081,external://0.0.0.0:18081",
        "--rpc-addr", "redpanda.rpe.internal:33145",
        "--advertise-rpc-addr", "redpanda.rpe.internal:33145",
        "--smp", "1", "--memory", "400M", "--mode", "dev-container", "--default-log-level=warn",
      ]
      environment = []
      secrets     = []
      # Fixed (arch-audit F-04): the old grep matched the LABEL LINE "Healthy: false" too — false-
      # healthy by construction. chaosforge's redpanda check already used the correct anchored form.
      healthcheck = ["CMD-SHELL", "rpk cluster health | grep -q 'Healthy:.*true'"]
      mount_path  = "/var/lib/redpanda/data"
    }
  }
}

resource "aws_ecs_task_definition" "rpe_data" {
  for_each                 = local.rpe_data_containers
  family                   = "rpe-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = each.value.cpu
  memory                   = each.value.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  volume {
    name = "data"
    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.data[each.key].id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.data[each.key].id
        iam             = "ENABLED"
      }
    }
  }

  container_definitions = jsonencode([{
    name      = each.key
    image     = each.value.image
    essential = true
    command   = each.value.command
    portMappings = [{
      containerPort = each.value.port
      protocol      = "tcp"
    }]
    environment = each.value.environment
    secrets     = each.value.secrets
    mountPoints = [{
      sourceVolume  = "data"
      containerPath = each.value.mount_path
    }]
    healthCheck = {
      command     = each.value.healthcheck
      interval    = 10
      timeout     = 5
      retries     = 5
      startPeriod = 20
    }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.rpe[each.key].name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = each.key
      }
    }
  }])
}

# ── App-service task definitions ───────────────────────────────────────

locals {
  # Every RPE service is an OAuth2 Resource Server on its Actuator surface (ADR-19) — all four need
  # these three. Values point at the shared lab JWKS stub (ADR-0404, foundation/jwks-stub.tf) via
  # secrets.tf; issuer/audience are byte-identical opaque constants, JWKS URI is the one AWS drift
  # point. With the stub up, tokens validate; with it down (or unset), services boot and 401
  # fail-closed — matching RPE's own k8s ConfigMap posture.
  rpe_oauth_secrets = [
    { name = "RPE_OAUTH_ISSUER", valueFrom = aws_ssm_parameter.oauth_issuer.arn },
    { name = "RPE_OAUTH_JWKS_URI", valueFrom = aws_ssm_parameter.oauth_jwks_uri.arn },
    { name = "RPE_OAUTH_AUDIENCE", valueFrom = aws_ssm_parameter.oauth_audience.arn },
  ]

  # DB_USER=rpe + the shared postgres password: COMPOSE PARITY, deliberately (Module 5.5 — see
  # secrets.tf for the full reversal rationale; the per-service roles are a k8s/CNPG-only construct).
  rpe_db_secrets = [
    { name = "DB_PASSWORD", valueFrom = aws_ssm_parameter.postgres_password.arn },
  ]

  rpe_app_services = {
    detection = {
      image  = "${aws_ecr_repository.app["detection"].repository_url}:${var.image_tag}"
      cpu    = 512
      memory = 1024
      port   = 8080
      environment = [
        { name = "KAFKA_BOOTSTRAP_SERVERS", value = "redpanda.rpe.internal:9092" },
        { name = "REDIS_HOST", value = "redis.rpe.internal" },
        { name = "REDIS_PORT", value = "6379" },
        { name = "DB_URL", value = "jdbc:postgresql://postgres.rpe.internal:5432/rpe" },
        { name = "DB_USER", value = "rpe" },
        # F-06 note: RPE already emits structured JSON via each service's logback-spring.xml
        # (LogstashEncoder, active on any non-dev profile) — so LOGGING_STRUCTURED_FORMAT_CONSOLE
        # would be inert here and was removed. chaosforge has no logback override, so it keeps it.
      ]
      secrets = concat(local.rpe_oauth_secrets, local.rpe_db_secrets)
    }
    relay = {
      image  = "${aws_ecr_repository.app["relay"].repository_url}:${var.image_tag}"
      cpu    = 256
      memory = 512
      port   = 8082
      environment = [
        { name = "KAFKA_BOOTSTRAP_SERVERS", value = "redpanda.rpe.internal:9092" },
        { name = "DB_URL", value = "jdbc:postgresql://postgres.rpe.internal:5432/rpe" },
        { name = "DB_USER", value = "rpe" },
      ]
      secrets = concat(local.rpe_oauth_secrets, local.rpe_db_secrets)
    }
    alert = {
      image  = "${aws_ecr_repository.app["alert"].repository_url}:${var.image_tag}"
      cpu    = 256
      memory = 512
      port   = 8083
      environment = [
        { name = "KAFKA_BOOTSTRAP_SERVERS", value = "redpanda.rpe.internal:9092" },
        { name = "DB_URL", value = "jdbc:postgresql://postgres.rpe.internal:5432/rpe" },
        { name = "DB_USER", value = "rpe" },
      ]
      secrets = concat(local.rpe_oauth_secrets, local.rpe_db_secrets)
    }
    triage = {
      image  = "${aws_ecr_repository.app["triage"].repository_url}:${var.image_tag}"
      cpu    = 512
      memory = 1024
      port   = 8081
      environment = [
        { name = "KAFKA_BOOTSTRAP_SERVERS", value = "redpanda.rpe.internal:9092" },
        { name = "REDIS_HOST", value = "redis.rpe.internal" },
        { name = "REDIS_PORT", value = "6379" },
        { name = "DB_URL", value = "jdbc:postgresql://postgres.rpe.internal:5432/rpe" },
        { name = "DB_USER", value = "rpe" },
        { name = "TRIAGE_LLM_MODEL", value = "gpt-4o-mini" },
      ]
      secrets = concat(local.rpe_oauth_secrets, local.rpe_db_secrets, [
        { name = "SPRING_AI_OPENAI_API_KEY", valueFrom = aws_ssm_parameter.openai_api_key.arn },
      ])
    }
  }
}

resource "aws_ecs_task_definition" "rpe_app" {
  for_each                 = local.rpe_app_services
  family                   = "rpe-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = each.value.cpu
  memory                   = each.value.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  # Writable scratch for /tmp under readonlyRootFilesystem=true — see chaosforge/ecs-task-definitions.tf
  # for the full rationale. Fargate ephemeral storage, $0, wiped on task stop.
  volume {
    name = "scratch"
  }

  container_definitions = jsonencode([{
    name = each.key
    # E5 hardening (verified locally against eclipse-temurin:21.0.7_6-jre under `docker run
    # --read-only`): non-root uid + frozen root filesystem. rpe's app tier mounts no EFS, so 1000 is
    # a free choice with nothing to conflict. HOME=/tmp because temurin's default home is unwritable
    # under a read-only root.
    user                   = "1000:1000"
    readonlyRootFilesystem = true
    image                  = each.value.image
    essential              = true
    portMappings = [{
      containerPort = each.value.port
      protocol      = "tcp"
    }]
    environment = concat(each.value.environment, [{ name = "HOME", value = "/tmp" }])
    secrets     = each.value.secrets
    mountPoints = [{ sourceVolume = "scratch", containerPath = "/tmp", readOnly = false }]
    # Container-level health check (arch-audit F-05). Without this ECS treats "task RUNNING" as
    # healthy, so a Spring context still booting (or a live-locked JVM) stays registered in Cloud
    # Map / passes ECS's own health gate the whole time. /actuator/health/readiness is permitAll
    # (ManagementSecurityConfig.java:61, ADR-19) — the one path that doesn't need a JWT the probe
    # can't carry. curl exists on eclipse-temurin's Ubuntu base (verified against the pinned tag).
    healthCheck = {
      command     = ["CMD-SHELL", "curl -sf http://127.0.0.1:${each.value.port}/actuator/health/readiness || exit 1"]
      interval    = 15
      timeout     = 5
      retries     = 3
      startPeriod = 90
    }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.rpe[each.key].name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = each.key
      }
    }
  }])
}
