# Budget-breach backstop: Lambda scales every ECS service to 0 on SNS alert. Idempotent,
# never touches Terraform state or runs destroy. Default ON.

variable "enable_budget_teardown" {
  description = "Default true: on a budget-threshold SNS alert, a Lambda scales all ECS services to 0 (stops Fargate burn - the only thing that climbs the bill post-5.5). Idempotent, safe, ~$0 to keep armed."
  type        = bool
  default     = true
}

data "archive_file" "budget_teardown" {
  count       = var.enable_budget_teardown ? 1 : 0
  type        = "zip"
  output_path = "${path.module}/.build/budget_teardown.zip"
  source {
    filename = "index.py"
    content  = <<-PY
      import boto3

      ecs = boto3.client("ecs")
      CLUSTER = "${aws_ecs_cluster.platform.name}"

      def handler(event, context):
          # Scale every service in the platform cluster to 0. Idempotent: already-0 services are
          # updated to 0 again (no-op). This is the budget circuit breaker - see cost-guardrail.tf.
          paginator = ecs.get_paginator("list_services")
          zeroed = []
          for page in paginator.paginate(cluster=CLUSTER):
              for svc_arn in page["serviceArns"]:
                  ecs.update_service(cluster=CLUSTER, service=svc_arn, desiredCount=0)
                  zeroed.append(svc_arn.split("/")[-1])
          print(f"budget teardown: scaled {len(zeroed)} services to 0: {zeroed}")
          return {"zeroed": zeroed}
    PY
  }
}

data "aws_iam_policy_document" "budget_teardown_assume" {
  count = var.enable_budget_teardown ? 1 : 0
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "budget_teardown" {
  count                = var.enable_budget_teardown ? 1 : 0
  name                 = "platform-budget-teardown"
  assume_role_policy   = data.aws_iam_policy_document.budget_teardown_assume[0].json
  permissions_boundary = aws_iam_policy.task_role_boundary.arn # R2 fix - see iam-task-role-boundary.tf
}

data "aws_iam_policy_document" "budget_teardown_permissions" {
  count = var.enable_budget_teardown ? 1 : 0

  # List/Describe don't support resource scoping; UpdateService is scoped to this cluster's services.
  statement {
    effect    = "Allow"
    actions   = ["ecs:ListServices"]
    resources = ["*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["ecs:UpdateService"]
    resources = ["arn:aws:ecs:${var.aws_region}:*:service/${aws_ecs_cluster.platform.name}/*"]
  }
  # CloudWatch Logs for the Lambda's own output - no log group pre-created; Lambda makes it.
  statement {
    effect    = "Allow"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:${var.aws_region}:*:*"]
  }
}

resource "aws_iam_role_policy" "budget_teardown" {
  count  = var.enable_budget_teardown ? 1 : 0
  name   = "platform-budget-teardown"
  role   = aws_iam_role.budget_teardown[0].id
  policy = data.aws_iam_policy_document.budget_teardown_permissions[0].json
}

resource "aws_lambda_function" "budget_teardown" {
  count            = var.enable_budget_teardown ? 1 : 0
  function_name    = "platform-budget-teardown"
  role             = aws_iam_role.budget_teardown[0].arn
  runtime          = "python3.13"
  handler          = "index.handler"
  filename         = data.archive_file.budget_teardown[0].output_path
  source_code_hash = data.archive_file.budget_teardown[0].output_base64sha256
  timeout          = 60 # list+update a handful of services; generous
}

# The SNS topic (budgets.tf) already emails you; this adds the Lambda as a SECOND subscriber to the
# same topic, so a threshold breach both notifies AND acts.
resource "aws_sns_topic_subscription" "budget_teardown" {
  count     = var.enable_budget_teardown ? 1 : 0
  topic_arn = aws_sns_topic.budget_alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.budget_teardown[0].arn
}

resource "aws_lambda_permission" "budget_teardown_from_sns" {
  count         = var.enable_budget_teardown ? 1 : 0
  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.budget_teardown[0].function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.budget_alerts.arn
}
