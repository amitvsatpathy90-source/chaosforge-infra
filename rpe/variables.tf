# Declares the variable locally so the rpe module can use the enable_fis flag.
variable "enable_fis" {
  description = "Create FIS experiment templates (blocked by SubscriptionRequiredException until account is activated for FIS)"
  type        = bool
  default     = true
}