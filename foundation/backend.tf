# bucket/region omitted (backend blocks can't reference variables); injected via
# `terraform init -backend-config=backend.hcl` (gitignored — keeps account ID out of git).
terraform {
  backend "s3" {
    key          = "foundation/terraform.tfstate"
    use_lockfile = true
    encrypt      = true
  }
}
