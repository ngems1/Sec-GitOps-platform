terraform {
  required_version = ">= 1.10.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.5.0" # same as terraform-gcp-bootstrap
    }
  }

  # The bucket of terraform-gcp-bootstrap, its own prefix (the bootstrap state is "bootstrap").
  # The bucket name holds the project ID: the infra-gcp workflow passes it with
  # -backend-config="bucket=..." (README.md).
  backend "gcs" {
    prefix = "gcp-infra"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region

  default_labels = {
    project    = "week3-boutique"
    env        = "gke"
    managed-by = "terraform-gcp"
  }
}
