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

  # How Argo CD on EKS reaches the control plane (ADR 0014, decision 4): the DNS-based
  # endpoint, open to any network but only to callers IAM lets connect
  # (container.clusters.connect: argocd-hub's custom role, terraform-gcp-bootstrap/argocd.tf).
  # No IP allow-list to keep in step with the EKS NAT gateway, whose address changes with every
  # terraform-aws rebuild. Google-signed certificate: no cluster CA to hand out. Only IAM
  # credentials: Kubernetes tokens and client certificates are refused on it. The IP-based
  # endpoint above stays closed (no authorized network).
  control_plane_endpoints_config {
    dns_endpoint_config {
      allow_external_traffic    = true
      enable_k8s_tokens_via_dns = false
      enable_k8s_certs_via_dns  = false
    }
  }

  # Monitoring (ADR 0014: Google Cloud Managed Service for Prometheus and Cloud Monitoring, not
  # Prometheus/Grafana as on EKS). See docs/gke-monitoring.md.
  #   - SYSTEM_COMPONENTS: GKE system metrics (container CPU, memory, restarts), free, always on
  #     in Autopilot;
  #   - KUBELET, CADVISOR: GKE's kubelet and cAdvisor packages, billed per sample like any
  #     Prometheus metric (var.gke_metric_packages to turn them off). GKE sets their scrape
  #     interval. No kube-proxy: Dataplane V2 has none;
  #   - managed_prometheus: managed collection (collectors in gke-gmp-system), which scrapes the
  #     PodMonitoring resources of the chart (the frontend's /metrics). It writes with the nodes'
  #     service account (gke-nodes: roles/container.defaultNodeServiceAccount), so no extra
  #     identity or binding. The project is its own Cloud Monitoring scope: no workspace to create.
  monitoring_config {
    enable_components = var.gke_metric_packages

    managed_prometheus {
      enabled = true
    }
  }

  release_channel {
    channel = "REGULAR"
  }

  resource_labels = {
    cluster = var.cluster_name
  }
}
