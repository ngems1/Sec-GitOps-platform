# Argo CD on EKS reaches GKE without a static credential (ADR 0014, decision 4):
#   1. its pods get a projected Kubernetes service account token (audience below), signed by the
#      EKS cluster's OIDC issuer;
#   2. this pool's provider trusts that issuer, and only Argo CD's controller and server;
#   3. they exchange the token (STS) and impersonate argocd-hub for 1-hour tokens;
#   4. argocd-hub may only get and connect to the clusters of the project (custom role below):
#      it reads no Kubernetes object through IAM. Inside GKE, RBAC alone gives it access
#      (terraform-gcp's cluster, namespace by namespace: deploy/argocd/gke/).
#
# A pool of its own: nothing here shares attribute names or bindings with the GitHub pool.
# The issuer changes with every EKS rebuild: update EKS_OIDC_ISSUER and re-run bootstrap-gcp
# (README.md); the argocd-gke workflow stops with an error until both match.

locals {
  argocd        = var.eks_oidc_issuer != ""
  argocd_subs   = [for sa in var.argocd_service_accounts : "system:serviceaccount:${replace(sa, "/", ":")}"]
  argocd_tokens = "eks-argocd" # the audience of Argo CD's projected token (deploy/argocd/values.yaml)
}

resource "google_iam_workload_identity_pool" "eks_argocd" {
  count = local.argocd ? 1 : 0

  project                   = var.project_id
  workload_identity_pool_id = "eks-argocd"
  display_name              = "Argo CD on EKS"
  description               = "Argo CD's Kubernetes service accounts on the EKS hub only (terraform-gcp-bootstrap, ADR 0014)"

  depends_on = [google_project_service.apis]
}

resource "google_iam_workload_identity_pool_provider" "eks_argocd" {
  count = local.argocd ? 1 : 0

  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.eks_argocd[0].workload_identity_pool_id
  workload_identity_pool_provider_id = "eks-hub"
  display_name                       = "EKS hub cluster"

  oidc {
    issuer_uri        = var.eks_oidc_issuer
    allowed_audiences = [local.argocd_tokens]
  }

  # A Kubernetes token's sub is system:serviceaccount:<namespace>:<name>.
  attribute_mapping = {
    "google.subject"            = "assertion.sub"
    "attribute.namespace"       = "assertion['kubernetes.io']['namespace']"
    "attribute.service_account" = "assertion['kubernetes.io']['serviceaccount']['name']"
  }

  # The trust boundary: any other workload of the cluster is refused at the exchange.
  attribute_condition = "assertion.sub in [${join(", ", formatlist("'%s'", local.argocd_subs))}]"
}

resource "google_service_account" "argocd_hub" {
  count = local.argocd ? 1 : 0

  project      = var.project_id
  account_id   = "argocd-hub"
  display_name = "Argo CD on EKS (GKE target cluster)"
  description  = "terraform-gcp-bootstrap (ADR 0014): Argo CD's controller and server on EKS, through the eks-argocd pool. Get and connect to GKE only; Kubernetes RBAC decides the rest. No keys."
}

# Argo CD's two Kubernetes service accounts, by exact subject, may act as argocd-hub.
resource "google_service_account_iam_member" "argocd_federation" {
  for_each = local.argocd ? toset(local.argocd_subs) : toset([])

  service_account_id = google_service_account.argocd_hub[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/${google_iam_workload_identity_pool.eks_argocd[0].name}/subject/${each.value}"
}

# Exactly what Argo CD needs from IAM: find the cluster and reach its DNS-based endpoint
# (terraform-gcp/gke.tf). Not roles/container.viewer, which reads every Kubernetes object of
# every cluster in the project through IAM.
resource "google_project_iam_custom_role" "gke_connect" {
  count = local.argocd ? 1 : 0

  project     = var.project_id
  role_id     = "gkeConnectOnly"
  title       = "GKE connect only"
  description = "terraform-gcp-bootstrap (ADR 0014): get a cluster and connect to its DNS-based endpoint. Kubernetes access comes from RBAC only."
  permissions = ["container.clusters.connect", "container.clusters.get"]
}

resource "google_project_iam_member" "argocd_hub" {
  count = local.argocd ? 1 : 0

  project = var.project_id
  role    = google_project_iam_custom_role.gke_connect[0].name
  member  = google_service_account.argocd_hub[0].member
}
