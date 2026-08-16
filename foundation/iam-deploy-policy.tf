# Deliberately narrow. This grows incrementally as each later module lands
# (Module 2 adds ec2/vpc:*, Module 4 adds ecs:*/elasticloadbalancing:*, etc.)
# — never a blanket AdministratorAccess grant on a role a public CI system
# can assume. See README.md#iam-growth for the running list of what each
# module is expected to add here.
locals {
  # The exact set of role names this repo's Terraform ever creates — chaosforge/iam-task-roles.tf,
  # rpe/iam-task-roles.tf, foundation/fis.tf, foundation/cost-guardrail.tf,
  # foundation/observability.tf. Shared by PassEcsRolesOnly and ManageOwnedRoles/
  # CreateOwnedRolesWithBoundary below (R2 fix) — a role this CI principal can create or modify must
  # be drawn from the same set it may ever pass to a service; scoping one without the other leaves
  # the escalation open (see iam-task-role-boundary.tf's header for the full chain).
  managed_role_arns = [
    "arn:aws:iam::*:role/chaosforge-*-execution",
    "arn:aws:iam::*:role/chaosforge-*-task",
    "arn:aws:iam::*:role/rpe-*-execution",
    "arn:aws:iam::*:role/rpe-*-task",
    # Module 6 — caught during observability build: the new roles matched neither pattern, so
    # the ECS services referencing them would have failed iam:PassRole at apply time.
    "arn:aws:iam::*:role/observability-execution",
    "arn:aws:iam::*:role/observability-task",
    # Module 8 — FIS experiment templates reference this via role_arn (PassRole at create).
    "arn:aws:iam::*:role/platform-fis",
    # Module 9 — the budget-teardown Lambda's role (PassRole at function create).
    "arn:aws:iam::*:role/platform-budget-teardown",
    # Lab IdP stub — its ECS task's execution role (PassRole at service create). Same omission
    # class as the Module 6 note above: a role that matches no pattern here fails iam:PassRole at
    # apply, not at review.
    "arn:aws:iam::*:role/platform-jwks-stub",
  ]
}

