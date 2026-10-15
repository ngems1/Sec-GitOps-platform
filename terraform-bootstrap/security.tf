# Account security baseline (DESIGN D-07, ADR 0003): this project's own CloudTrail trail,
# its audit bucket and key, and its AWS Config rules. It lives here, not in terraform-aws:
# terraform-aws is destroyed every day, and the audit bucket uses S3 Object Lock, whose
# files cannot be deleted before their retention ends, so a destroy would fail. Nothing here
# is ever destroyed.
#
# Shared, not managed here: GuardDuty, the AWS Config recorder and delivery channel, and
# Security Hub (with FSBP) already exist in this account for another project. Each is one per
# account and region, so this project uses them as they are and never imports, tags or
# changes them (ADR 0003). Owning them needs a separate AWS account.

locals {
  account_id   = data.aws_caller_identity.current.account_id
  audit_bucket = "${var.project}-audit-${local.account_id}"
  trail_name   = "${var.project}-trail"
  trail_arn    = "arn:aws:cloudtrail:${var.region}:${local.account_id}:trail/${local.trail_name}"
}

# ---------------------------------------------------------------------------
# 4. KMS key for the CloudTrail log files
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "audit_key" {
  # IAM policies of the account decide who else may use the key (to read the logs).
  statement {
    sid       = "AccountAdministration"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }
  }

  statement {
    sid       = "CloudTrailEncryptsThisTrail"
    actions   = ["kms:GenerateDataKey*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:aws:cloudtrail:arn"
      values   = ["arn:aws:cloudtrail:*:${local.account_id}:trail/*"]
    }
  }

  statement {
    sid       = "CloudTrailDescribesKey"
    actions   = ["kms:DescribeKey"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }
}

resource "aws_kms_key" "audit" {
  description             = "CloudTrail log files in the week3 audit bucket"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.audit_key.json

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "audit" {
  name          = "alias/${var.project}-audit"
  target_key_id = aws_kms_key.audit.key_id
}

# ---------------------------------------------------------------------------
# 5. Audit bucket: Object Lock (GOVERNANCE), KMS, private, deleted after 90 days
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "audit" {
  bucket              = local.audit_bucket
  object_lock_enabled = true

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "audit" {
  bucket = aws_s3_bucket.audit.id

  versioning_configuration {
    status = "Enabled" # required by Object Lock
  }
}

# GOVERNANCE: only a principal with s3:BypassGovernanceRetention (the bootstrap role, an
# admin) can delete a file before its retention ends. The plan and deploy roles cannot.
resource "aws_s3_bucket_object_lock_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    default_retention {
      mode = "GOVERNANCE"
      days = var.audit_retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.audit]
}

resource "aws_s3_bucket_server_side_encryption_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.audit.arn
    }
    bucket_key_enabled = true # one data key per bucket and hour instead of one KMS call per file
  }
}

resource "aws_s3_bucket_public_access_block" "audit" {
  bucket = aws_s3_bucket.audit.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Day 90: the current version becomes a delete marker; a day later the old version is gone
# (its 30-day lock ended long before); then the leftover delete marker is removed.
resource "aws_s3_bucket_lifecycle_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    id     = "expire-audit-files"
    status = "Enabled"
    filter {}

    expiration {
      days = var.audit_expiry_days
    }
    noncurrent_version_expiration {
      noncurrent_days = 1
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "remove-expired-delete-markers"
    status = "Enabled"
    filter {}

    expiration {
      expired_object_delete_marker = true
    }
  }

  depends_on = [aws_s3_bucket_versioning.audit]
}

data "aws_iam_policy_document" "audit_bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid       = "CloudTrailAclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.audit.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }

  statement {
    sid       = "CloudTrailWrite"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.audit.arn}/cloudtrail/AWSLogs/${local.account_id}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
}

resource "aws_s3_bucket_policy" "audit" {
  bucket = aws_s3_bucket.audit.id
  policy = data.aws_iam_policy_document.audit_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.audit]
}

# ---------------------------------------------------------------------------
# 6. CloudTrail: one multi-region trail, management events, log file validation
# ---------------------------------------------------------------------------
# This project's own trail and bucket, so its audit files are under its own Object Lock and
# key whatever the other trails in the account do.
resource "aws_cloudtrail" "main" {
  name                          = local.trail_name
  s3_bucket_name                = aws_s3_bucket.audit.id
  s3_key_prefix                 = "cloudtrail"
  kms_key_id                    = aws_kms_key.audit.arn
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true

  depends_on = [aws_s3_bucket_policy.audit]
}

# ---------------------------------------------------------------------------
# 7. AWS Config rules (this project's), evaluated by the account's shared recorder
# ---------------------------------------------------------------------------
# The recorder and delivery channel belong to another project (see the top of this file).
# These rules only add evaluations; if the recorder ever stops, they stop reporting.
# Names carry the project prefix so they never clash with rules of another project.
# Periodic rules (no resource type) run once a day.
locals {
  config_rules = {
    s3-bucket-public-access-prohibited = { id = "S3_BUCKET_LEVEL_PUBLIC_ACCESS_PROHIBITED", periodic = false }
    s3-bucket-encryption-enabled       = { id = "S3_BUCKET_SERVER_SIDE_ENCRYPTION_ENABLED", periodic = false }
    rds-storage-encrypted              = { id = "RDS_STORAGE_ENCRYPTED", periodic = false }
    rds-instance-public-access-check   = { id = "RDS_INSTANCE_PUBLIC_ACCESS_CHECK", periodic = false }
    iam-root-access-key-check          = { id = "IAM_ROOT_ACCESS_KEY_CHECK", periodic = true }
    cloudtrail-enabled                 = { id = "CLOUD_TRAIL_ENABLED", periodic = true }
  }
}

resource "aws_config_config_rule" "managed" {
  for_each = local.config_rules

  name                        = "${var.project}-${each.key}"
  maximum_execution_frequency = each.value.periodic ? "TwentyFour_Hours" : null

  source {
    owner             = "AWS"
    source_identifier = each.value.id
  }
}
