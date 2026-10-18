#!/usr/bin/env bash
# Before terraform-gcp is destroyed (infra-gcp, action destroy): removes what Terraform didn't
# create but depends on, in this order (ADR 0014, decision 6):
#   1. Route 53: gke.<domain>. Left behind, it would point at a released IP that Google may give
#      to someone else.
#   2. EKS: the Argo CD Application boutique-gke, without its resources (no finalizer), so its
#      self-heal doesn't put the Ingress back while it's being removed. argocd-gke registers it
#      again after a rebuild.
#   3. GKE: the Ingress. Its finalizer makes GKE delete the load balancer (forwarding rules,
#      proxies, NEGs) first; until then the static IP is in use and the network can't go.
# Each step is skipped when its side is already gone (a re-run, or terraform-aws destroyed).
#
# Needs AWS credentials (deploy role), gcloud signed in as gha-deploy (with
# gke-gcloud-auth-plugin), kubectl, jq, and:
#   GCP_PROJECT_ID, GCP_REGION, AWS_REGION, TF_STATE_BUCKET (terraform-aws's state)
set -euo pipefail
: "${GCP_PROJECT_ID:?}" "${GCP_REGION:?}" "${AWS_REGION:?}" "${TF_STATE_BUCKET:?}"
here=$(cd "$(dirname "$0")" && pwd)
ADDRESS=boutique-gke-ingress

# --- terraform-aws: the zone, the domain, the EKS cluster ------------------------------------
domain="" zone="" cluster=""
if aws s3 cp "s3://${TF_STATE_BUCKET}/week3/terraform.tfstate" state.json --only-show-errors 2>/dev/null; then
  domain=$(jq -r '.outputs.tls.value.domain // empty' state.json)
  zone=$(jq -r '.outputs.tls.value.zone_id // empty' state.json)
  cluster=$(jq -r '.outputs.cluster_name.value // empty' state.json)
fi
rm -f state.json
[ -n "$zone" ] && echo "::add-mask::${zone}"

# --- 1. Route 53 -------------------------------------------------------------------------------
if [ -n "$domain" ] && [ -n "$zone" ]; then
  DNS_ZONE_ID="$zone" bash "${here}/dns-record.sh" delete "gke.${domain}"
else
  echo "Route 53: no terraform-aws domain, no gke.<domain> record to remove"
fi

# --- 2. EKS: stop Argo CD from re-creating the Ingress ----------------------------------------
if [ -n "$cluster" ] && aws eks update-kubeconfig --name "$cluster" --region "$AWS_REGION" >/dev/null 2>&1; then
  kubectl -n argocd delete application boutique-gke --ignore-not-found --wait=true --timeout=2m >/dev/null
  echo "Argo CD: Application boutique-gke removed (its resources stay until the cluster goes)"
else
  echo "Argo CD: no EKS cluster, nothing syncs boutique-gke"
fi

# --- 3. GKE: the Ingress, then its load balancer -----------------------------------------------
export KUBECONFIG="${RUNNER_TEMP:-/tmp}/gke-teardown.kubeconfig"
if gcloud container clusters get-credentials boutique-gke --region "$GCP_REGION" --project "$GCP_PROJECT_ID" --dns-endpoint >/dev/null 2>&1; then
  kubectl -n boutique-gke delete ingress frontend --ignore-not-found --wait=true --timeout=10m >/dev/null \
    || { echo "::error::the Ingress frontend was not deleted within 10 minutes: its load balancer would block the destroy"; exit 1; }
  echo "GKE: Ingress frontend deleted"
else
  echo "GKE: no cluster boutique-gke, no Ingress to remove"
fi
rm -f "$KUBECONFIG"

# The address is free once no forwarding rule uses it (status RESERVED, not IN_USE).
for _ in $(seq 1 30); do
  status=$(gcloud compute addresses describe "$ADDRESS" --global --project "$GCP_PROJECT_ID" --format='value(status)' 2>/dev/null || echo GONE)
  case "$status" in
    RESERVED|GONE) echo "static IP ${ADDRESS}: ${status,,}, ready for terraform destroy"; exit 0 ;;
  esac
  sleep 10
done
echo "::error::static IP ${ADDRESS} still ${status} after 5 minutes: a load balancer still uses it (gcloud compute forwarding-rules list --global)"
exit 1
