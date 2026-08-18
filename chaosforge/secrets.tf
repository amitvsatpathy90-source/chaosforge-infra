# SSM SecureString, not Secrets Manager - cost + destroy-recovery-window fights. See cost-model.md.
# DB password: Terraform-generated. mTLS passwords: Terraform-accepted, must match generate-certs.sh.
# CP/Exec share one Postgres login - see docs/adrs/ADR-0403.md.

resource "random_password" "db_password" {
  length  = 32
  special = false # round-trips through JDBC URLs / env vars without escaping surprises
}

resource "aws_ssm_parameter" "db_username" {
  name  = "/chaosforge/db/username"
  type  = "SecureString"
  value = "chaosforge"
}

resource "aws_ssm_parameter" "db_password" {
  name  = "/chaosforge/db/password"
  type  = "SecureString"
  value = random_password.db_password.result
}

variable "mtls_keystore_password" {
  description = "Must match the password generate-certs.sh was actually run with (mtls-rules.md) - not generated here."
  type        = string
  sensitive   = true
}

variable "mtls_truststore_password" {
  description = "Same caveat as mtls_keystore_password."
  type        = string
  sensitive   = true
}

resource "aws_ssm_parameter" "mtls_keystore_password" {
  name  = "/chaosforge/mtls/keystore-password"
  type  = "SecureString"
  value = var.mtls_keystore_password
}

resource "aws_ssm_parameter" "mtls_truststore_password" {
  name  = "/chaosforge/mtls/truststore-password"
  type  = "SecureString"
  value = var.mtls_truststore_password
}

# JWKS endpoint - served by the shared lab IdP stub (foundation/jwks-stub.tf).
# " " crashloop history: see docs/adrs/ADR-0404.md.
# Not SecureString - a JWKS URI is not a credential.
resource "aws_ssm_parameter" "jwk_set_uri" {
  name  = "/chaosforge/jwk-set-uri"
  type  = "String"
  value = local.jwks_stub_url # shared stub; serves chaosforge-lab-1 + rpe-lab-1, decoders pick by kid
}
