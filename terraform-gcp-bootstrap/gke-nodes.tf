# The service account the GKE Autopilot nodes run as (ADR 0014), here and not in terraform-gcp:
# creating service accounts needs service-account admin, which gha-deploy must never hold (a
# stolen deploy token could then create accounts and grant them anything). This root runs on
# the higher-trust path (the owner, or gha-bootstrap in the protected prod environment).
#
# Not the Compute Engine default service account (editor on the project by default): this one
# can only write logs and metrics, read monitoring, and pull images.

resource "google_service_account" "gke_nodes" {
  project      = var.project_id
  account_id   = "gke-nodes"
  display_name = "GKE Autopilot nodes (terraform-gcp)"
  description  = "terraform-gcp-bootstrap (ADR 0014): runs the GKE nodes. Logs, metrics, monitoring read, image pulls. No keys, no federation."
}

locals {
  gke_node_roles = [
    "roles/logging.logWriter",       # node and container logs to Cloud Logging
    "roles/monitoring.metricWriter", # system metrics to Cloud Monitoring
    "roles/monitoring.viewer",       # read its own metrics (autoscaling, metrics agent)
    "roles/artifactregistry.reader", # pull the mirrored images (ADR 0014, decision 5)
  ]
}

resource "google_project_iam_member" "gke_nodes" {
  for_each = toset(local.gke_node_roles)

  project = var.project_id
  role    = each.value
  member  = google_service_account.gke_nodes.member
}

# terraform-gcp (as gha-deploy) creates the cluster with this account as the nodes' identity,
# which needs act-as on it: granted on this one account only, never project-wide.
resource "google_service_account_iam_member" "deploy_uses_gke_nodes" {
  service_account_id = google_service_account.gke_nodes.name
  role               = "roles/iam.serviceAccountUser"
  member             = google_service_account.gha["deploy"].member
}
