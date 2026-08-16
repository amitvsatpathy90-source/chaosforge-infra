# Standard ECS split: execution role (agent — pull image, logs, secrets) vs task role (app —
# near-empty, no service calls AWS APIs directly). One shared pair for all services.

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
  name                 = "chaosforge-app-execution"
  assume_role_policy   = data.aws_iam_policy_document.ecs_tasks_assume.json
  permissions_boundary = local.task_role_permissions_boundary_arn # R2 fix — see foundation/iam-task-role-boundary.tf
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "execution_secrets" {
  # SSM parameters, not Secrets Manager (Module 5.5 — see secrets.tf header). ECS resolves
  # SSM-backed `secrets` entries via ssm:GetParameters; decryption of SecureString values under
  # the AWS-managed aws/ssm key needs no separate kms:Decrypt grant (customer-managed keys would).
  statement {
    effect  = "Allow"
    actions = ["ssm:GetParameters"]
    resources = [
      aws_ssm_parameter.db_username.arn,
      aws_ssm_parameter.db_password.arn,
      aws_ssm_parameter.mtls_keystore_password.arn,
      aws_ssm_parameter.mtls_truststore_password.arn,
      aws_ssm_parameter.jwk_set_uri.arn,
    ]
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  name   = "chaosforge-app-execution-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets.json
}

# Module 5.5 audit fix: every EFS volume in the task definitions sets authorization_config
# iam = "ENABLED", which makes EFS evaluate the mount against the TASK role's IAM identity — and
# no EFS permissions had ever been granted to it. Depending on the filesystem's (absent) resource
# policy this is a denied or anonymous mount; either way the intent was an IAM-authorized mount,
# so grant it explicitly. ClientRootAccess is deliberately omitted — the access points already own
# their root directories, nothing needs root on the filesystem.
data "aws_iam_policy_document" "task_efs" {
  statement {
    effect = "Allow"
    actions = [
      "elasticfilesystem:ClientMount",
      "elasticfilesystem:ClientWrite",
    ]
    resources = concat(
      [for fs in aws_efs_file_system.data : fs.arn],
      [aws_efs_file_system.mtls_material.arn],
    )
  }
}

resource "aws_iam_role_policy" "task_efs" {
  name   = "chaosforge-app-task-efs"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_efs.json
}

resource "aws_iam_role" "task" {
  name                 = "chaosforge-app-task"
  assume_role_policy   = data.aws_iam_policy_document.ecs_tasks_assume.json
  permissions_boundary = local.task_role_permissions_boundary_arn # R2 fix — see foundation/iam-task-role-boundary.tf
}
