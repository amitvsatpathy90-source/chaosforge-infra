# SSM SecureString — see chaosforge/secrets.tf for the cost/destroy rationale.
# Single `rpe` DB login (compose parity, not per-service k8s/CNPG roles) — ADR-0403.

resource "random_password" "postgres_admin_password" {
  length  = 32
  special = false
}

# Both the postgres container's POSTGRES_PASSWORD and every service's DB_PASSWORD — one login,
# compose parity (above).
resource "aws_ssm_parameter" "postgres_password" {
  name  = "/rpe/postgres-password"
  type  = "SecureString"
  value = random_password.postgres_admin_password.result
}

# Real secret, verified — spring.ai.openai.api-key has a sentinel default ("llm-disabled-sentinel",
# ADR-15 §9) that makes triage degrade to DEGRADED_RULE_BASED rather than fail to start. With the
# NAT default-off (foundation/network.tf, Module 5.5) triage can't reach OpenAI anyway, so the
# sentinel default is also the honest default: degraded mode unless you both set this AND enable
# the NAT for the session.
variable "openai_api_key" {
  description = "SPRING_AI_OPENAI_API_KEY for rpe-triage-agent. Leave unset to run in documented degraded mode (ADR-15 §9). Only useful together with foundation's enable_nat_gateway=true."
  type        = string
  sensitive   = true
  default     = ""
}

resource "aws_ssm_parameter" "openai_api_key" {
  name  = "/rpe/openai-api-key"
  type  = "SecureString"
  value = var.openai_api_key != "" ? var.openai_api_key : "llm-disabled-sentinel"
}

# ── OAuth issuer/JWKS/audience — NOT secrets ("ConfigMap, not Secret") ──
# Issuer/audience byte-identical to local (opaque exact-match, never dereferenced). JWKS URI is
# the only AWS drift point — see ADR-0404 and LOCAL-PARITY.md. String type, not SecureString.
resource "aws_ssm_parameter" "oauth_issuer" {
  name  = "/rpe/oauth/issuer"
  type  = "String"
  value = "http://rpe-jwks-stub" # opaque constant; MUST equal mint-jwt.sh's ISS, exact-string match
}

resource "aws_ssm_parameter" "oauth_jwks_uri" {
  name  = "/rpe/oauth/jwks-uri"
  type  = "String"
  value = local.jwks_stub_url # foundation/jwks-stub.tf — the one value that differs from local
}

resource "aws_ssm_parameter" "oauth_audience" {
  name  = "/rpe/oauth/audience"
  type  = "String"
  value = "rpe-actuator" # the k8s ConfigMap's one non-blank default
}
