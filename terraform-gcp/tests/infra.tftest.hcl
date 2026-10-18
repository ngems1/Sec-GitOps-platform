# terraform test (no GCP access: mocked provider). Checks what this root builds: run by the
# infra-gcp workflow before any plan, and runnable on a laptop:
#   cd terraform-gcp && terraform init -backend=false && terraform test

mock_provider "google" {
  mock_resource "google_compute_network" {
    override_during = plan
    defaults = {
      id = "projects/boutique-test-123456/global/networks/boutique-gke"
    }
  }
  mock_resource "google_compute_subnetwork" {
    override_during = plan
    defaults = {
      id = "projects/boutique-test-123456/regions/us-east1/subnetworks/boutique-gke-us-east1"
    }
  }
  mock_resource "google_artifact_registry_repository" {
    override_during = plan
    defaults = {
      name = "boutique"
    }
  }
}

variables {
  project_id           = "boutique-test-123456"
  node_service_account = "gke-nodes@boutique-test-123456.iam.gserviceaccount.com"
}

run "autopilot_with_the_bootstrap_node_account" {
  command = plan

  assert {
    condition     = google_container_cluster.main.enable_autopilot && google_container_cluster.main.location == "us-east1"
    error_message = "one Autopilot cluster, in us-east1"
  }
  assert {
    condition     = google_container_cluster.main.cluster_autoscaling[0].auto_provisioning_defaults[0].service_account == "gke-nodes@boutique-test-123456.iam.gserviceaccount.com"
    error_message = "the nodes run as the bootstrap's gke-nodes service account"
  }
  assert {
    condition     = !google_container_cluster.main.deletion_protection
    error_message = "this root is destroyable: no deletion protection"
  }
  assert {
    condition     = google_container_cluster.main.release_channel[0].channel == "REGULAR"
    error_message = "the cluster follows the REGULAR release channel"
  }
}

run "private_nodes_closed_control_plane" {
  command = plan

  assert {
    condition     = google_container_cluster.main.private_cluster_config[0].enable_private_nodes
    error_message = "nodes have no public IP"
  }
  assert {
    condition     = length(google_container_cluster.main.master_authorized_networks_config[0].cidr_blocks) == 0 && !google_container_cluster.main.master_authorized_networks_config[0].gcp_public_cidrs_access_enabled
    error_message = "by default nobody reaches the control plane (no CIDR, not Google Cloud's public IPs)"
  }
  assert {
    condition     = google_compute_subnetwork.nodes.private_ip_google_access && google_compute_subnetwork.nodes.region == "us-east1"
    error_message = "one subnet in us-east1, Private Google Access on (Artifact Registry without NAT)"
  }
  assert {
    condition     = !google_compute_network.main.auto_create_subnetworks
    error_message = "no auto-created subnets in every region"
  }
  assert {
    condition     = google_compute_router_nat.nat[0].source_subnetwork_ip_ranges_to_nat == "LIST_OF_SUBNETWORKS" && length(google_compute_router_nat.nat[0].subnetwork) == 1
    error_message = "Cloud NAT serves this subnet only"
  }
}

run "authorized_networks_and_no_nat" {
  command = plan
  variables {
    cloud_nat                      = false
    control_plane_authorized_cidrs = [{ cidr = "203.0.113.10/32", name = "eks-nat-a" }]
  }

  assert {
    condition     = length(google_compute_router_nat.nat) == 0 && length(google_compute_router.nat) == 0
    error_message = "cloud_nat = false: no router, no NAT"
  }
  assert {
    condition     = [for b in google_container_cluster.main.master_authorized_networks_config[0].cidr_blocks : b.cidr_block] == ["203.0.113.10/32"]
    error_message = "only the listed CIDRs reach the control plane"
  }
}

run "registry_like_ecr" {
  command = plan

  assert {
    condition     = google_artifact_registry_repository.boutique.format == "DOCKER" && google_artifact_registry_repository.boutique.docker_config[0].immutable_tags
    error_message = "a Docker repository with immutable tags, like ECR"
  }
  assert {
    condition     = one([for p in google_artifact_registry_repository.boutique.cleanup_policies : p.most_recent_versions[0].keep_count if p.action == "KEEP"]) == 60 && !google_artifact_registry_repository.boutique.cleanup_policy_dry_run
    error_message = "keep the last 20 builds (image, .sig, .att: 60 versions), like the ECR rule, for real (no dry run)"
  }
}

run "never_the_compute_default_account" {
  command = plan
  variables {
    node_service_account = "123456789012-compute@developer.gserviceaccount.com"
  }
  expect_failures = [var.node_service_account]
}

run "nodes_read_the_boutique_repository_only" {
  command = plan

  assert {
    condition     = google_artifact_registry_repository_iam_member.nodes_pull.role == "roles/artifactregistry.reader" && google_artifact_registry_repository_iam_member.nodes_pull.member == "serviceAccount:gke-nodes@boutique-test-123456.iam.gserviceaccount.com"
    error_message = "the node service account reads images, nothing more"
  }
  assert {
    condition     = google_artifact_registry_repository_iam_member.nodes_pull.repository == google_artifact_registry_repository.boutique.name && google_artifact_registry_repository_iam_member.nodes_pull.location == "us-east1"
    error_message = "on the boutique repository only"
  }
}

run "dns_endpoint_iam_only" {
  command = plan

  assert {
    condition     = google_container_cluster.main.control_plane_endpoints_config[0].dns_endpoint_config[0].allow_external_traffic
    error_message = "the DNS-based endpoint is reachable from EKS (IAM decides who connects)"
  }
  assert {
    condition     = !google_container_cluster.main.control_plane_endpoints_config[0].dns_endpoint_config[0].enable_k8s_tokens_via_dns && !google_container_cluster.main.control_plane_endpoints_config[0].dns_endpoint_config[0].enable_k8s_certs_via_dns
    error_message = "IAM credentials only on the DNS endpoint: no Kubernetes tokens or client certificates"
  }
}
