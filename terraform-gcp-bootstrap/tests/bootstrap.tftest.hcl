# terraform test (no GCP access: mocked provider). Checks the trust and the rights this root
# grants: run by the bootstrap-gcp workflow before any plan, and runnable on a laptop:
#   cd terraform-gcp-bootstrap && terraform init -backend=false && terraform test

mock_provider "google" {
  mock_data "google_project" {
    override_during = plan
    defaults = {
      number = "123456789012"
    }
  }
  mock_resource "google_iam_workload_identity_pool" {
    override_during = plan
    defaults = {
      name = "projects/123456789012/locations/global/workloadIdentityPools/github-actions"
    }
  }
  mock_resource "google_service_account" {
    override_during = plan
    defaults = {
      name   = "projects/boutique-test-123456/serviceAccounts/gha-mock@boutique-test-123456.iam.gserviceaccount.com"
      member = "serviceAccount:gha-mock@boutique-test-123456.iam.gserviceaccount.com"
    }
  }
}

# The node service account gets its own identity, so a binding on the wrong account shows.
override_resource {
  target          = google_service_account.gke_nodes
  override_during = plan
  values = {
    name   = "projects/boutique-test-123456/serviceAccounts/gke-nodes@boutique-test-123456.iam.gserviceaccount.com"
    email  = "gke-nodes@boutique-test-123456.iam.gserviceaccount.com"
    member = "serviceAccount:gke-nodes@boutique-test-123456.iam.gserviceaccount.com"
  }
}

# Every variable a test depends on is set here: test-file values win over the TF_VAR_*
# environment variables, which the bootstrap-gcp job sets from the real repository variables
# (EKS_OIDC_ISSUER, GCP_ENFORCE_NO_KEY_POLICY...). A run that needs another value sets it.
variables {
  project_id            = "boutique-test-123456"
  billing_account_id    = "012345-6789AB-CDEF01"
  monthly_budget_usd    = 25.5
  enforce_no_key_policy = true
  eks_oidc_issuer       = ""
}

run "trust_is_this_repository_only" {
  command = plan

  assert {
    condition     = google_iam_workload_identity_pool_provider.github.attribute_condition == "assertion.repository_id == '1416343276' && assertion.repository_owner_id == '330211773'"
    error_message = "the provider must admit only this repository and owner, by numeric ID"
  }
  assert {
    condition     = google_iam_workload_identity_pool_provider.github.oidc[0].issuer_uri == "https://token.actions.githubusercontent.com"
    error_message = "the issuer must be GitHub Actions'"
  }
  assert {
    condition     = !strcontains(join(" ", values(google_iam_workload_identity_pool_provider.github.attribute_mapping)), "assertion.environment")
    error_message = "map the environment from sub, not from the optional environment claim (a missing claim fails the mapping)"
  }
}

run "who_may_use_which_service_account" {
  command = plan

  assert {
    condition = toset([for k, b in google_service_account_iam_member.federation : "${split(" ", k)[0]} ${replace(b.member, "principalSet://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/github-actions/", "")}"]) == toset([
      "plan attribute.event_name/pull_request",
      "deploy attribute.ref/refs/heads/main",
      "deploy attribute.environment/dev",
      "deploy attribute.environment/prod",
      "bootstrap attribute.environment/prod",
    ])
    error_message = "plan <- pull_request; deploy <- main, dev, prod; bootstrap <- prod, and nothing else"
  }
  assert {
    condition     = alltrue([for b in google_service_account_iam_member.federation : b.role == "roles/iam.workloadIdentityUser"])
    error_message = "federation bindings must be roles/iam.workloadIdentityUser only"
  }
}

