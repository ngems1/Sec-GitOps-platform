# Workload Identity Federation for GitHub Actions (ADR 0014, decision 2): no service account
# key exists anywhere. A job gets a GitHub OIDC token, exchanges it for a federated token (STS),
# then a 1-hour access token of ONE service account (impersonation). The same posture as the AWS
# trust in terraform-bootstrap/main.tf:
#   - this repository only, by its immutable numeric IDs (the provider's attribute condition):
#     a fork, another repository, or this name re-created by someone else gets nothing;
#   - plan     <- pull_request events                  (AWS: sub ...:pull_request)
#     deploy   <- refs/heads/main, or a dev/prod job    (AWS: ...:ref:refs/heads/main, ...:environment:dev|prod)
#     bootstrap<- jobs in the protected prod environment (AWS: the hand-made week3-bootstrap role)

resource "google_iam_workload_identity_pool" "github" {
  project                   = var.project_id
  workload_identity_pool_id = "github-actions"
  display_name              = "GitHub Actions"
  description               = "GitHub Actions of this repository only (terraform-gcp-bootstrap, ADR 0014)"

  depends_on = [google_project_service.apis]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "sec-gitops-platform"
  display_name                       = "GitHub: this repository"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
    # No allowed_audiences: the default audience is this provider's own resource name, which is
    # what google-github-actions/auth asks GitHub for.
  }

  # Claims -> attributes. The "environment" claim exists only for jobs in an environment, so the
  # environment is read from "sub" instead (always there, ...:environment:<name> for those jobs,
  # the same value the AWS deploy trust matches): "" for any other job, which no binding uses.
  attribute_mapping = {
    "google.subject"                = "assertion.sub"
    "attribute.repository_id"       = "assertion.repository_id"
    "attribute.repository_owner_id" = "assertion.repository_owner_id"
    "attribute.event_name"          = "assertion.event_name"
    "attribute.ref"                 = "assertion.ref"
    "attribute.environment"         = "assertion.sub.contains(':environment:') ? assertion.sub.split(':environment:')[1] : ''"
  }

  # The trust boundary: tokens of any other repository (forks included: they have their own
  # repository_id) are refused at the exchange, before any service account is considered.
  attribute_condition = "assertion.repository_id == '${var.github_repo_id}' && assertion.repository_owner_id == '${var.github_owner_id}'"
}

locals {
  pool = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}"
  sa = {
    plan      = { id = "gha-plan", name = "GitHub Actions: plan (pull requests, read-only)" }
    deploy    = { id = "gha-deploy", name = "GitHub Actions: apply and deploy (main, dev/prod)" }
    bootstrap = { id = "gha-bootstrap", name = "GitHub Actions: bootstrap-gcp (prod environment)" }
  }
  # Which GitHub contexts may impersonate which service account (roles/iam.workloadIdentityUser):
  # attributes of the pool (the pool's name is only known once it exists, so it is added below).
  who = {
    plan      = ["attribute.event_name/pull_request"]
    deploy    = concat(["attribute.ref/refs/heads/main"], [for e in var.github_environments : "attribute.environment/${e}"])
    bootstrap = ["attribute.environment/${var.bootstrap_environment}"]
  }
}

resource "google_service_account" "gha" {
  for_each = local.sa

  project      = var.project_id
  account_id   = each.value.id
  display_name = each.value.name
  description  = "terraform-gcp-bootstrap (ADR 0014). No keys: used only through Workload Identity Federation."
}

resource "google_service_account_iam_member" "federation" {
  for_each = { for p in flatten([for k, attrs in local.who : [for a in attrs : { sa = k, attr = a }]]) : "${p.sa} ${p.attr}" => p }

  service_account_id = google_service_account.gha[each.value.sa].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "${local.pool}/${each.value.attr}"
}

# ---------------------------------------------------------------------------
# What each service account may do in the project.
# ---------------------------------------------------------------------------
locals {
  project_roles = {
    # Read-only, like the AWS plan role's ReadOnlyAccess. Plus the state below.
    plan = ["roles/viewer", "roles/iam.securityReviewer"]
    # terraform-gcp (ADR 0014: VPC, Cloud NAT, Autopilot cluster, Artifact Registry, static IP).
    # Not roles/editor or owner: editor may act as ANY service account of the project (the
    # bootstrap one is owner) and create service account keys. None of these roles can do either,
    # and none grants project IAM: service accounts and project roles are all granted here.
    # No compute.securityAdmin: terraform-gcp creates no firewall rules (GKE makes its own).
    deploy = [
      "roles/compute.networkAdmin",
      "roles/container.admin",
      "roles/artifactregistry.admin",
      "roles/serviceusage.serviceUsageViewer",
      "roles/iam.securityReviewer",
    ]
    # Re-runs of this root: it creates IAM, pools, policies (like the AWS bootstrap role, admin).
    bootstrap = ["roles/owner"]
  }
}

resource "google_project_iam_member" "gha" {
  for_each = { for p in flatten([for k, roles in local.project_roles : [for r in roles : { sa = k, role = r }]]) : "${p.sa} ${p.role}" => p }

  project = var.project_id
  role    = each.value.role
  member  = google_service_account.gha[each.value.sa].member
}

# State: plan takes the lock (writes the .tflock object), deploy writes the state, bootstrap
# owns the project anyway. Bucket-level only, never project-wide storage rights.
resource "google_storage_bucket_iam_member" "state" {
  for_each = toset(["plan", "deploy"])

  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectUser"
  member = google_service_account.gha[each.value].member
}
