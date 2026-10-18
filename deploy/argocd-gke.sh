#!/usr/bin/env bash
# Registers the GKE cluster in Argo CD on EKS and proves the connection (ADR 0014, decision 4).
# Run by the argocd-gke workflow, after argocd-install (the controller and server need the
# gcp-token / gcp-credentials volumes of deploy/argocd/values.yaml). No static credential:
# Argo CD's pods exchange their own Kubernetes token for argocd-hub's (terraform-gcp-bootstrap).
#
#   1. GKE (as gha-deploy): the throwaway probe namespace, read-only for argocd-hub.
#   2. EKS: the credential file (ConfigMap gcp-wif-credentials), no secret in it.
#   3. Diagnostic, before Argo CD is involved: argocd-k8s-auth gcp inside the controller and
#      server pods, then direct calls to the GKE API with the controller's token: /version,
#      a read in argocd-probe (must work), a cluster-wide list (must be refused).
#   4. EKS: the cluster Secret, the probe AppProject and Application; then Argo CD's own
#      status of the probe (Synced, Healthy, no error), which needs a working cluster cache.
#
# Needs kubectl (EKS: the default context; GKE: $GKE_KUBECONFIG), gcloud (signed in as
# gha-deploy), jq, curl, envsubst, and:
#   GKE_KUBECONFIG     kubeconfig of the GKE cluster (DNS-based endpoint, gcloud credentials)
#   GKE_DNS_ENDPOINT   the control plane's DNS-based endpoint (host name)
#   ARGOCD_SA          argocd-hub's email (terraform-gcp-bootstrap output GCP_ARGOCD_SA)
#   EKS_WIF_PROVIDER   the eks-argocd pool's provider (output GCP_EKS_WIF_PROVIDER)
#   REPO_URL           this repository (Argo CD's repository credential)
# The logs are public: no token is printed (masked as soon as it exists), only HTTP statuses.
# shellcheck disable=SC2016 # ${ARGOCD_SA} and ${REPO_URL} are envsubst's, not the shell's
set -euo pipefail

: "${GKE_KUBECONFIG:?}" "${GKE_DNS_ENDPOINT:?}" "${ARGOCD_SA:?}" "${EKS_WIF_PROVIDER:?}" "${REPO_URL:?}"
NS=argocd
# Release "argo-cd" (deploy/argocd.sh): workloads are argo-cd-argocd-*, their service accounts
# argocd-application-controller and argocd-server (the subjects terraform-gcp-bootstrap trusts).
here=$(cd "$(dirname "$0")" && pwd)
gke() { kubectl --kubeconfig "$GKE_KUBECONFIG" "$@"; }
CRED=/etc/gcp/credentials.json # mount of gcp-credentials (deploy/argocd/values.yaml)
HINT="If the error is about the token or its issuer: EKS was probably rebuilt. Set EKS_OIDC_ISSUER to the new issuer and re-run bootstrap-gcp (terraform-gcp-bootstrap/README.md)."

# --- 1. GKE: the probe namespace -------------------------------------------------------------
export ARGOCD_SA
envsubst '${ARGOCD_SA}' < "${here}/argocd/gke/probe-rbac.yaml" | gke apply -f -

# --- 2. EKS: the credential file -------------------------------------------------------------
# Points Google's client library at the projected token (audience eks-argocd) and at argocd-hub.
gcloud iam workload-identity-pools create-cred-config "$EKS_WIF_PROVIDER" \
  --service-account="$ARGOCD_SA" \
  --credential-source-file=/var/run/secrets/gcp/token \
  --credential-source-type=text \
  --output-file=credentials.json >/dev/null 2>&1
kubectl -n "$NS" create configmap gcp-wif-credentials --from-file=credentials.json \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
rm -f credentials.json
echo "gcp-wif-credentials: written"

# An optional ConfigMap volume fills in some time after the ConfigMap appears: restart the pods
# that don't see the file yet.
for w in statefulset/argo-cd-argocd-application-controller deployment/argo-cd-argocd-server; do
  kubectl -n "$NS" get "$w" -o json | jq -e '.spec.template.spec.volumes[]? | select(.name == "gcp-token")' >/dev/null \
    || { echo "::error::${w} has no gcp-token volume: run the argocd-install workflow first (deploy/argocd/values.yaml)."; exit 1; }
  if ! kubectl -n "$NS" exec "$w" -- test -s "$CRED" 2>/dev/null; then
    kubectl -n "$NS" rollout restart "$w" >/dev/null
    kubectl -n "$NS" rollout status "$w" --timeout=5m >/dev/null
  fi
  kubectl -n "$NS" exec "$w" -- test -s "$CRED" \
    || { echo "::error::${w}: ${CRED} still missing after a restart"; exit 1; }
