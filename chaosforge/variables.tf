# One-way cross-system dependency: chaosforge/ -> rpe/ via plain variable (ADR-0401).
# Apply order: rpe/ first, copy its detection_security_group_id output here, then chaosforge/.
variable "rpe_detection_security_group_id" {
  description = "rpe/'s detection_security_group_id output, after rpe/ has been applied at least once"
  type        = string
}

# Module 7 fix: the app task definitions referenced `:latest`, but the app ECR repos are IMMUTABLE
# (ecr.tf) — a `latest` tag can never be pushed there, so every task launch would have failed with
# an image-pull error. CI pushes :<12-char-git-sha> (.github/workflows/ci.yml in the chaosforge
# repo); pass that SHA here. Required on purpose — a default of "latest" would just re-hide the bug.
variable "image_tag" {
  description = "Image tag for the three app services — the 12-char git SHA pushed by chaosforge's CI"
  type        = string
}

# Defaults to 3 days: on-demand sessions are hours, not weeks, and CloudWatch Logs bills per-GB
# ingested + stored, so short retention is the near-$0 default. Raise to 90+ for any audited
# environment (SOC 2 / PCI generally expect 90 days hot + longer retained) — a per-GB cost increase,
# hence a variable rather than a hardcode.
variable "log_retention_days" {
  description = "CloudWatch Logs retention for the app + data task log groups. Default 3 (lab); 90+ for an audited environment."
  type        = number
  default     = 3
}
