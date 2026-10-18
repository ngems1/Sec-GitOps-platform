# One-time GCP bootstrap (ADR 0014): what GitHub Actions needs BEFORE it can run terraform-gcp,
# and what must outlive a terraform-gcp destroy. The GCP twin of terraform-bootstrap.
#   main.tf        the APIs, and the GCS bucket for every Terraform state of this project
#   federation.tf  Workload Identity Federation for GitHub (this repository only, by ID), and
#                  three service accounts: plan (pull requests), deploy (main, dev/prod), bootstrap
#   policies.tf    no service account keys (organization policies)
#   budgets.tf     the project's monthly budget, email alerts at 50% and 100%
# First run: by the project owner, from a laptop (README.md). Then .github/workflows/bootstrap-gcp.yml.

data "google_project" "this" {
  project_id = var.project_id
}

locals {
  bucket_name = "${var.project_id}-tfstate"
}

# ---------------------------------------------------------------------------
# APIs. serviceusage and cloudresourcemanager must be on before Terraform can enable the
# rest (README.md, step 2). Never disabled by a destroy: other things may use them.
# ---------------------------------------------------------------------------
locals {
  apis = toset(concat([
    "serviceusage.googleapis.com",         # enabling APIs
    "cloudresourcemanager.googleapis.com", # project IAM
    "iam.googleapis.com",                  # service accounts, workload identity pools
    "iamcredentials.googleapis.com",       # impersonation: short-lived service account tokens
    "sts.googleapis.com",                  # token exchange: GitHub OIDC token -> federated token
    "storage.googleapis.com",              # the state bucket
    "cloudbilling.googleapis.com",         # billing account IAM (the bootstrap service account)
    "billingbudgets.googleapis.com",       # the budget
  ], var.enforce_no_key_policy ? ["orgpolicy.googleapis.com"] : []))
}

resource "google_project_service" "apis" {
  for_each = local.apis

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# terraform-gcp's APIs: gha-deploy can't enable APIs (serviceUsageViewer only), so they are on
# here. After the organization policy: enabling Compute Engine creates its default service
# account, which must not get Editor (policies.tf).
resource "google_project_service" "gke_apis" {
  for_each = toset([
    "compute.googleapis.com",          # VPC, subnet, Cloud NAT
    "container.googleapis.com",        # the GKE cluster
    "artifactregistry.googleapis.com", # the mirrored images
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false

  depends_on = [google_org_policy_policy.no_default_sa_editor]
}

# ---------------------------------------------------------------------------
# Terraform state bucket: terraform-gcp under prefix "gcp-infra", this root under "bootstrap".
# ---------------------------------------------------------------------------
resource "google_storage_bucket" "state" {
  name     = local.bucket_name
  project  = var.project_id
  location = upper(var.region)

  uniform_bucket_level_access = true       # IAM only, no object ACLs
  public_access_prevention    = "enforced" # never public, whatever IAM says
  force_destroy               = false

  versioning {
    enabled = true
  }

  # Keep the last 20 versions of each state file.
  lifecycle_rule {
    condition {
      num_newer_versions = 20
      with_state         = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }

  # Losing the state means Terraform forgets everything it created.
  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.apis]
}
