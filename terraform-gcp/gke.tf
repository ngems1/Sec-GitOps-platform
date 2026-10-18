# GKE Autopilot (ADR 0014, decision 7): billed per Pod request, no nodes to size or patch.
# Autopilot turns on Workload Identity, Shielded nodes and Dataplane V2 (the chart's
# NetworkPolicies) itself. Autopilot clusters are regional: there is no zonal option.
resource "google_container_cluster" "main" {
  name     = var.cluster_name
  project  = var.project_id
  location = var.region

  enable_autopilot = true

  # Destroyable on purpose (terraform destroy from the infra-gcp workflow).
  deletion_protection = false

  network    = google_compute_network.main.id
  subnetwork = google_compute_subnetwork.nodes.id

  ip_allocation_policy {
    cluster_secondary_range_name  = google_compute_subnetwork.nodes.secondary_ip_range[0].range_name
    services_secondary_range_name = google_compute_subnetwork.nodes.secondary_ip_range[1].range_name
  }

  # The nodes run as the bootstrap's gke-nodes service account, never the Compute Engine
  # default one (editor). gha-deploy may act as that one account only (terraform-gcp-bootstrap).
  cluster_autoscaling {
    auto_provisioning_defaults {
      service_account = var.node_service_account
      oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"] # IAM decides, not scopes
    }
  }

  # Private nodes (no public IP), public control plane endpoint limited to the authorized
  # networks (ADR 0014, decision 4). Google Cloud's own public IPs are not let in either.
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
  }

  master_authorized_networks_config {
    gcp_public_cidrs_access_enabled = false

    dynamic "cidr_blocks" {
      for_each = var.control_plane_authorized_cidrs
      content {
        cidr_block   = cidr_blocks.value.cidr
        display_name = cidr_blocks.value.name
      }
    }
  }

  release_channel {
    channel = "REGULAR"
  }

  resource_labels = {
    cluster = var.cluster_name
  }
}