data "aws_iam_policy_document" "deploy_permissions" {
  # Corrected from the original Module 1 pass: without this, `terraform
  # init`/`plan`/`apply` against the S3 backend fails AccessDenied before
  # touching a single AWS resource — every other module depends on it.
  statement {
    sid    = "TerraformStateAccess"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject", # S3 native locking (use_lockfile) writes/removes a .tflock object
      "s3:ListBucket",
    ]
    resources = [
      "arn:aws:s3:::chaosforge-tfstate-*",
      "arn:aws:s3:::chaosforge-tfstate-*/*",
    ]
  }

  statement {
    sid       = "BudgetsAndCostVisibility"
    effect    = "Allow"
    actions   = ["budgets:ViewBudget", "budgets:ModifyBudget", "ce:Get*"]
    resources = ["*"] # Budgets/Cost Explorer are account-scoped APIs — no ARN to narrow to
  }

  # Module 2 — networking. EC2 network object APIs have no useful
  # resource-level ARN scoping for create calls (AWS-wide limitation, not a
  # shortcut here), so this is action-scoped rather than resource-scoped.
  statement {
    sid    = "NetworkingModule2"
    effect = "Allow"
    actions = [
      "ec2:*Vpc*",
      "ec2:*Subnet*",
      "ec2:*SecurityGroup*",
      "ec2:*RouteTable*",
      "ec2:*InternetGateway*",
      "ec2:*VpcEndpoint*",
      "ec2:DescribeAvailabilityZones",
      "ec2:CreateTags",
      "ec2:DeleteTags",
    ]
    resources = ["*"]
  }

  # Module 3 — data layer. The README's original placeholder guessed
  # rds:*/elasticache:* before the actual design landed; the real decision
  # was self-hosted-on-Fargate + EFS (see chaosforge/data-layer.tf and
  # rpe/data-layer.tf for why), so this grants EFS, not RDS/ElastiCache.
  statement {
    sid    = "DataLayerModule3"
    effect = "Allow"
    actions = [
      "elasticfilesystem:CreateFileSystem",
      "elasticfilesystem:DeleteFileSystem",
      "elasticfilesystem:DescribeFileSystems",
      "elasticfilesystem:TagResource",
      "elasticfilesystem:CreateAccessPoint",
      "elasticfilesystem:DeleteAccessPoint",
      "elasticfilesystem:DescribeAccessPoints",
      "elasticfilesystem:CreateMountTarget",
      "elasticfilesystem:DeleteMountTarget",
      "elasticfilesystem:DescribeMountTargets",
      "elasticfilesystem:DescribeMountTargetSecurityGroups",
      "elasticfilesystem:ModifyMountTargetSecurityGroups",
    ]
    resources = ["*"]
  }

  # Module 4 — compute. Includes the NAT/EIP actions that Module 2's
  # original grant didn't need (NAT Gateway was added in Module 4, not 2 —
  # see network.tf's reversal note).
  statement {
    sid    = "ComputeModule4"
    effect = "Allow"
    actions = [
      "ec2:*NatGateway*",
      "ec2:AllocateAddress",
      "ec2:ReleaseAddress",
      "ec2:DescribeAddresses",
      "ec2:AssociateAddress",
      "ec2:DisassociateAddress",
      "ecs:*",
      "ecr:*",
      "servicediscovery:*",
      "elasticloadbalancing:*",
      "logs:CreateLogGroup",
      "logs:DeleteLogGroup",
      "logs:DescribeLogGroups",
      "logs:PutRetentionPolicy",
      "logs:TagResource",
    ]
    resources = ["*"]
  }

  # R2 fix: iam:*Role* scoped to local.managed_role_arns; grant actions also require the
  # task-role permissions boundary (iam-task-role-boundary.tf) so no role can escalate beyond it.
  statement {
    sid    = "ManageOwnedRoles"
    effect = "Allow"
    actions = [
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:DetachRolePolicy",
      "iam:TagRole",
    ]
    resources = local.managed_role_arns
  }

  statement {
    sid    = "CreateOwnedRolesWithBoundary"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:PutRolePolicy",
      "iam:AttachRolePolicy",
    ]
    resources = local.managed_role_arns
    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [aws_iam_policy.task_role_boundary.arn]
    }
  }

  # Module 5 — secrets. SSM SecureString only; secretsmanager:* trimmed (unused, dormant attack surface).
  statement {
    sid    = "SecretsModule5"
    effect = "Allow"
    actions = [
      "ssm:PutParameter",
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:DeleteParameter",
      "ssm:AddTagsToResource",
      "ssm:ListTagsForResource",
      "ssm:DescribeParameters",
    ]
    resources = ["*"] # parameter ARNs aren't known until creation; the role is deploy-time-only and statement-scoped
  }

  # Module 8 — chaos (FIS). Templates + the FIS experiment role live in these roots; the deploy
  # role needs to manage them. fis:* covers template CRUD; the experiment role's own creation is
  # covered by the iam:*Role* actions already granted in ComputeModule4.
  statement {
    sid    = "ChaosModule8"
    effect = "Allow"
    actions = [
      "fis:CreateExperimentTemplate",
      "fis:UpdateExperimentTemplate",
      "fis:DeleteExperimentTemplate",
      "fis:GetExperimentTemplate",
      "fis:ListExperimentTemplates",
      "fis:TagResource",
    ]
    resources = ["*"]
  }

  # FIS stop-condition alarms (rpe/fis.tf, chaosforge/fis.tf) need create/refresh/destroy here.
  # Experiment role's own DescribeAlarms grant lives in foundation/fis.tf.
  statement {
    sid       = "ChaosModule8StopConditionAlarmsRead"
    effect    = "Allow"
    actions   = ["cloudwatch:DescribeAlarms", "cloudwatch:ListTagsForResource"]
    resources = ["*"]
  }
  statement {
    sid    = "ChaosModule8StopConditionAlarmsWrite"
    effect = "Allow"
    actions = [
      "cloudwatch:PutMetricAlarm",
      "cloudwatch:DeleteAlarms",
      "cloudwatch:TagResource",
      "cloudwatch:UntagResource",
    ]
    resources = ["arn:aws:cloudwatch:${var.aws_region}:*:alarm:*-fis-steady-state-breach"]
  }

  # Module 9 — cost guardrail. The budget-teardown Lambda + its SNS subscription (cost-guardrail.tf).
  statement {
    sid    = "CostGuardrailModule9"
    effect = "Allow"
    actions = [
      "lambda:CreateFunction",
      "lambda:DeleteFunction",
      "lambda:GetFunction",
      "lambda:UpdateFunctionCode",
      "lambda:UpdateFunctionConfiguration",
      "lambda:AddPermission",
      "lambda:RemovePermission",
      "lambda:GetPolicy",
      "lambda:TagResource",
      "sns:Subscribe",
      "sns:Unsubscribe",
      "sns:GetTopicAttributes",
      "sns:ListSubscriptionsByTopic",
    ]
    resources = ["*"]
  }

  # Budget topic create/tag/attrs — scoped to the single topic foundation owns.
  statement {
    sid    = "BudgetTopicManagement"
    effect = "Allow"
    actions = [
      "sns:CreateTopic",
      "sns:DeleteTopic",
      "sns:SetTopicAttributes",
      "sns:ListTagsForResource",
      "sns:TagResource",
      "sns:UntagResource",
    ]
    resources = [aws_sns_topic.budget_alerts.arn]
  }

  # PassRole scoped to local.managed_role_arns only — unscoped PassRole is a priv-esc primitive.
  # Same set CI may CREATE must be the same set it may PASS (R2 fix).
  statement {
    sid       = "PassEcsRolesOnly"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = local.managed_role_arns
  }
}

resource "aws_iam_role_policy" "deploy_permissions" {
  name   = "foundation-permissions"
  role   = aws_iam_role.github_deploy.id
  policy = data.aws_iam_policy_document.deploy_permissions.json
}
