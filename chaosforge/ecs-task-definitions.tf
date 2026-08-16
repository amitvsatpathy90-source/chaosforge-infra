# CPU/memory are reasoned starting points, not measured — no CloudWatch data yet to size against.
# `mtls` profile active on gateway/CP/exec; passwords come from Module 5's secrets block, not here.

locals {
  chaosforge_log_retention_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "chaosforge" {
  for_each          = merge(local.chaosforge_stateful_services, local.chaosforge_app_services)
  name              = "/chaosforge/${each.key}"
  retention_in_days = local.chaosforge_log_retention_days
}

# ── Data-layer task definitions ────────────────────────────────────────

locals {
  chaosforge_data_containers = {
    postgres = {
      # Derived image bakes init-databases.sql (else CP/Exec crashloop, no bind-mount on Fargate).
      # Single-host Fargate memory limit boundary.
      image       = "${aws_ecr_repository.data_mirror["postgres"].repository_url}:16.4-alpine-cf1"
      cpu         = 256
      memory      = 512
      port        = 5432
      command     = null
      environment = [{ name = "POSTGRES_USER", value = "chaosforge" }, { name = "POSTGRES_DB", value = "chaosforge" }]
      # Without this the postgres image refuses to start at all (it requires POSTGRES_PASSWORD or
      # POSTGRES_HOST_AUTH_METHOD=trust) — same parameter CP/Exec read as DB_PASSWORD, same login.
      secrets     = [{ name = "POSTGRES_PASSWORD", valueFrom = aws_ssm_parameter.db_password.arn }]
      healthcheck = ["CMD-SHELL", "pg_isready -U chaosforge -d chaosforge"]
      mount_path  = "/var/lib/postgresql/data"
    }
    redis = {
      image       = "${aws_ecr_repository.data_mirror["redis"].repository_url}:7.4-alpine"
      cpu         = 256
      memory      = 512
      port        = 6379
      command     = ["redis-server", "--maxmemory", "96mb", "--maxmemory-policy", "allkeys-lru", "--save", ""]
      environment = []
      secrets     = []
      healthcheck = ["CMD", "redis-cli", "ping"]
      # No volume: `--save ""` and no `--appendonly` means nothing is ever written to /data. This is
      # the L2 cache (ADR-0504) — losing it on a task restart is the documented design, not a gap.
      # See data-layer.tf. (rpe's Redis is AOF-backed and DOES mount a volume.)
      mount_path = null
    }
    redpanda = {
      image  = "${aws_ecr_repository.data_mirror["redpanda"].repository_url}:v24.2.7"
      cpu    = 512
      memory = 1024
      port   = 9092
      command = [
        "redpanda", "start", "--smp=1", "--memory=512M", "--reserve-memory=0M", "--overprovisioned",
        "--node-id=0", "--check=false", "--kafka-addr=PLAINTEXT://0.0.0.0:9092",
        # advertised address MUST be externally reachable, unlike compose's `localhost` — every
        # other task resolves redpanda by this Cloud Map name, not by container-internal loopback.
        "--advertise-kafka-addr=PLAINTEXT://redpanda.chaosforge.internal:9092",
      ]
      environment = []
      secrets     = []
      healthcheck = ["CMD-SHELL", "rpk cluster health -X brokers=localhost:9092 | grep -q 'Healthy:.*true'"]
      mount_path  = "/var/lib/redpanda/data"
    }
  }
}

resource "aws_ecs_task_definition" "chaosforge_data" {
  for_each                 = local.chaosforge_data_containers
  family                   = "chaosforge-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = each.value.cpu
  memory                   = each.value.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  dynamic "volume" {
    for_each = each.value.mount_path == null ? [] : [1]
    content {
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
    mountPoints = each.value.mount_path == null ? [] : [{
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
        "awslogs-group"         = aws_cloudwatch_log_group.chaosforge[each.key].name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = each.key
      }
    }
  }])
}

# ── App-service task definitions ───────────────────────────────────────

