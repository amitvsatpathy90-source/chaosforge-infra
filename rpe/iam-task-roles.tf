# Same split and same reasoning as chaosforge/iam-task-roles.tf: execution
# role for the ECS agent (pull/log/secrets), task role for the app itself
# (near-empty today — RPE's services talk to Postgres/Kafka/Redis and
# OpenAI's API over plain network protocols, not AWS SDK calls).

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name                 = "rpe-app-execution"
  assume_role_policy   = data.aws_iam_policy_document.ecs_tasks_assume.json
  permissions_boundary = local.task_role_permissions_boundary_arn # R2 fix — see foundation/iam-task-role-boundary.tf
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "task" {
  name                 = "rpe-app-task"
  assume_role_policy   = data.aws_iam_policy_document.ecs_tasks_assume.json
  permissions_boundary = local.task_role_permissions_boundary_arn # R2 fix — see foundation/iam-task-role-boundary.tf
}

data "aws_iam_policy_document" "execution_secrets" {
  # All SSM now (Module 5.5 — see secrets.tf). ECS resolves SSM-backed `secrets` entries via
  # ssm:GetParameters; the AWS-managed aws/ssm key needs no separate kms:Decrypt grant.
  statement {
    effect  = "Allow"
    actions = ["ssm:GetParameters"]
    resources = [
      aws_ssm_parameter.postgres_password.arn,
      aws_ssm_parameter.openai_api_key.arn,
      aws_ssm_parameter.oauth_issuer.arn,
      aws_ssm_parameter.oauth_jwks_uri.arn,
      aws_ssm_parameter.oauth_audience.arn,
    ]
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  name   = "rpe-app-execution-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets.json
}

# Same Module 5.5 audit fix as chaosforge's: EFS volumes mount with iam = "ENABLED" but the task
# role had no EFS permissions — grant ClientMount/ClientWrite on exactly these filesystems.
data "aws_iam_policy_document" "task_efs" {
  statement {
    effect = "Allow"
    actions = [
      "elasticfilesystem:ClientMount",
      "elasticfilesystem:ClientWrite",
    ]
    resources = [for fs in aws_efs_file_system.data : fs.arn]
  }
}

resource "aws_iam_role_policy" "task_efs" {
  name   = "rpe-app-task-efs"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_efs.json
}
