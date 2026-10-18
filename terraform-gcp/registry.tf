# The signed images, mirrored from ECR by digest with their .sig and .att (ADR 0014, decision 5:
# `cosign copy`, a later PR). Same digest, so the signatures stay valid. GKE pulls from here as
# the gke-nodes service account (roles/artifactregistry.reader, terraform-gcp-bootstrap).
resource "google_artifact_registry_repository" "boutique" {
  project       = var.project_id
  location      = var.region
  repository_id = "boutique"
  format        = "DOCKER"
  description   = "Signed Online Boutique images mirrored from ECR (ADR 0014). Images: <region>-docker.pkg.dev/<project>/boutique/<service>"

  # Like ECR: a tag (the commit SHA) always names the same image.
  docker_config {
    immutable_tags = true
  }

  # Like the ECR lifecycle rule (terraform-aws/ecr.tf): the last 20 builds of each image, 3
  # artifacts per build (image, .sig, .att), so 60 versions. Keep rules win over delete rules.
  cleanup_policy_dry_run = false
  cleanup_policies {
    id     = "keep-last-builds"
    action = "KEEP"
    most_recent_versions {
      keep_count = var.registry_builds_kept * 3
    }
  }
  cleanup_policies {
    id     = "delete-older"
    action = "DELETE"
    condition {
      tag_state  = "ANY"
      older_than = "86400s" # never a version pushed in the last day (a copy in progress)
    }
  }
}
