# Organization policies on the project. They exist only for projects inside a Google Cloud
# organization (var.enforce_no_key_policy, README.md step 1).

# No service account keys, ever (ADR 0014): creating or uploading a key is refused for everyone,
# owners included. Without an organization the keys are still kept out by IAM: none of the CI
# service accounts except gha-bootstrap (owner) holds iam.serviceAccountKeys.create
# (federation.tf), and the bootstrap-gcp workflow fails if any user-managed key exists on them.
resource "google_org_policy_policy" "no_key_creation" {
  for_each = var.enforce_no_key_policy ? toset([
    "iam.disableServiceAccountKeyCreation",
    "iam.disableServiceAccountKeyUpload",
  ]) : toset([])

  name   = "projects/${var.project_id}/policies/${each.value}"
  parent = "projects/${var.project_id}"

  spec {
    rules {
      enforce = "TRUE"
    }
  }

  depends_on = [google_project_service.apis]
}

# No automatic Editor for the default service accounts: enabling Compute Engine (main.tf,
# gke_apis, which waits for this policy) creates the Compute Engine default service account,
# which otherwise gets roles/editor on the project. Not retroactive: an account created before
# the policy keeps its Editor role (README.md).
resource "google_org_policy_policy" "no_default_sa_editor" {
  count = var.enforce_no_key_policy ? 1 : 0

  name   = "projects/${var.project_id}/policies/iam.automaticIamGrantsForDefaultServiceAccounts"
  parent = "projects/${var.project_id}"

  spec {
    rules {
      enforce = "TRUE"
    }
  }

  depends_on = [google_project_service.apis]
}
