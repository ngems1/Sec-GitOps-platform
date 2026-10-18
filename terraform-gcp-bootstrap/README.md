# terraform-gcp-bootstrap

What GitHub Actions needs before it can run `terraform-gcp`, and what must outlive a
`terraform-gcp` destroy (ADR 0014). The GCP twin of `terraform-bootstrap`.

| Resource | Why |
|---|---|
| APIs | IAM, IAM Credentials, STS, Cloud Resource Manager, Service Usage, Cloud Storage, Cloud Billing, Billing Budgets, Org Policy (`main.tf`) |
| GCS bucket `<project>-tfstate` | Every GCP Terraform state: `bootstrap/` (this root), `gcp/` (terraform-gcp). Versioned, IAM only, public access prevented, protected against `destroy` |
| Workload identity pool `github-actions`, provider `sec-gitops-platform` | GitHub Actions sign in without a key. Only this repository, by its numeric IDs (`federation.tf`) |
| `gha-plan` | Read-only (`roles/viewer`, `roles/iam.securityReviewer`), pull requests |
| `gha-deploy` | terraform-gcp and deploys, from `main` or the `dev` / `prod` environments: network, firewall, GKE, Artifact Registry admin, and project IAM limited to an allow-list (`deploy_grantable_roles`). Not editor or owner |
| `gha-bootstrap` | Owner, only for jobs in the protected `prod` environment: the bootstrap-gcp workflow |
| Org policies | No service account key can be created or uploaded (`policies.tf`), when the project is in an organization |
| Budget | Monthly, on this project, email at 50% and 100% to the billing account's admins and users (`budgets.tf`) |

**No key exists anywhere.** GitHub gets 1-hour tokens through federation.

## Who can use which service account

| GitHub context | Service account |
|---|---|
| A job of a `pull_request` event | `gha-plan` |
| A job on `refs/heads/main` (push, manual run on main) | `gha-deploy` |
| A job in the `dev` or `prod` environment | `gha-deploy` |
| A job in the `prod` environment | `gha-bootstrap` (and `gha-deploy`) |

All of them only if the token's `repository_id` is `1416343276` and its `repository_owner_id`
is `330211773` (this repository). Same model as the AWS roles (`terraform-bootstrap/main.tf`).

## First run: by the project owner, once

The workflow can't do it: it signs in through the federation this creates. You need **Owner** on
the project and **Billing Account Administrator** on its billing account; `gcloud` and Terraform
1.12.2 on a laptop.

1. **Check the project, its billing and its organization:**

   ```bash
   P=<project-id>
   gcloud config set project "$P"
   gcloud billing projects describe "$P" --format='value(billingEnabled,billingAccountName)'
   gcloud projects get-ancestors "$P"
   ```

   - The first command must say `True` and `billingAccounts/XXXXXX-XXXXXX-XXXXXX`: keep that ID.
   - The second lists an `organization` line, or not. Without one, the key policies can't exist:
     use `-var enforce_no_key_policy=false` below, and set `GCP_ENFORCE_NO_KEY_POLICY=false` in
     step 5. Keys are then kept out by IAM only, and the workflow fails if one appears.
2. **Sign in and enable the two APIs Terraform needs to enable the others:**

   ```bash
   gcloud auth application-default login
   gcloud auth application-default set-quota-project "$P"
   gcloud services enable serviceusage.googleapis.com cloudresourcemanager.googleapis.com
   ```

3. **Apply, with local state:**

   ```bash
   cd terraform-gcp-bootstrap
   terraform init
   terraform apply -var "project_id=$P" \
     -var "billing_account_id=XXXXXX-XXXXXX-XXXXXX" -var "monthly_budget_usd=<amount>"
   ```

   - The plan creates the APIs, the bucket, the pool and provider, 3 service accounts, their
     bindings, the two org policies and the budget.
   - An `orgpolicy` permission error means no organization, or no Organization Policy
     Administrator role: see step 1.
   - **Org policy changes need that role.** Organization policies need Organization Policy
     Administrator (`roles/orgpolicy.policyAdmin`), which is granted on the organization, not
     the project. A project owner may need an organization admin for this one step.
     `gha-bootstrap` (owner) can read the policies on re-runs, not change them: a later change
     to `policies.tf` is applied by hand the same way.
4. **Move the state into the bucket:**

   ```bash
   cat > ci_backend.tf <<EOF
   terraform {
     backend "gcs" {
       bucket = "$P-tfstate"
       prefix = "bootstrap"
     }
   }
   EOF
   terraform init -migrate-state -force-copy
   rm -f terraform.tfstate terraform.tfstate.backup   # now in the bucket
   ```

   `ci_backend.tf` is git-ignored.
5. **GitHub settings.** Read the values with `terraform output` (don't paste them into issues or
   logs).
   - Repository variables: `GCP_PROJECT_ID`, `GCP_REGION`, `GCP_WIF_PROVIDER`, `GCP_PLAN_SA`,
     `GCP_DEPLOY_SA`, `GCP_TF_STATE_BUCKET`, `GCP_MONTHLY_BUDGET_USD` (the amount of step 3),
     and `GCP_ENFORCE_NO_KEY_POLICY` (only when `false`).
   - `prod` environment variable: `GCP_BOOTSTRAP_SA`.
   - Repository secret: `GCP_BILLING_ACCOUNT_ID`. Not a credential, but a secret keeps it masked
     in the public logs.
6. **Check the workflow:** Actions > **bootstrap-gcp** > Run workflow, **apply unchecked**.
   Approve the prod run. The plan must say "No changes", and "No service account keys" must
   show 0 for each account.

## Re-running after a change here

After a merge that changes `terraform-gcp-bootstrap/`: **bootstrap-gcp** with apply unchecked,
read which resources change, then again with apply checked.

- **What the workflow prints:** it runs `terraform test` first (the trust and the rights, with a
  mocked provider). It prints only which resources change, never values or outputs: the logs
  are public.
- **On a laptop:** `terraform init -backend=false && terraform test` runs the same checks
  without any GCP access.

## Removing it

The bucket is protected by `prevent_destroy`. Destroy `terraform-gcp` first, then remove the
`prevent_destroy` block and run `terraform destroy` here, as the project owner.
