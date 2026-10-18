# Read by later steps (the image mirror, the Argo CD registration). The infra-gcp workflow does
# NOT print them: the repository and its logs are public, and they hold the project ID.

output "cluster_name" {
  value = google_container_cluster.main.name
}

output "cluster_location" {
  value = google_container_cluster.main.location
}

output "registry" {
  description = "Image path prefix: <registry>/<service>:<tag>"
  value       = "${google_artifact_registry_repository.boutique.location}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.boutique.repository_id}"
}

output "network" {
  value = google_compute_network.main.name
}
