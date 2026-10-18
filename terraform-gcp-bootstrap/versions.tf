terraform {
  required_version = ">= 1.10.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.5.0" # 8.5.x: the newest minor at least two weeks old (2026-09-29)
    }
  }

  # No backend here on purpose, like terraform-bootstrap: the first run (by the project owner,
  # README.md) starts with local state, then moves it into the bucket it creates. The workflow
  # writes the backend (ci_backend.tf) itself.
}

provider "google" {
  project = var.project_id
  region  = var.region

  # Budgets and some IAM APIs bill the caller's quota project: use this one, also when the first
  # run uses a person's own credentials.
  user_project_override = true
  billing_project       = var.project_id

  default_labels = {
    project    = "week3-boutique"
    managed-by = "terraform-gcp-bootstrap"
  }
}
