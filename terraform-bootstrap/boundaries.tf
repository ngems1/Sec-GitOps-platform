# Permission boundaries of the GitHub Actions roles (DESIGN D-07, ADR 0003). A boundary is
# a ceiling: a role can only do what both its own policies and its boundary allow, so even
# AdministratorAccess on the deploy role stops at this list.
#
# The lists come from what the workflows actually call (checked 2026-10-15):
#   terraform-aws (infra: plan on pull requests, apply/destroy on main): acm, cloudwatch,
#     dynamodb, ec2, ecr, eks, elasticache, events, iam, kms, lambda, logs, rds, route53,
#     secretsmanager, ses (SES v2), sns, sqs, sts, plus the Terraform state in S3.
#   AWS CLI in the workflows and deploy/*.sh (deploy role): s3 cp (state), eks
#     update-kubeconfig/describe-cluster/list-addons/describe-addon, ecr (push, scan
#     results), secretsmanager get/put-secret-value, route53 records, elbv2
#     describe-load-balancers, cloudwatch get-metric-data, dynamodb scan/update-item,
#     logs tail, sesv2 get-account/get-email-identity, sqs get-queue-attributes.
#   Workflows: infra, deploy, deploy-env, cluster-status, eks-openapi-fix, argocd-install,
#     catalog, chaos, isolation-test, load-test, order-flow. (bootstrap uses its own role.)
# A new AWS service in terraform-aws (X-Ray on Day 5, for example) needs a line here and a
# bootstrap run first: otherwise its apply fails with "explicit deny in a permissions
# boundary" (RUNBOOK section 1).

locals {
  # Services the deploy role may use fully (subject to the denies below).
  deploy_services = [
    "acm", "cloudwatch", "dynamodb", "ec2", "ecr", "eks", "elasticache", "events", "iam",
    "kms", "lambda", "logs", "rds", "route53", "secretsmanager", "ses", "sns", "sqs",
  ]

  # Services that support aws:ResourceTag on their resources (used by the tag conditions).
  tagged_services = [
    "cloudwatch", "dynamodb", "ec2", "ecr", "eks", "elasticache", "events", "iam", "kms",
    "lambda", "logs", "rds", "secretsmanager", "sns", "sqs",
  ]

  # Read-only actions a Terraform plan of terraform-aws needs (refresh of every resource
  # and data source). No secretsmanager:GetSecretValue, no table, log or object reads.
  plan_read_actions = [
    "acm:Describe*", "acm:Get*", "acm:List*",
    "autoscaling:Describe*",
    "cloudwatch:Describe*", "cloudwatch:List*",
    "dynamodb:Describe*", "dynamodb:List*",
    "ec2:Describe*", "ec2:Get*",
    "ecr:Describe*", "ecr:GetLifecyclePolicy", "ecr:GetRepositoryPolicy", "ecr:List*",
    "eks:Describe*", "eks:List*",
    "elasticache:Describe*", "elasticache:List*",
    "events:Describe*", "events:List*",
    "iam:Get*", "iam:List*",
    "kms:Describe*", "kms:Get*", "kms:List*",
    "lambda:Get*", "lambda:List*",
    "logs:Describe*", "logs:List*",
    "rds:Describe*", "rds:List*",
    "route53:Get*", "route53:List*",
    "secretsmanager:DescribeSecret", "secretsmanager:GetResourcePolicy", "secretsmanager:List*",
    "ses:Get*", "ses:List*",
    "sns:Get*", "sns:List*",
    "sqs:Get*", "sqs:List*",
    "sts:GetCallerIdentity",
  ]

  # Public parameters only (EKS AMI lookups), never the account's own SecureStrings.
  public_ssm_parameters = "arn:aws:ssm:*::parameter/aws/service/*"

  ci_role_arns = [
    "arn:aws:iam::${local.account_id}:role/${var.plan_role_name}",
    "arn:aws:iam::${local.account_id}:role/${var.deploy_role_name}",
    "arn:aws:iam::${local.account_id}:role/${var.bootstrap_role_name}",
  ]
  boundary_policy_arns = [
    "arn:aws:iam::${local.account_id}:policy/${var.plan_role_name}-boundary",
    "arn:aws:iam::${local.account_id}:policy/${var.deploy_role_name}-boundary",
  ]
}

# ---------------------------------------------------------------------------
# Plan role: read-only on the services terraform-aws uses, plus the state lock
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "plan_boundary" {
  statement {
    sid       = "ReadWhatTerraformPlans"
    actions   = local.plan_read_actions
    resources = ["*"]
  }

  statement {
    sid       = "ReadPublicSsmParameters"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = [local.public_ssm_parameters]
  }

  statement {
    sid       = "TerraformStateAndLock"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation", "s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
  }
}

resource "aws_iam_policy" "plan_boundary" {
  name        = "${var.plan_role_name}-boundary"
  description = "Permission boundary of ${var.plan_role_name}: read-only on what terraform-aws uses, plus the Terraform state lock"
  policy      = data.aws_iam_policy_document.plan_boundary.json
}

