# Ref: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/budgets_budget
resource "aws_sns_topic" "budget_alerts" {
  name = "chaosforge-budget-alerts"
}

data "aws_caller_identity" "current" {}

# WITHOUT THIS, THE ENTIRE COST CIRCUIT BREAKER IS INERT — SNS denies budgets.amazonaws.com without it.
resource "aws_sns_topic_policy" "budget_alerts" {
  arn = aws_sns_topic.budget_alerts.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowAWSBudgetsPublish"
      Effect    = "Allow"
      Principal = { Service = "budgets.amazonaws.com" }
      Action    = "SNS:Publish"
      Resource  = aws_sns_topic.budget_alerts.arn
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:budgets::${data.aws_caller_identity.current.account_id}:*" }
      }
    }]
  })
}

resource "aws_sns_topic_subscription" "budget_email" {
  topic_arn = aws_sns_topic.budget_alerts.arn
  protocol  = "email"
  endpoint  = var.budget_alert_email
}

resource "aws_budgets_budget" "monthly_cap" {
  name         = "chaosforge-platform-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Actual spend crossed 80% of the cap.
  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 80
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.budget_alerts.arn]
  }

  # AWS Cost Explorer's forecast says this month will exceed the cap —
  # catches the trend before the ACTUAL alert would fire.
  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [aws_sns_topic.budget_alerts.arn]
  }
}