locals {
  # Shared across gateway/CP/exec — verified all three read the same MTLS_KEYSTORE_PASSWORD /
  # MTLS_TRUSTSTORE_PASSWORD variable names (application-mtls.yml, all three services).
  # JWK_SET_URI: also all three JWT-touching services (gateway validates, CP re-verifies). Points
  # at the shared lab IdP stub (foundation/jwks-stub.tf); each decoder selects the chaosforge-lab-1
  # key by kid. Read at BOOT, not first request — see secrets.tf.
  chaosforge_mtls_secrets = [
    { name = "MTLS_KEYSTORE_PASSWORD", valueFrom = aws_ssm_parameter.mtls_keystore_password.arn },
    { name = "MTLS_TRUSTSTORE_PASSWORD", valueFrom = aws_ssm_parameter.mtls_truststore_password.arn },
    { name = "JWK_SET_URI", valueFrom = aws_ssm_parameter.jwk_set_uri.arn },
  ]

  # CP and Exec only — verified both read DB_USERNAME/DB_PASSWORD (control-plane and
  # execution-service application.yml). Edge Gateway has no database. Two flat SSM parameters —
  # the `:json-key::` extraction syntax was Secrets-Manager-only (Module 5.5).
  chaosforge_db_secrets = [
    { name = "DB_USERNAME", valueFrom = aws_ssm_parameter.db_username.arn },
    { name = "DB_PASSWORD", valueFrom = aws_ssm_parameter.db_password.arn },
  ]

  chaosforge_app_services = {
    edge-gateway = {
      image  = "${aws_ecr_repository.app["edge-gateway"].repository_url}:${var.image_tag}"
      cpu    = 512
      memory = 1024
      port   = 8080
      environment = [
        { name = "SPRING_PROFILES_ACTIVE", value = "mtls" },
        { name = "CONTROL_PLANE_URL", value = "https://control-plane.chaosforge.internal:8081" },
        { name = "MTLS_KEYSTORE", value = "file:/mnt/mtls/edge-gateway-keystore.p12" },
        { name = "MTLS_TRUSTSTORE", value = "file:/mnt/mtls/truststore.p12" },
        # Spring Boot 4.1's native structured logging (arch-audit F-06) — single-line JSON events,
        # no extra dependency. Turns MDC keys (trace_id) into first-class Logs Insights fields and
        # stops multi-line stack traces from shredding into one CloudWatch event per frame.
        { name = "LOGGING_STRUCTURED_FORMAT_CONSOLE", value = "ecs" },
        # Boot's graceful-shutdown default (30s) == this task's ECS stopTimeout default (30s) —
        # zero margin for SIGKILL to land mid-drain. RPE runs 20s < its stopTimeout (ADR-22);
        # matched here without touching application.yml (local-parity invariant).
        { name = "SPRING_LIFECYCLE_TIMEOUTPERSHUTDOWNPHASE", value = "20s" },
      ]
      secrets          = local.chaosforge_mtls_secrets
      needs_mtls_mount = true
    }
    control-plane = {
      image  = "${aws_ecr_repository.app["control-plane"].repository_url}:${var.image_tag}"
      cpu    = 1024
      memory = 2048
      port   = 8081
      environment = [
        { name = "SPRING_PROFILES_ACTIVE", value = "mtls" },
        { name = "CP_DB_URL", value = "jdbc:postgresql://postgres.chaosforge.internal:5432/chaosforge_cp" },
        { name = "REDIS_HOST", value = "redis.chaosforge.internal" },
        { name = "REDIS_PORT", value = "6379" },
        # CP's application.yml hardcodes spring.kafka.bootstrap-servers with no ${VAR:default}
        # placeholder (unlike every sibling property in the same file) — verified, not assumed.
        # SPRING_KAFKA_BOOTSTRAP_SERVERS still overrides it: Spring Boot's environment
        # property source outranks application.yml regardless of whether the YAML used a
        # placeholder. Flagged for a follow-up fix in chaosforge for consistency with its
        # siblings, not blocking here.
        { name = "SPRING_KAFKA_BOOTSTRAP_SERVERS", value = "redpanda.chaosforge.internal:9092" },
        { name = "MTLS_KEYSTORE", value = "file:/mnt/mtls/control-plane-keystore.p12" },
        { name = "MTLS_TRUSTSTORE", value = "file:/mnt/mtls/truststore.p12" },
        { name = "LOGGING_STRUCTURED_FORMAT_CONSOLE", value = "ecs" }, # arch-audit F-06
        # Boot's graceful-shutdown default (30s) == this task's ECS stopTimeout default (30s) —
        # zero margin for SIGKILL to land mid-drain. RPE runs 20s < its stopTimeout (ADR-22);
        # matched here without touching application.yml (local-parity invariant).
        { name = "SPRING_LIFECYCLE_TIMEOUTPERSHUTDOWNPHASE", value = "20s" },
      ]
      secrets          = concat(local.chaosforge_mtls_secrets, local.chaosforge_db_secrets)
      needs_mtls_mount = true
    }
    execution-service = {
      image  = "${aws_ecr_repository.app["execution-service"].repository_url}:${var.image_tag}"
      cpu    = 1024
      memory = 2048
      port   = 8082
      environment = [
        { name = "SPRING_PROFILES_ACTIVE", value = "mtls" },
        { name = "EXEC_DB_URL", value = "jdbc:postgresql://postgres.chaosforge.internal:5432/chaosforge_exec" },
        { name = "KAFKA_BOOTSTRAP", value = "redpanda.chaosforge.internal:9092" },
        { name = "CONTROL_PLANE_URL", value = "https://control-plane.chaosforge.internal:8081" },
        { name = "MTLS_KEYSTORE", value = "file:/mnt/mtls/execution-service-keystore.p12" },
        { name = "MTLS_TRUSTSTORE", value = "file:/mnt/mtls/truststore.p12" },
        # Deployment-wide override; RPE's readiness path differs from the "/health" default. Local
        # Dev mode default configuration.
        { name = "CHAOSFORGE_STEADYSTATE_HEALTHPATH", value = "/actuator/health/readiness" },
        # Blast-radius ceiling for the fault injector — non-empty allowlist is the sole ceiling
        # and overrides the private-network block. Enforces network isolation security invariants.
        { name = "TARGET_ALLOWED_HOSTS", value = "detection.rpe.internal" },
        { name = "TARGET_BLOCK_PRIVATE", value = "true" },
        { name = "LOGGING_STRUCTURED_FORMAT_CONSOLE", value = "ecs" }, # arch-audit F-06
        # Boot's graceful-shutdown default (30s) == this task's ECS stopTimeout default (30s) —
        # zero margin for SIGKILL to land mid-drain. RPE runs 20s < its stopTimeout (ADR-22);
        # matched here without touching application.yml (local-parity invariant).
        { name = "SPRING_LIFECYCLE_TIMEOUTPERSHUTDOWNPHASE", value = "20s" },
      ]
      secrets          = concat(local.chaosforge_mtls_secrets, local.chaosforge_db_secrets)
      needs_mtls_mount = true
    }
  }
}