# ---------------------------------------------------------------------------
# Deploy role: the services above, never the audit trail, the CI roles or other projects
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "deploy_boundary" {
  statement {
    sid       = "ServicesTerraformAndWorkflowsUse"
    actions   = [for s in local.deploy_services : "${s}:*"]
    resources = ["*"]
  }

  statement {
    sid       = "ReadOnlyExtras"
    actions   = ["elasticloadbalancing:Describe*", "autoscaling:Describe*", "sts:GetCallerIdentity"]
    resources = ["*"]
  }

  statement {
    sid       = "ReadPublicSsmParameters"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = [local.public_ssm_parameters]
  }

  statement {
    sid       = "TerraformState"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation", "s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
  }

  # --- denies (win over any allow) -------------------------------------------

  # The audit trail and the detectors (this project's and the shared ones) stay on, whatever
  # the deploy role is given later.
  statement {
    sid    = "DenySecurityServiceChanges"
    effect = "Deny"
    actions = [
      "cloudtrail:Delete*", "cloudtrail:Stop*", "cloudtrail:Update*", "cloudtrail:Put*", "cloudtrail:Remove*",
      "config:Delete*", "config:Stop*", "config:Put*",
      "guardduty:Archive*", "guardduty:Create*", "guardduty:Delete*", "guardduty:Disable*", "guardduty:Disassociate*", "guardduty:Update*",
      "securityhub:BatchDisable*", "securityhub:BatchUpdate*", "securityhub:Create*", "securityhub:Delete*", "securityhub:Disable*", "securityhub:Update*",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "DenyAuditBucket"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"]
  }

  # Tag-based: everything this bootstrap creates (roles, boundaries, the audit KMS key, the
  # Config role) carries ManagedBy = terraform-bootstrap.
  statement {
    sid    = "DenyChangesToBootstrapResources"
    effect = "Deny"
    actions = [
      "iam:Add*", "iam:Attach*", "iam:Create*", "iam:Delete*", "iam:Detach*", "iam:Put*",
      "iam:Remove*", "iam:Set*", "iam:Tag*", "iam:Untag*", "iam:Update*",
      "kms:Cancel*", "kms:Create*", "kms:Delete*", "kms:Disable*", "kms:Put*", "kms:Retire*",
      "kms:Revoke*", "kms:Schedule*", "kms:Tag*", "kms:Untag*", "kms:Update*",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/ManagedBy"
      values   = ["terraform-bootstrap"]
    }
  }

  # Same by name, for what has no tag (the hand-made bootstrap role, the OIDC provider).
  statement {
    sid    = "DenyChangesToCiIdentity"
    effect = "Deny"
    actions = [
      "iam:Attach*", "iam:Create*", "iam:Delete*", "iam:Detach*", "iam:Put*", "iam:Set*",
      "iam:Tag*", "iam:Untag*", "iam:Update*", "iam:AddClientIDToOpenIDConnectProvider",
      "iam:RemoveClientIDFromOpenIDConnectProvider",
    ]
    resources = concat(local.ci_role_arns, local.boundary_policy_arns, [local.oidc_arn])
  }

  # No long-lived credentials.
  statement {
    sid    = "DenyIamUsersAndKeys"
    effect = "Deny"
    actions = [
      "iam:CreateUser", "iam:CreateAccessKey", "iam:CreateLoginProfile", "iam:UpdateLoginProfile",
      "iam:CreateServiceSpecificCredential", "iam:UploadSSHPublicKey",
    ]
    resources = ["*"]
  }

  # No admin-level managed policies on anything the deploy role creates.
  statement {
    sid       = "DenyAdminPolicyAttachments"
    effect    = "Deny"
    actions   = ["iam:AttachRolePolicy", "iam:AttachUserPolicy", "iam:AttachGroupPolicy"]
    resources = ["*"]
    condition {
      test     = "ArnEquals"
      variable = "iam:PolicyARN"
      values = [
        "arn:aws:iam::aws:policy/AdministratorAccess",
        "arn:aws:iam::aws:policy/PowerUserAccess",
        "arn:aws:iam::aws:policy/IAMFullAccess",
      ]
    }
  }

  # Tag-based: a new role must carry this project's tag (terraform-aws sets it through
  # default_tags), so every role the deploy role creates is attributable.
  statement {
    sid       = "DenyUntaggedNewRoles"
    effect    = "Deny"
    actions   = ["iam:CreateRole"]
    resources = ["*"]
    condition {
      test     = "StringNotEquals"
      variable = "aws:RequestTag/Project"
      values   = [var.project]
    }
  }

  # Tag-based: resources tagged for another project are off limits. Resources with no
  # Project tag (made by EKS or the Load Balancer Controller, AWS-managed keys) stay usable,
  # so the daily destroy still works.
  statement {
    sid       = "DenyOtherProjects"
    effect    = "Deny"
    actions   = [for s in local.tagged_services : "${s}:*"]
    resources = ["*"]
    condition {
      test     = "StringNotEquals"
      variable = "aws:ResourceTag/Project"
      values   = [var.project]
    }
    condition {
      test     = "Null"
      variable = "aws:ResourceTag/Project"
      values   = ["false"]
    }
  }
}

resource "aws_iam_policy" "deploy_boundary" {
  name        = "${var.deploy_role_name}-boundary"
  description = "Permission boundary of ${var.deploy_role_name}: the services terraform-aws and the workflows use; never the audit trail, the CI roles or other projects"
  policy      = data.aws_iam_policy_document.deploy_boundary.json
}
