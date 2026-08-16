# FIS experiment templates for RPE (Module 8) — each maps to a documented resilience claim in
# RPE's ADRs, observed via the self-hosted Prometheus. All use aws:ecs:stop-task, selection ALL.
# Start with: aws fis start-experiment --experiment-template-id <id>.

locals {
  # experiment key -> { service group to kill, the claim under test }
  rpe_fis_experiments = {
    kill-redis = {
      group       = "service:rpe-redis"
      description = "RPE: kill Redis. Claims under test: ADR-02 C+D hybrid CB fallback buffers events (no DLT for transients); ADR-26 automaticTransitionFromOpenToHalfOpen unwedges the redis CB on recovery; ADR-24 rate limiter degrades to per-instance Guava (rpe.ratelimit.degraded=1), never fails closed. Watch: detection stays Running, CB state metric OPEN->HALF_OPEN->CLOSED after ECS restarts the task."
    }
    kill-postgres = {
      group       = "service:rpe-postgres"
      description = "RPE: kill Postgres. Claims under test: hot path is Redis-only (~99% of events never touch PG — detection keeps consuming); outbox writer absorbs the outage up to the in-memory queue bound, then rpe.outbox.dropped counts (ADR-12's documented loss accounting, not silent loss). Watch: consumer lag stays flat while alert-intent buffering degrades."
    }
    kill-relay = {
      group       = "service:rpe-relay"
      description = "RPE: kill the relay. Claim under test: ADR-17 'a peer down => backlog, never an error upstream' — PENDING outbox rows accrue (rpe.outbox.pending.age_seconds climbs), detection is entirely unaffected, and the backlog drains exactly once on recovery (Kafka-transactional relay + consumer dedup)."
    }
    kill-redpanda = {
      group       = "service:rpe-redpanda"
      description = "RPE: kill Redpanda. Claims under test: ADR-26 asyncAcks holds the committed watermark at the un-acked gap, so every in-flight event at kill time is REDELIVERED on recovery (dedup + deterministic UUIDv5 alert_id absorb the replay — no duplicate alert actions in processed_alerts); relay's send backs off, rows stay PENDING."
    }
  }
}

# Abort path: halts a running experiment when the stop-condition alarm fires. Coarse blast-radius
# guard (AWS/ECS MemoryUtilization on rpe-detection), not a real SLO guard — CloudWatch can't see
# Prometheus SLIs. treat_missing_data="breaching" means the alarm is in ALARM at desired_count=0 —
# bring the stack up before starting an experiment (Target system must be UP). ~$0.10/mo.
resource "aws_cloudwatch_metric_alarm" "fis_steady_state" {
  alarm_name          = "rpe-fis-steady-state-breach"
  alarm_description   = "Halts any running FIS experiment: rpe-detection is thrashing, or has stopped reporting entirely."
  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 95
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "breaching"

  dimensions = {
    ClusterName = data.terraform_remote_state.foundation.outputs.ecs_cluster_name
    ServiceName = aws_ecs_service.rpe_app["detection"].name
  }
}

resource "aws_fis_experiment_template" "rpe" {
  for_each    = local.rpe_fis_experiments
  description = each.value.description
  role_arn    = data.terraform_remote_state.foundation.outputs.fis_role_arn

  stop_condition {
    source = "aws:cloudwatch:alarm"
    value  = aws_cloudwatch_metric_alarm.fis_steady_state.arn
  }

  action {
    name      = each.key
    action_id = "aws:ecs:stop-task"
    target {
      key   = "Tasks"
      value = "target-tasks"
    }
  }

  target {
    name           = "target-tasks"
    resource_type  = "aws:ecs:task"
    selection_mode = "ALL"

    filter {
      path   = "clusterArn"
      values = [data.terraform_remote_state.foundation.outputs.ecs_cluster_id]
    }
    # ECS sets a task's `group` to "service:<service-name>" — filtering on it selects the target
    # service's tasks without needing tag propagation onto tasks.
    filter {
      path   = "group"
      values = [each.value.group]
    }
  }

  log_configuration {
    log_schema_version = 2
    cloudwatch_logs_configuration {
      log_group_arn = "${data.terraform_remote_state.foundation.outputs.fis_log_group_arn}:*"
    }
  }

  tags = { Name = "rpe-${each.key}" }
}

output "fis_experiment_template_ids" {
  description = "Start with: aws fis start-experiment --experiment-template-id <id>"
  value       = { for k, v in aws_fis_experiment_template.rpe : k => v.id }
}
