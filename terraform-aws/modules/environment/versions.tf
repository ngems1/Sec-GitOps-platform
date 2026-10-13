terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
    archive = {
      source = "hashicorp/archive"
    }
    random = {
      source = "hashicorp/random"
    }
  }
}

locals {
  # Every permission a pod gets is also limited to pods of THIS namespace.
  # EKS Pod Identity stamps each session with the pod's namespace as a session tag.
  this_namespace_only = {
    StringEquals = { "aws:PrincipalTag/kubernetes-namespace" = var.namespace }
  }
}
