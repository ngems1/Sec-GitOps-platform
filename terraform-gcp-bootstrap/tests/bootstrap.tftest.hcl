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

variables {
  project_id         = "boutique-test-123456"
  billing_account_id = "012345-6789AB-CDEF01"
  monthly_budget_usd = 25.5
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
    ], m.role)]) == 0
    error_message = "plan and deploy must not get owner/editor, act-as, token-creator, key or pool admin roles"
  }
  assert {
    condition     = length([for k, m in google_project_iam_member.gha : k if startswith(k, "plan ") && !contains(["roles/viewer", "roles/iam.securityReviewer"], m.role)]) == 0
    error_message = "plan is read-only"
  }
  assert {
    condition     = strcontains(google_project_iam_member.deploy_grants.condition[0].expression, "modifiedGrantsByRole") && !strcontains(google_project_iam_member.deploy_grants.condition[0].expression, "roles/owner")
    error_message = "deploy's project IAM admin must be limited to an allow-list"
  }
}

run "no_key_policies_and_budget" {
  command = plan

  assert {
    condition     = toset(keys(google_org_policy_policy.no_key_creation)) == toset(["iam.disableServiceAccountKeyCreation", "iam.disableServiceAccountKeyUpload"])
    error_message = "both key policies must be enforced by default"
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
    condition     = length(google_org_policy_policy.no_key_creation) == 0 && !contains(keys(google_project_service.apis), "orgpolicy.googleapis.com")
    error_message = "without an organization: no org policy and no orgpolicy API"
  }
}

run "gke_nodes_least_privilege" {
  command = plan

  assert {
    condition = toset([for m in google_project_iam_member.gke_nodes : m.role]) == toset([
      "roles/container.defaultNodeServiceAccount", "roles/artifactregistry.reader",
    ])
    error_message = "the GKE node service account gets exactly: GKE's default node role, Artifact Registry reader"
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
