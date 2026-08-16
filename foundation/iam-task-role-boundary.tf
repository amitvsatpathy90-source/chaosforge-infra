# Permissions boundary for every ECS/FIS/Lambda role this repo creates (R2 fix).
# Prevents a CreateRole -> PutRolePolicy(*:*) -> PassRole -> RunTask privilege-escalation chain:
# IAM evaluates identity-policy INTERSECT boundary, so even Action:*/Resource:* is capped here.
# Allow-list is the union of what every bounded role actually uses today — widen deliberately, not by default.
data "aws_iam_policy_document" "task_role_boundary" {
  statement {
    sid    = "AllowedServiceActions"
    effect = "Allow"
    actions = [
      # AmazonECSTaskExecutionRolePolicy, verbatim (chaosforge/rpe/observability execution roles)
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      # budget-teardown Lambda's own log group (cost-guardrail.tf)
      "logs:CreateLogGroup",
      # execution roles' SSM-backed `secrets` resolution (chaosforge/rpe/observability secrets.tf)
      "ssm:GetParameters",
      # task roles' EFS data-directory + mTLS-material mounts (chaosforge/rpe/observability)
      "elasticfilesystem:ClientMount",
      "elasticfilesystem:ClientWrite",
      # platform-fis: stop-task experiments + its stop-condition alarm evaluation (foundation/fis.tf)
      "ecs:ListTasks",
      "ecs:DescribeTasks",
      "ecs:StopTask",
      "cloudwatch:DescribeAlarms",
      # platform-budget-teardown: scale every service to 0 on a budget breach (cost-guardrail.tf)
      "ecs:ListServices",
      "ecs:UpdateService",
    ]
    resources = ["*"] # a boundary caps the CEILING; each role's own policy (resource-scoped where AWS allows it) determines the actual grant
  }

  # Explicit, redundant by design: the allow-list above already omits iam:*/sts:AssumeRole*, so
  # these would be implicit-denied regardless of the statement above. Stated anyway so the security
  # intent — nothing this boundary bounds can ever touch IAM or assume another role — is readable
  # directly in the policy, not just inferable from an absence.
  statement {
    sid    = "ExplicitNoEscalation"
    effect = "Deny"
    actions = [
      "iam:*",
      "sts:AssumeRole",
      "sts:AssumeRoleWithWebIdentity",
      "sts:AssumeRoleWithSAML",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "task_role_boundary" {
  name        = "chaosforge-platform-task-role-boundary"
  description = "Permissions boundary attached to every ECS/FIS/Lambda role this repo's Terraform creates (R2 fix). See header comment — counterpart to PassEcsRolesOnly in iam-deploy-policy.tf."
  policy      = data.aws_iam_policy_document.task_role_boundary.json
}
