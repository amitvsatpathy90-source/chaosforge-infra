variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "monthly_budget_usd" {
  description = "Hard monthly cost ceiling across the account. Alert fires at 80% actual and 100% forecasted; Module 9 wires the SNS topic to an actual teardown action."
  type        = number
  default     = 25
}

variable "budget_alert_email" {
  description = "Email subscribed to the budget-threshold SNS topic"
  type        = string
}

variable "github_repositories" {
  description = "GitHub \"org/repo\" strings allowed to assume the CI deploy role via OIDC, e.g. [\"amitsatpathy/chaosforge\", \"amitsatpathy/revenue-protection-engine\"]"
  type        = list(string)
}

variable "github_immutable_subs" {
  description = "Full OIDC 'sub' strings for repos on GitHub's immutable subject format (owner@ownerID/repo@repoID) — needed alongside github_repositories when a repo predates or postdates the cutoff differently than its siblings."
  type        = list(string)
  default     = []
}
