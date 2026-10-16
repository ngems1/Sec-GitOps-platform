variable "region" {
  description = "AWS region for the state bucket (use the same region as terraform-aws)."
  type        = string
  default     = "us-east-1"
}

variable "github_owner" {
  description = "GitHub user or organization that owns the repo (the bootstrap workflow fills this in)."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name (the bootstrap workflow fills this in)."
  type        = string
}

variable "github_owner_id" {
  description = "Numeric ID of the GitHub owner (github.repository_owner_id). Needed for repos that use immutable OIDC subjects."
  type        = string
  default     = ""
}

variable "github_repo_id" {
  description = "Numeric ID of the GitHub repository (github.repository_id)."
  type        = string
  default     = ""
}

variable "state_bucket_name" {
  description = "Name of the Terraform state bucket. Empty = week3-tfstate-<account-id>."
  type        = string
  default     = ""
}

variable "create_oidc_provider" {
  description = "Create the GitHub OIDC provider. False when it already exists (the bootstrap workflow signs in through it, so it passes false)."
  type        = bool
  default     = true
}

variable "plan_role_name" {
  description = "Read-only role used by pull-request plans."
  type        = string
  default     = "week3-gha-plan"
}

variable "deploy_role_name" {
  description = "Role used to apply Terraform and deploy, from main and the dev/prod environments only."
  type        = string
  default     = "week3-gha-deploy"
}

variable "deploy_policy_arn" {
  description = "Permissions of the deploy role. Terraform creates IAM roles, VPCs, EKS, so it needs broad rights; narrowing it is a security remediation item."
  type        = string
  default     = "arn:aws:iam::aws:policy/AdministratorAccess"
}

variable "github_environments" {
  description = "GitHub environments whose jobs may use the deploy role."
  type        = list(string)
  default     = ["dev", "prod"]
}

variable "project" {
  description = "Value of the Project tag on everything terraform-aws creates (its var.project). The deploy role's permission boundary only lets it change resources with this tag, or with no Project tag."
  type        = string
  default     = "week3-boutique"
}

variable "bootstrap_role_name" {
  description = "Name of the hand-made bootstrap role (docs/week3/BOOTSTRAP.md). The plan and deploy roles may not change it."
  type        = string
  default     = "week3-bootstrap"
}

variable "audit_retention_days" {
  description = "S3 Object Lock retention (GOVERNANCE mode) of the CloudTrail and AWS Config files: nobody without s3:BypassGovernanceRetention can delete or overwrite them before this."
  type        = number
  default     = 30
}

variable "audit_expiry_days" {
  description = "Lifecycle: CloudTrail and AWS Config files are deleted after this many days."
  type        = number
  default     = 90
}

variable "bedrock_daily_budget_usd" {
  description = "Daily Amazon Bedrock cost (USD) of the AI shopping assistant; alerts at 50% and 100% (ADR 0009). Nova Lite costs about USD 0.0004 per question."
  type        = string
  default     = "1"
}
