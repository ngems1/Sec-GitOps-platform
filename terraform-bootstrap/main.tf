# One-time bootstrap: what GitHub Actions needs BEFORE it can run terraform-aws.
#   1. an S3 bucket for Terraform state (private, encrypted, versioned, HTTPS only)
#   2. the GitHub OIDC identity provider (optional: usually created by hand, see docs/week3/BOOTSTRAP.md)
#   3. two roles with different rights (least privilege), each with a permission boundary:
#        week3-gha-plan    read-only, for pull-request plans (any branch)
#        week3-gha-deploy  apply + deploy, only from main or the dev/prod environments
#   4.-7. this project's audit baseline (security.tf): its CloudTrail trail, KMS key, Object Lock
#        bucket and AWS Config rules (GuardDuty, the Config recorder and Security Hub are shared)
#   budgets.tf: the Bedrock daily budget (AI shopping assistant) and its alert topic
# Normally run by .github/workflows/bootstrap.yml.

data "aws_caller_identity" "current" {}

locals {
  bucket_name = var.state_bucket_name != "" ? var.state_bucket_name : "week3-tfstate-${data.aws_caller_identity.current.account_id}"
  oidc_url    = "token.actions.githubusercontent.com"
  oidc_arn    = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${local.oidc_url}"

  # GitHub's "sub" claim starts with the repository. Repos created after 15 July 2026
  # use immutable IDs (repo:owner@123/name@456): when the IDs are given, only that
  # form is trusted, so a deleted-and-recreated repo with the same name gets nothing.
  use_ids = var.github_owner_id != "" && var.github_repo_id != ""
  repos   = [local.use_ids ? "repo:${var.github_owner}@${var.github_owner_id}/${var.github_repo}@${var.github_repo_id}" : "repo:${var.github_owner}/${var.github_repo}"]
}

# ---------------------------------------------------------------------------
# 1. Terraform state bucket
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "state" {
  bucket = local.bucket_name

  # Losing the state file means Terraform forgets everything it created.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Refuse any request that is not over HTTPS.
resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.state]
}

# ---------------------------------------------------------------------------
# 2. GitHub OIDC identity provider (only when not created by hand)
# ---------------------------------------------------------------------------
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url             = "https://${local.oidc_url}"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"] # AWS no longer checks it for GitHub, but the field must be set
}

# ---------------------------------------------------------------------------
# 3a. Plan role: read-only, for pull requests
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "plan_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url}:sub"
      values   = [for r in local.repos : "${r}:pull_request"]
    }
  }
}

resource "aws_iam_role" "plan" {
  name                 = var.plan_role_name
  description          = "GitHub Actions: read-only terraform plan on pull requests"
  assume_role_policy   = data.aws_iam_policy_document.plan_trust.json
  permissions_boundary = aws_iam_policy.plan_boundary.arn # boundaries.tf
  max_session_duration = 7200
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# A plan still has to take the state lock, i.e. write the .tflock object.
resource "aws_iam_role_policy" "plan_state" {
  name = "terraform-state-lock"
  role = aws_iam_role.plan.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.state.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.state.arn}/*"
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# 3b. Deploy role: apply + deploy, only from main or a protected environment
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "deploy_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url}:sub"
      values = flatten([for r in local.repos : concat(
        ["${r}:ref:refs/heads/main"],
        [for env in var.github_environments : "${r}:environment:${env}"],
      )])
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = var.deploy_role_name
  description          = "GitHub Actions: terraform apply and deployments (main branch, dev/prod environments)"
  assume_role_policy   = data.aws_iam_policy_document.deploy_trust.json
  permissions_boundary = aws_iam_policy.deploy_boundary.arn # boundaries.tf
  max_session_duration = 7200 # the workflows ask for 2-hour credentials
}

resource "aws_iam_role_policy_attachment" "deploy" {
  role       = aws_iam_role.deploy.name
  policy_arn = var.deploy_policy_arn
}
