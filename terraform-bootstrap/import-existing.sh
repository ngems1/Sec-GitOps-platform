#!/usr/bin/env bash
# Writes ci_import.tf with Terraform "import" blocks for bootstrap resources that
# already exist in AWS but are missing from the state. That happens when:
#   - the bucket or roles were created earlier by hand or by bootstrap/bootstrap.sh
#   - a previous run failed after creating resources but before saving its state
# Terraform then adopts them instead of failing with "already exists".
# Never imports anything else: GuardDuty, the AWS Config recorder and Security Hub in
# this account belong to another project and stay unmanaged here (ADR 0003).
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

if [ -s "$out" ]; then
  echo "Existing resources found, they will be imported:"
  cat "$out"
else
  rm -f "$out"
  echo "Nothing to import."
fi
