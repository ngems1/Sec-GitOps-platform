# No service account keys, ever (ADR 0014). Organization policies on the project: creating or
# uploading a key is refused for everyone, owners included. They exist only for projects inside
# a Google Cloud organization (var.enforce_no_key_policy, README.md step 1).
#
# Without an organization the keys are still kept out by IAM: none of the CI service accounts
# except gha-bootstrap (owner) holds iam.serviceAccountKeys.create (federation.tf), and the
# bootstrap-gcp workflow fails if any user-managed key exists on them.

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