done

# --- 3. Diagnostic: the auth chain inside Argo CD's own pods, then the GKE API ----------------
# argocd-k8s-auth gcp prints an ExecCredential (JSON) with the token: kept in $token (never in
# a command substitution of this function, so the mask line reaches the log), masked at once.
token=""
mint() {
  local out
  if ! out=$(kubectl -n "$NS" exec "$1" -- env GOOGLE_APPLICATION_CREDENTIALS="$CRED" argocd-k8s-auth gcp 2>&1); then
    echo "::error::$1: argocd-k8s-auth gcp failed (EKS token -> STS -> argocd-hub)."
    sed -E 's/(ya29|eyJ)[A-Za-z0-9._-]+/<token>/g' <<<"$out" | tail -5
    echo "$HINT"
    exit 1
  fi
  token=$(jq -r '.status.token // empty' <<<"$out" 2>/dev/null || true)
  unset out
  [ -n "$token" ] || { echo "::error::$1: argocd-k8s-auth gcp returned no token"; exit 1; }
  echo "::add-mask::${token}"
}
mint deployment/argo-cd-argocd-server            # the server's chain works too (UI live view, logs)
mint statefulset/argo-cd-argocd-application-controller # the controller's token is used below
echo "argocd-k8s-auth gcp: a token for argocd-hub in the controller and the server pods"

api() { curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${token}" "https://${GKE_DNS_ENDPOINT}$1"; }
check() { # path, expected status, what it proves
  local got; got=$(api "$1")
  if [ "$got" = "$2" ]; then echo "GKE API ${1}: ${got} (${3})"; else echo "::error::GKE API ${1}: ${got}, expected ${2} (${3})"; failed=1; fi
}
failed=0
check /version 200 "reached the DNS-based endpoint, IAM let argocd-hub connect"
check /api/v1/namespaces/argocd-probe/configmaps 200 "RBAC: argocd-hub reads the probe namespace"
check /api/v1/namespaces 403 "nothing cluster-wide: no read beyond RBAC"
check /api/v1/namespaces/argocd-probe/configmaps/x 404 "a read of a missing object is a 404, not a 403"
unset token
[ "$failed" = 0 ] || { echo "$HINT"; exit 1; }

# --- 4. EKS: register the cluster, then Argo CD's own status ----------------------------------
config=$(jq -cn --arg cred "$CRED" '{
  execProviderConfig: {
    command: "argocd-k8s-auth", args: ["gcp"],
    apiVersion: "client.authentication.k8s.io/v1beta1",
    env: {GOOGLE_APPLICATION_CREDENTIALS: $cred}
  },
  tlsClientConfig: {insecure: false}
}') # Google-signed certificate on the DNS endpoint: no caData
kubectl -n "$NS" create secret generic cluster-boutique-gke \
  --from-literal=name=boutique-gke \
  --from-literal=server="https://${GKE_DNS_ENDPOINT}" \
  --from-literal=namespaces=argocd-probe \
  --from-literal=clusterResources=false \
  --from-literal=config="$config" \
  --dry-run=client -o yaml \
  | kubectl label --local -f - argocd.argoproj.io/secret-type=cluster -o yaml \
  | kubectl apply -f - >/dev/null
echo "cluster Secret: boutique-gke (namespace argocd-probe only, no cluster-scoped resources)"

export REPO_URL
envsubst '${REPO_URL}' < "${here}/argocd/gke/probe-project.yaml" | kubectl apply -f -
envsubst '${REPO_URL}' < "${here}/argocd/gke/probe-app.yaml" | kubectl apply -f -
kubectl -n "$NS" annotate application gke-connection-probe argocd.argoproj.io/refresh=hard --overwrite >/dev/null

app_state() {
  kubectl -n "$NS" get application gke-connection-probe -o json \
    | jq -r '[.status.sync.status // "-", .status.health.status // "-", ([.status.conditions[]? | .type + ": " + .message] | join("; "))] | @tsv'
}
for _ in $(seq 1 30); do
  IFS=$'\t' read -r sync health conditions <<<"$(app_state)"
  if [ "$sync" = Synced ] && [ "$health" = Healthy ] && [ -z "$conditions" ]; then
    echo "Argo CD: gke-connection-probe Synced and Healthy on boutique-gke: the cluster is connected."
    exit 0
  fi
  sleep 10
done
echo "::error::Argo CD: gke-connection-probe is ${sync}/${health} after 5 minutes. ${conditions}"
exit 1
