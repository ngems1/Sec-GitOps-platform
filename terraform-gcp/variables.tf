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
