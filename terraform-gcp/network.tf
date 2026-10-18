resource "google_compute_network" "main" {
  name                    = "boutique-gke"
  project                 = var.project_id
  auto_create_subnetworks = false # one subnet, not one per region
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "nodes" {
  name          = "boutique-gke-${var.region}"
  project       = var.project_id
  region        = var.region
  network       = google_compute_network.main.id
  ip_cidr_range = var.subnet_cidr

  # The nodes have no public IP: Google APIs and Artifact Registry are reached privately.
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }
}

# Outbound internet for the private nodes, this subnet only: Docker Hub (redis, busybox).
# No inbound: the shop is reached through the GKE Ingress (a later PR).
resource "google_compute_router" "nat" {
  count = var.cloud_nat ? 1 : 0

  name    = "boutique-gke-nat"
  project = var.project_id
  region  = var.region
  network = google_compute_network.main.id
}

resource "google_compute_router_nat" "nat" {
  count = var.cloud_nat ? 1 : 0

  name                               = "boutique-gke-nat"
  project                            = var.project_id
  region                             = var.region
  router                             = google_compute_router.nat[0].name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.nodes.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# The shop's public address (ADR 0014, decision 6): the GKE Ingress's load balancer uses it
# (frontend.ingress.gce.staticIpName, helm-chart/values-gcp.yaml) and gke.<domain> points at it
# (Route 53, deploy/argocd-gke.sh). Global: an external Application Load Balancer is global.
# A static IP that no forwarding rule uses is billed by the hour: destroy this root between
# uses (infra-gcp removes the Ingress and the DNS record first).
resource "google_compute_global_address" "ingress" {
  name         = "boutique-gke-ingress"
  project      = var.project_id
  address_type = "EXTERNAL"
  ip_version   = "IPV4"
  description  = "terraform-gcp (ADR 0014): GKE Ingress of the shop, gke.<domain>"
}