run "no_key_or_impersonation_rights_for_ci" {
  command = plan

  assert {
    condition = length([for k, m in google_project_iam_member.gha : k if !startswith(k, "bootstrap ") && contains([
      "roles/owner", "roles/editor", "roles/iam.serviceAccountUser", "roles/iam.serviceAccountTokenCreator",
      "roles/iam.serviceAccountKeyAdmin", "roles/iam.serviceAccountAdmin", "roles/iam.workloadIdentityPoolAdmin",
      "roles/resourcemanager.projectIamAdmin", "roles/iam.securityAdmin",
    ], m.role)]) == 0
    error_message = "plan and deploy must not get owner/editor, act-as, token-creator, key, pool or project IAM admin roles"
  }
  assert {
    condition     = length([for k, m in google_project_iam_member.gha : k if startswith(k, "plan ") && !contains(["roles/viewer", "roles/iam.securityReviewer"], m.role)]) == 0
    error_message = "plan is read-only"
  }
  assert {
    condition = toset([for k, m in google_project_iam_member.gha : m.role if startswith(k, "deploy ")]) == toset([
      "roles/compute.networkAdmin", "roles/container.admin", "roles/artifactregistry.admin",
      "roles/serviceusage.serviceUsageViewer", "roles/iam.securityReviewer",
    ])
    error_message = "deploy gets exactly what terraform-gcp needs: network, GKE, Artifact Registry admin, read-only service usage and IAM (no firewall admin, no project IAM admin)"
  }
}

run "no_key_policies_and_budget" {
  command = plan

  assert {
    condition     = toset(keys(google_org_policy_policy.no_key_creation)) == toset(["iam.disableServiceAccountKeyCreation", "iam.disableServiceAccountKeyUpload"])
    error_message = "both key policies must be enforced by default"
  }
  assert {
    condition     = length(google_org_policy_policy.no_default_sa_editor) == 1 && endswith(google_org_policy_policy.no_default_sa_editor[0].name, "/policies/iam.automaticIamGrantsForDefaultServiceAccounts") && google_org_policy_policy.no_default_sa_editor[0].spec[0].rules[0].enforce == "TRUE"
    error_message = "the default service accounts get no automatic Editor grant, by default"
  }
  assert {
    condition     = toset(keys(google_project_service.gke_apis)) == toset(["compute.googleapis.com", "container.googleapis.com", "artifactregistry.googleapis.com", "monitoring.googleapis.com"]) && length(setintersection(keys(google_project_service.apis), keys(google_project_service.gke_apis))) == 0
    error_message = "Compute Engine, GKE, Artifact Registry and Monitoring are enabled only through gke_apis (after the Editor policy)"
  }
  assert {
    condition     = [for t in google_billing_budget.project.threshold_rules : t.threshold_percent] == [0.5, 1.0]
    error_message = "alerts at 50% and 100%"
  }
  assert {
    condition     = google_billing_budget.project.amount[0].specified_amount[0].units == "25" && google_billing_budget.project.amount[0].specified_amount[0].nanos == 500000000
    error_message = "the budget amount comes from monthly_budget_usd"
  }
  assert {
    condition     = google_storage_bucket.state.public_access_prevention == "enforced" && google_storage_bucket.state.uniform_bucket_level_access && google_storage_bucket.state.versioning[0].enabled
    error_message = "the state bucket must be private, IAM-only and versioned"
  }
}

run "project_without_organization" {
  command = plan
  variables {
    enforce_no_key_policy = false
  }

  assert {
    condition     = length(google_org_policy_policy.no_key_creation) == 0 && length(google_org_policy_policy.no_default_sa_editor) == 0 && !contains(keys(google_project_service.apis), "orgpolicy.googleapis.com")
    error_message = "without an organization: no org policy and no orgpolicy API"
  }
}

run "gke_nodes_least_privilege" {
  command = plan

  assert {
    condition     = toset([for m in google_project_iam_member.gke_nodes : m.role]) == toset(["roles/container.defaultNodeServiceAccount"])
    error_message = "the GKE node service account gets exactly GKE's default node role on the project (image pulls: on the repository, terraform-gcp)"
  }
  assert {
    condition     = google_service_account.gke_nodes.account_id == "gke-nodes"
    error_message = "a dedicated node service account, not the Compute Engine default one"
  }
  assert {
    condition     = google_service_account_iam_member.deploy_uses_gke_nodes.role == "roles/iam.serviceAccountUser" && google_service_account_iam_member.deploy_uses_gke_nodes.service_account_id == google_service_account.gke_nodes.name
    error_message = "gha-deploy may act as the node service account only, on that account (never project-wide)"
  }
  assert {
    condition     = alltrue([for k in keys(google_service_account_iam_member.federation) : contains(["plan", "deploy", "bootstrap"], split(" ", k)[0])])
    error_message = "GitHub can never sign in as the node service account"
  }
}

