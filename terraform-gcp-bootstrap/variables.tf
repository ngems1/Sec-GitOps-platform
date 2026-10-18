variable "project_id" {
  description = "GCP project of the GKE environment (ADR 0014). From the GitHub variable GCP_PROJECT_ID (README.md)."
  type        = string
}

variable "region" {
  description = "Region of the state bucket, and later of the GKE cluster: near the EKS hub in us-east-1 (ADR 0014)."
  type        = string
  default     = "us-east1"
}

variable "github_repo_id" {
  description = "Immutable numeric ID of the GitHub repository (github.repository_id). The federation trusts only this repository, never by name."
  type        = string
  default     = "1416343276" # ngems1/Sec-GitOps-platform

  validation {
    condition     = can(regex("^[0-9]+$", var.github_repo_id))
    error_message = "github_repo_id must be the numeric repository ID."
  }
}

variable "github_owner_id" {
  description = "Immutable numeric ID of the repository owner (github.repository_owner_id)."
  type        = string
  default     = "330211773" # ngems1

  validation {
    condition     = can(regex("^[0-9]+$", var.github_owner_id))
    error_message = "github_owner_id must be the numeric owner ID."
  }
}

variable "github_environments" {
  description = "GitHub environments whose jobs may use the deploy service account (like the AWS deploy role)."
  type        = list(string)
  default     = ["dev", "prod"]
}

variable "bootstrap_environment" {
  description = "The protected GitHub environment whose jobs may use the bootstrap service account (the bootstrap-gcp workflow)."
  type        = string
  default     = "prod"
}

variable "enforce_no_key_policy" {
  description = "Enforce the organization policies on this project (policies.tf): no service account key creation or upload, and no automatic Editor grant to the default service accounts. They need the project to be in a Google Cloud organization: false when it has none (README.md, step 1)."
  type        = bool
  default     = true
}

variable "billing_account_id" {
  description = "Billing account of the project (XXXXXX-XXXXXX-XXXXXX), for the budget. Not a secret, but kept out of the logs."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}$", var.billing_account_id))
    error_message = "billing_account_id must look like 012345-6789AB-CDEF01."
  }
}

variable "monthly_budget_usd" {
  description = "Monthly budget of the whole project in USD; alerts at 50% and 100% of it. No default on purpose: it is a decision (README.md)."
  type        = number

  validation {
    condition     = var.monthly_budget_usd > 0
    error_message = "monthly_budget_usd must be more than 0."
  }
}

variable "grant_bootstrap_billing" {
  description = "Let the bootstrap service account manage this budget on re-runs (Billing Account Costs Manager on the billing account). Needs a billing account administrator on the first run."
  type        = bool
  default     = true
}
