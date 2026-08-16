# Same reasoning as chaosforge/ecr.tf: app images need a private repo
# regardless (built from this codebase); data-layer images are mirrored to
# avoid Docker Hub's anonymous pull-rate limit on an on-demand workload
# that recreates tasks every session.

locals {
  rpe_app_images  = ["detection", "relay", "alert", "triage"]
  rpe_data_images = ["postgres", "redis", "redpanda"]
}

resource "aws_ecr_repository" "app" {
  for_each             = toset(local.rpe_app_images)
  name                 = "rpe/${each.value}"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_repository" "data_mirror" {
  for_each             = toset(local.rpe_data_images)
  name                 = "rpe/mirror/${each.value}"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

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
