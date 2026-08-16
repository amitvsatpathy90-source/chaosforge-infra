# Injected at `terraform init -backend-config=backend.hcl` time — see
# foundation/backend.tf for why this can't be a variable.
terraform {
  backend "s3" {
    key          = "chaosforge/terraform.tfstate"
    use_lockfile = true
    encrypt      = true
  }
}
