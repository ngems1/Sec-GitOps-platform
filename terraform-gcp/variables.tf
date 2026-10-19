variable "project_id" {
  description = "GCP project of the GKE environment (ADR 0014). From the GitHub variable GCP_PROJECT_ID."
  type        = string
}

variable "region" {
  description = "Region of the network, the cluster and the registry: one region, near the EKS hub in us-east-1."
  type        = string
  default     = "us-east1"
}

variable "node_service_account" {
  description = "Email of the GKE node service account, created by terraform-gcp-bootstrap (output and GitHub variable GCP_GKE_NODE_SA)."
  type        = string

  validation {
    condition     = can(regex("^gke-nodes@[a-z0-9-]+\\.iam\\.gserviceaccount\\.com$", var.node_service_account))
    error_message = "node_service_account must be the bootstrap's gke-nodes service account, never the Compute Engine default one."
  }
}

variable "cluster_name" {
  description = "Name of the GKE Autopilot cluster."
  type        = string
  default     = "boutique-gke"
}

# Not overlapping the EKS VPC (10.0.0.0/16), in case the two networks are ever connected.
variable "subnet_cidr" {
  description = "Primary range of the subnet: the nodes."
  type        = string
  default     = "10.20.0.0/22"
}

variable "pods_cidr" {
  description = "Secondary range of the subnet: the Pods (Autopilot: a /26 per node)."
  type        = string
  default     = "10.24.0.0/17"
}

variable "services_cidr" {
  description = "Secondary range of the subnet: the Services."
  type        = string
  default     = "10.28.0.0/22"
}

variable "control_plane_authorized_cidrs" {
  description = "CIDRs that may reach the cluster's public endpoint (ADR 0014, decision 4: the EKS NAT gateway's egress IPs). Empty: none, until Argo CD is registered."
  type = list(object({
    cidr = string
    name = string
  }))
  default = []
}

variable "cloud_nat" {
  description = "Cloud NAT for the private nodes: redis-cart and the loadgenerator's init container pull from Docker Hub. Off once those images are mirrored to Artifact Registry."
  type        = bool
  default     = true
}

variable "registry_builds_kept" {
  description = "Builds kept per image in Artifact Registry, like the ECR lifecycle rule (terraform-aws/ecr.tf)."
  type        = number
  default     = 20
}

variable "gke_metric_packages" {
  description = "GKE metric packages (monitoring_config.enable_components, gke.tf). SYSTEM_COMPONENTS is free and required on Autopilot; the others are billed per sample ingested (Managed Service for Prometheus pricing, docs/gke-monitoring.md)."
  type        = list(string)
  default     = ["SYSTEM_COMPONENTS", "KUBELET", "CADVISOR"]

  validation {
    condition     = contains(var.gke_metric_packages, "SYSTEM_COMPONENTS")
    error_message = "gke_metric_packages must keep SYSTEM_COMPONENTS: Autopilot can't turn off GKE system metrics."
  }
  validation {
    condition     = alltrue([for p in var.gke_metric_packages : contains(["SYSTEM_COMPONENTS", "APISERVER", "SCHEDULER", "CONTROLLER_MANAGER", "STORAGE", "HPA", "POD", "DAEMONSET", "DEPLOYMENT", "STATEFULSET", "KUBELET", "CADVISOR", "DCGM", "JOBSET"], p)])
    error_message = "gke_metric_packages: unknown package (see the google provider's monitoring_config.enable_components)."
  }
}
