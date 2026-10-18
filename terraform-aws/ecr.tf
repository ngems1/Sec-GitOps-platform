resource "aws_ecr_repository" "svc" {
  for_each = toset(var.services)

  name                 = "${var.ecr_prefix}/${each.value}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true # lets `terraform destroy` remove repos that still hold images

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
  }
}

# Keep the last 20 builds of each repository (the rollback window, deploy workflow's image_tag).
#
# Each build pushes 3 artifacts to every repository (ADR 0012): the image (tag = commit SHA), its
# cosign signature (tag sha256-<digest>.sig) and its SBOM attestation (sha256-<digest>.att). The
# count therefore covers 3 artifacts per build: 60.
#
# Why not count the images alone: ECR cannot select them. Their tags are bare 12-character SHAs
# with no common prefix, and tag filters cannot exclude a pattern (no "not sha256-*"). A
# higher-priority rule for sha256-* would not help either: lower-priority rules still count the
# images it selects ("can still identify them as if they haven't been expired"). Counting every
# artifact is safe for signatures: expiry goes oldest first by push time, and a signature and an
# attestation are always pushed after their image, so an image is never kept without them.
locals {
  ecr_builds_kept         = 20
  ecr_artifacts_per_build = 3 # image + .sig + .att
}

resource "aws_ecr_lifecycle_policy" "svc" {
  for_each   = aws_ecr_repository.svc
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last ${local.ecr_builds_kept} builds (image, signature, SBOM attestation)"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = local.ecr_builds_kept * local.ecr_artifacts_per_build
      }
      action = {
        type = "expire"
      }
    }]
  })
}
