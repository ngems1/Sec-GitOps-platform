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

output "cluster_dns_endpoint" {
  description = "The control plane's DNS-based endpoint (host name): the server of Argo CD's cluster Secret, https://<this>"
  value       = google_container_cluster.main.control_plane_endpoints_config[0].dns_endpoint_config[0].endpoint
}

output "ingress_ip" {
  description = "The shop's static IP: gke.<domain> points at it (deploy/argocd-gke.sh)"
  value       = google_compute_global_address.ingress.address
}

output "ingress_ip_name" {
  description = "Its name, the GKE Ingress's kubernetes.io/ingress.global-static-ip-name (helm-chart/values.yaml)"
  value       = google_compute_global_address.ingress.name
}
