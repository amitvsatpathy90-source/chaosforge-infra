variable "state_bucket_name" {
  description = "Bucket created by bootstrap/ (its state_bucket_name output) — same bucket foundation/ and chaosforge/ use"
  type        = string
}

data "terraform_remote_state" "foundation" {
  backend = "s3"
  config = {
    bucket = var.state_bucket_name
    key    = "foundation/terraform.tfstate"
    region = var.aws_region
  }
}

# rpe/ reads foundation/'s state and NOTHING else. It deliberately does not read
# chaosforge/'s state: that reverse read, combined with chaosforge/ needing rpe/'s
# detection_security_group_id output, made the two roots mutually dependent and left no
# valid first-apply order. Both halves of the cross-system steady-state probe rule are now
# declared in chaosforge/security-groups.tf, which holds both SG ids. Keep it that way —
# adding a terraform_remote_state read of chaosforge/ here reintroduces the cycle.
locals {
  vpc_id                             = data.terraform_remote_state.foundation.outputs.vpc_id
  vpc_cidr                           = data.terraform_remote_state.foundation.outputs.vpc_cidr
  private_subnet_ids                 = data.terraform_remote_state.foundation.outputs.private_rpe_subnet_ids
  vpc_endpoints_security_group_id    = data.terraform_remote_state.foundation.outputs.vpc_endpoints_security_group_id
  s3_prefix_list_id                  = data.terraform_remote_state.foundation.outputs.s3_prefix_list_id
  task_role_permissions_boundary_arn = data.terraform_remote_state.foundation.outputs.task_role_permissions_boundary_arn
  jwks_stub_security_group_id        = data.terraform_remote_state.foundation.outputs.jwks_stub_security_group_id
  jwks_stub_url                      = data.terraform_remote_state.foundation.outputs.jwks_stub_url
}
