# AWS FIS shared plumbing (Module 8): experiment role + evidence log group. Templates live in
# each system's own root (rpe/fis.tf, chaosforge/fis.tf). Idle cost: log group only (pennies);
# experiments bill $0.10/action-minute while running.

resource "aws_cloudwatch_log_group" "fis" {
  name              = "/fis/experiments"
  retention_in_days = 30 # longer than app logs on purpose — game-day evidence (C31's "no manual data repair" attestation needs a trail that outlives the session)
}

data "aws_iam_policy_document" "fis_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["fis.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "fis" {
  name                 = "platform-fis"
  assume_role_policy   = data.aws_iam_policy_document.fis_assume.json
  permissions_boundary = aws_iam_policy.task_role_boundary.arn # R2 fix — see iam-task-role-boundary.tf
}

data "aws_iam_policy_document" "fis_permissions" {
  # Only what aws:ecs:stop-task needs, scoped to this cluster's tasks. No EC2/network/SSM actions —
  # the agent-based FIS actions (task-network-latency etc.) need an SSM sidecar per task, which is
  # real per-task overhead; stop-task covers every documented resilience claim we test (see the
  # template files). Widen deliberately if an experiment ever needs more, not preemptively.
  statement {
    effect    = "Allow"
    actions   = ["ecs:ListTasks", "ecs:DescribeTasks"]
    resources = ["*"] # List/Describe don't support useful resource scoping
  }
  statement {
    effect    = "Allow"
    actions   = ["ecs:StopTask"]
    resources = ["arn:aws:ecs:${var.aws_region}:*:task/${aws_ecs_cluster.platform.name}/*"]
  }

  # Required by the CloudWatch-alarm stop conditions on every experiment template
  # (rpe/fis.tf, chaosforge/fis.tf). FIS polls the alarm through THIS role; without
  # DescribeAlarms it cannot evaluate the stop condition, and the experiment errors on start.
  # DescribeAlarms does not support resource-level scoping.
  statement {
    effect    = "Allow"
    actions   = ["cloudwatch:DescribeAlarms"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "fis_permissions" {
  name   = "platform-fis-permissions"
  role   = aws_iam_role.fis.id
  policy = data.aws_iam_policy_document.fis_permissions.json
}
