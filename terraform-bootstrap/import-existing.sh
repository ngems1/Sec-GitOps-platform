#!/usr/bin/env bash
# Writes ci_import.tf with Terraform "import" blocks for bootstrap resources that
# already exist in AWS but are missing from the state. That happens when:
#   - the bucket or roles were created earlier by hand or by bootstrap/bootstrap.sh
#   - a previous run failed after creating resources but before saving its state
#   - GuardDuty, Security Hub or AWS Config were already turned on in the account
#     (one detector, hub and recorder per region: creating a second one fails)
# Terraform then adopts them instead of failing with "already exists".
# Runs on every bootstrap run (after terraform init): addresses already in the state
# are skipped, so it only ever adds what is missing.
#
# Usage: ./import-existing.sh <state-bucket> [plan-role-name] [deploy-role-name] [deploy-policy-arn]
set -euo pipefail

bucket="$1"
plan_role="${2:-week3-gha-plan}"
deploy_role="${3:-week3-gha-deploy}"
deploy_policy="${4:-arn:aws:iam::aws:policy/AdministratorAccess}"
readonly_policy="arn:aws:iam::aws:policy/ReadOnlyAccess"
region="${AWS_REGION:-us-east-1}"

out=ci_import.tf
: > "$out"

state=$(terraform state list 2>/dev/null || true)

# Adds an import block unless the address is already in the state.
add() {
  if grep -qxF "$1" <<<"$state"; then return 0; fi
  printf 'import {\n  to = %s\n  id = "%s"\n}\n\n' "$1" "$2" >> "$out"
}

# --- state bucket and its settings ------------------------------------------
if aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
  add aws_s3_bucket.state "$bucket"
  aws s3api get-bucket-encryption --bucket "$bucket" >/dev/null 2>&1 &&
    add aws_s3_bucket_server_side_encryption_configuration.state "$bucket"
  aws s3api get-public-access-block --bucket "$bucket" >/dev/null 2>&1 &&
    add aws_s3_bucket_public_access_block.state "$bucket"
  aws s3api get-bucket-ownership-controls --bucket "$bucket" >/dev/null 2>&1 &&
    add aws_s3_bucket_ownership_controls.state "$bucket"
  [ "$(aws s3api get-bucket-versioning --bucket "$bucket" --query Status --output text 2>/dev/null)" = "Enabled" ] &&
    add aws_s3_bucket_versioning.state "$bucket"
  aws s3api get-bucket-policy --bucket "$bucket" >/dev/null 2>&1 &&
    add aws_s3_bucket_policy.state "$bucket"
fi

# --- roles ---------------------------------------------------------------------
attached() { aws iam list-attached-role-policies --role-name "$1" --query "AttachedPolicies[?PolicyArn=='$2'] | length(@)" --output text 2>/dev/null; }

if aws iam get-role --role-name "$plan_role" >/dev/null 2>&1; then
  add aws_iam_role.plan "$plan_role"
  [ "$(attached "$plan_role" "$readonly_policy")" = "1" ] &&
    add aws_iam_role_policy_attachment.plan_readonly "$plan_role/$readonly_policy"
  aws iam get-role-policy --role-name "$plan_role" --policy-name terraform-state-lock >/dev/null 2>&1 &&
    add aws_iam_role_policy.plan_state "$plan_role:terraform-state-lock"
fi

if aws iam get-role --role-name "$deploy_role" >/dev/null 2>&1; then
  add aws_iam_role.deploy "$deploy_role"
  [ "$(attached "$deploy_role" "$deploy_policy")" = "1" ] &&
    add aws_iam_role_policy_attachment.deploy "$deploy_role/$deploy_policy"
fi

# --- security services (one per account and region) ---------------------------
account=$(aws sts get-caller-identity --query Account --output text)

detector=$(aws guardduty list-detectors --query 'DetectorIds[0]' --output text 2>/dev/null || true)
if [ -n "$detector" ] && [ "$detector" != "None" ]; then
  add aws_guardduty_detector.main "$detector"
fi

if aws securityhub describe-hub >/dev/null 2>&1; then
  add aws_securityhub_account.main "$account"
  fsbp="arn:aws:securityhub:${region}:${account}:subscription/aws-foundational-security-best-practices/v/1.0.0"
  aws securityhub get-enabled-standards --query 'StandardsSubscriptions[].StandardsSubscriptionArn' --output text 2>/dev/null |
    tr '\t' '\n' | grep -qxF "$fsbp" && add aws_securityhub_standards_subscription.fsbp "$fsbp"
fi

recorder=$(aws configservice describe-configuration-recorders --query 'ConfigurationRecorders[0].name' --output text 2>/dev/null || true)
if [ -n "$recorder" ] && [ "$recorder" != "None" ]; then
  if [ "$recorder" != "default" ]; then
    echo "::error::An AWS Config recorder named '${recorder}' already exists; this bootstrap manages one named 'default' (only one per region). Rename it or delete it, then re-run."
    exit 1
  fi
  add aws_config_configuration_recorder.main default
  add aws_config_configuration_recorder_status.main default
fi
channel=$(aws configservice describe-delivery-channels --query 'DeliveryChannels[0].name' --output text 2>/dev/null || true)
if [ -n "$channel" ] && [ "$channel" != "None" ]; then
  if [ "$channel" != "default" ]; then
    echo "::error::An AWS Config delivery channel named '${channel}' already exists; this bootstrap manages one named 'default'. Delete it, then re-run."
    exit 1
  fi
  add aws_config_delivery_channel.main default
fi

if [ -s "$out" ]; then
  echo "Existing resources found, they will be imported:"
  cat "$out"
else
  rm -f "$out"
  echo "Nothing to import."
fi
