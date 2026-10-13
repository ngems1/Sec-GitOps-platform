# Argo CD (deploy/argocd.sh) reads this repository with a read-only GitHub deploy key.
# Terraform creates the empty secret, encrypted with the dev KMS key. The private key is
# stored by hand once (docs/week3/ARGOCD.md), so it is never in Git, in GitHub secrets
# or in the Terraform state. The argocd-install workflow copies it into the cluster.

resource "aws_secretsmanager_secret" "argocd_repo_key" {
  name        = "${var.project}/argocd-repo-deploy-key"
  description = "Private half of the read-only GitHub deploy key Argo CD uses to read the repository. Value stored by hand."
  kms_key_id  = module.env["dev"].kms_key_arn

  # Deleted at once on destroy, so the next apply can recreate the same name.
  recovery_window_in_days = 0
}
