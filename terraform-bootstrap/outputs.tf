# Add these as GitHub repository variables: repo > Settings > Secrets and variables > Actions > Variables.
# The bootstrap workflow prints them as a table in its run summary.

output "AWS_REGION" {
  value = var.region
}

output "AWS_PLAN_ROLE_ARN" {
  value = aws_iam_role.plan.arn
}

output "AWS_DEPLOY_ROLE_ARN" {
  value = aws_iam_role.deploy.arn
}

output "TF_STATE_BUCKET" {
  value = aws_s3_bucket.state.bucket
}

# Not GitHub variables: where to look for the audit trail (docs/week3/SECURITY.md).
output "audit_bucket" {
  value = aws_s3_bucket.audit.bucket
}

output "cloudtrail_trail" {
  value = aws_cloudtrail.main.name
}