# Argo CD's federation (argocd.tf): own pool, own identity, distinct names so a binding on the
# wrong pool or account shows.
override_resource {
  target          = google_iam_workload_identity_pool.eks_argocd
  override_during = plan
  values = {
    name = "projects/123456789012/locations/global/workloadIdentityPools/eks-argocd"
  }
}

override_resource {
  target          = google_service_account.argocd_hub
  override_during = plan
  values = {
    name   = "projects/boutique-test-123456/serviceAccounts/argocd-hub@boutique-test-123456.iam.gserviceaccount.com"
    email  = "argocd-hub@boutique-test-123456.iam.gserviceaccount.com"
    member = "serviceAccount:argocd-hub@boutique-test-123456.iam.gserviceaccount.com"
  }
}

override_resource {
  target          = google_project_iam_custom_role.gke_connect
  override_during = plan
  values = {
    name = "projects/boutique-test-123456/roles/gkeConnectOnly"
  }
}

run "no_argocd_federation_without_an_issuer" {
  command = plan

  assert {
    condition     = length(google_iam_workload_identity_pool.eks_argocd) == 0 && length(google_service_account.argocd_hub) == 0 && length(google_service_account_iam_member.argocd_federation) == 0 && output.GCP_ARGOCD_SA == null
    error_message = "EKS_OIDC_ISSUER empty: no pool, no argocd-hub, no binding"
  }
}

run "argocd_only_from_its_two_service_accounts" {
  command = plan
  variables {
    eks_oidc_issuer = "https://oidc.eks.us-east-1.amazonaws.com/id/0123456789ABCDEF0123456789ABCDEF"
  }

  assert {
    condition     = google_iam_workload_identity_pool_provider.eks_argocd[0].oidc[0].issuer_uri == "https://oidc.eks.us-east-1.amazonaws.com/id/0123456789ABCDEF0123456789ABCDEF" && google_iam_workload_identity_pool_provider.eks_argocd[0].oidc[0].allowed_audiences[0] == "eks-argocd" && length(google_iam_workload_identity_pool_provider.eks_argocd[0].oidc[0].allowed_audiences) == 1
    error_message = "the provider trusts the EKS issuer, for tokens with the eks-argocd audience only"
  }
  assert {
    condition     = google_iam_workload_identity_pool_provider.eks_argocd[0].attribute_condition == "assertion.sub in ['system:serviceaccount:argocd:argocd-application-controller', 'system:serviceaccount:argocd:argocd-server']"
    error_message = "only Argo CD's controller and server may exchange a token, no other workload of the cluster"
  }
  assert {
    condition     = toset(keys(google_iam_workload_identity_pool_provider.eks_argocd[0].attribute_mapping)) == toset(["google.subject", "attribute.namespace", "attribute.service_account"])
    error_message = "Kubernetes attributes only: no GitHub attribute names (event_name, ref, environment, repository_id)"
  }
  assert {
    condition     = google_iam_workload_identity_pool_provider.eks_argocd[0].workload_identity_pool_id != google_iam_workload_identity_pool.github.workload_identity_pool_id
    error_message = "a pool of its own, not the GitHub pool"
  }
  assert {
    condition = toset([for b in google_service_account_iam_member.argocd_federation : b.member]) == toset([
      "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/eks-argocd/subject/system:serviceaccount:argocd:argocd-application-controller",
      "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/eks-argocd/subject/system:serviceaccount:argocd:argocd-server",
    ]) && alltrue([for b in google_service_account_iam_member.argocd_federation : b.role == "roles/iam.workloadIdentityUser" && b.service_account_id == google_service_account.argocd_hub[0].name])
    error_message = "the two subjects, by exact principal, may act as argocd-hub only"
  }
  assert {
    condition     = toset(google_project_iam_custom_role.gke_connect[0].permissions) == toset(["container.clusters.connect", "container.clusters.get"]) && google_project_iam_member.argocd_hub[0].role == google_project_iam_custom_role.gke_connect[0].name && google_project_iam_member.argocd_hub[0].member == google_service_account.argocd_hub[0].member
    error_message = "argocd-hub gets exactly get + connect on the clusters (custom role), nothing through IAM beyond that"
  }
}

run "argocd_issuer_must_be_eks" {
  command = plan
  variables {
    eks_oidc_issuer = "https://token.actions.githubusercontent.com"
  }
  expect_failures = [var.eks_oidc_issuer]
}
