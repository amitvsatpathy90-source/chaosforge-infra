provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "chaosforge-platform"
      ManagedBy = "terraform"
      Layer     = "foundation"
    }
  }
}
