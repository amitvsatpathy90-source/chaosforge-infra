# Data-layer images mirrored to private ECR to avoid Docker Hub pull-rate limits; app images
# built from this codebase. Terraform declares repos only — pushing is CI (Module 7) or a
# documented manual step, not local-exec.

locals {
  chaosforge_app_images  = ["edge-gateway", "control-plane", "execution-service"]
  chaosforge_data_images = ["postgres", "redis", "redpanda"]
}

resource "aws_ecr_repository" "app" {
  for_each             = toset(local.chaosforge_app_images)
  name                 = "chaosforge/${each.value}"
  image_tag_mutability = "IMMUTABLE" # a tag is a specific build, never silently replaced — matches production release discipline.

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_repository" "data_mirror" {
  for_each             = toset(local.chaosforge_data_images)
  name                 = "chaosforge/mirror/${each.value}"
  image_tag_mutability = "MUTABLE" # these track upstream tags (e.g. "16.4-alpine"), not a build artifact of this repo

  image_scanning_configuration {
    scan_on_push = true
  }
}

# 7-day expiry on untagged layers only — never touches a tagged image.
# Keeps ECR storage cost from growing unbounded across repeated CI builds
# without ever deleting something you might still reference.
resource "aws_ecr_lifecycle_policy" "untagged_cleanup" {
  for_each   = merge(aws_ecr_repository.app, aws_ecr_repository.data_mirror)
  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images after 7 days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 7
      }
      action = { type = "expire" }
    }]
  })
}