resource "aws_ecs_task_definition" "chaosforge_app" {
  for_each                 = local.chaosforge_app_services
  family                   = "chaosforge-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = each.value.cpu
  memory                   = each.value.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  dynamic "volume" {
    for_each = each.value.needs_mtls_mount ? [1] : []
    content {
      name = "mtls"
      efs_volume_configuration {
        file_system_id     = aws_efs_file_system.mtls_material.id
        transit_encryption = "ENABLED"
        authorization_config {
          access_point_id = aws_efs_access_point.mtls_material.id
          iam             = "ENABLED"
        }
      }
    }
  }

  # Writable scratch for /tmp, required because readonlyRootFilesystem=true (below) freezes the rest
  # of the container's filesystem. A bare volume{} with no efs_volume_configuration is Fargate
  # ephemeral storage (the task's built-in 20 GB) — $0, wiped on task stop. Fargate does not support
  # linuxParameters.tmpfs, so this scratch-volume mount is the supported writable-/tmp mechanism.
  volume {
    name = "scratch"
  }

  container_definitions = jsonencode([{
    name = each.key
    # E5 hardening (verified locally against eclipse-temurin:21.0.7_6-jre under `docker run
    # --read-only`): run as a non-root uid and freeze the root filesystem. 1000 is not arbitrary —
    # the mTLS EFS access point roots its files at owner_uid 1000 (mtls.tf), so the app tier already
    # had to be uid 1000 to read its certs. HOME=/tmp is added below because temurin's default
    # HOME=/home/ubuntu is unwritable under a read-only root, and some libraries write to $HOME.
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
    mountPoints = concat(
      [{ sourceVolume = "scratch", containerPath = "/tmp", readOnly = false }],
      each.value.needs_mtls_mount ? [{
        sourceVolume  = "mtls"
        containerPath = "/mnt/mtls"
        readOnly      = true
      }] : []
    )
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.chaosforge[each.key].name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = each.key
      }
    }
  }])
}
