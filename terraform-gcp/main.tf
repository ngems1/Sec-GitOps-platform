# The destroyable GCP side (ADR 0014), like terraform-aws: destroying it removes the cluster and
# its network, never the way back in (terraform-gcp-bootstrap: federation, state, budget).
#   network.tf   VPC, one subnet in one region, Cloud NAT for the private nodes
#   gke.tf       the GKE Autopilot cluster, nodes as the bootstrap's gke-nodes service account
#   registry.tf  the Artifact Registry repository for the signed images mirrored from ECR
# Applied by gha-deploy through the infra-gcp workflow (manual), planned by gha-plan on pull
# requests. Nothing here creates service accounts or project IAM: the bootstrap does.
#
# Scope: the portable profile only (ADR 0014, decision 1): 10 services, the loadgenerator and an
# in-cluster Redis. No database, queue, assistant or inventoryservice infrastructure.
