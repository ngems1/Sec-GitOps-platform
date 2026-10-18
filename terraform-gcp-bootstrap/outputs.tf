# GitHub variables (README.md, step 5). The bootstrap-gcp workflow does NOT print them (the
# repository and its logs are public): read them once with `terraform output` on the first run.

output "GCP_PROJECT_ID" {
  value = var.project_id
}

output "GCP_REGION" {
  value = var.region
}

output "GCP_WIF_PROVIDER" {
  description = "workload_identity_provider of google-github-actions/auth"
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "GCP_PLAN_SA" {
  value = google_service_account.gha["plan"].email
}

output "GCP_DEPLOY_SA" {
  value = google_service_account.gha["deploy"].email
}

output "GCP_BOOTSTRAP_SA" {
  value = google_service_account.gha["bootstrap"].email
}

output "GCP_TF_STATE_BUCKET" {
  value = google_storage_bucket.state.name
}

output "GCP_GKE_NODE_SA" {
  description = "Service account of the GKE nodes (terraform-gcp: node_config / cluster_autoscaling service account)"
  value       = google_service_account.gke_nodes.email
}
