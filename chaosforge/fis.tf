# FIS experiment templates for chaosforge (Module 8), same shape as rpe/fis.tf. Cloud counterparts
# of local IT tests; enables C31 game day.

locals {
  chaosforge_fis_experiments = {
    kill-execution-mid-run = {
      group       = "service:chaosforge-execution-service"
      description = "chaosforge: kill the Execution Service mid-scenario. Claims under test: C16 (IncompleteRunSweeper marks the orphaned IN_PROGRESS run INCOMPLETE); redelivery on restart is absorbed by fencing + inbox dedup + step-level Idempotency-Key (no double fault injection — the ADR-0523/0528 machinery under a real crash, not a mock)."
    }
    kill-postgres-mid-run = {
      group       = "service:chaosforge-postgres"
      description = "chaosforge: kill Postgres mid-scenario. Claims under test: C19 (in-executor deadline + DB socketTimeout/statement_timeout bound the stall — run finalizes rather than hangs); CP outbox rows born PENDING before the kill survive and publish after recovery (crash-recovery-without-duplicates, ADR-0506). Local counterpart: ExecutorControlsUnderFaultIT's paused/stopped-PG cases."
    }
  }
}

# Abort path — see rpe/fis.tf. Steady-state subject is the Control Plane; if it thrashes or
# stops reporting, the experiment escaped its blast radius and must halt.
# Gate alaram to avoid orphan alarma when enable_fis = false
resource "aws_cloudwatch_metric_alarm" "fis_steady_state" {
  count               = var.enable_fis ? 1 : 0
  alarm_name          = "chaosforge-fis-steady-state-breach"
  alarm_description   = "Halts any running FIS experiment: chaosforge-control-plane is thrashing, or has stopped reporting entirely."
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
    ServiceName = aws_ecs_service.control_plane.name
  }
}

resource "aws_fis_experiment_template" "chaosforge" {
  for_each    = var.enable_fis ? local.chaosforge_fis_experiments : {}
  description = each.value.description
  role_arn    = data.terraform_remote_state.foundation.outputs.fis_role_arn

  stop_condition {
    source = "aws:cloudwatch:alarm"
    value  = aws_cloudwatch_metric_alarm.fis_steady_state[0].arn
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

  tags = { Name = "chaosforge-${each.key}" }
}

output "fis_experiment_template_ids" {
  description = "Start with: aws fis start-experiment --experiment-template-id <id>"
  value       = { for k, v in aws_fis_experiment_template.chaosforge : k => v.id }
}
