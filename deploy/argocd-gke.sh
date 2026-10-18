#!/usr/bin/env bash
# Deploys the shop's portable profile to GKE through Argo CD on EKS (ADR 0014, decisions 1
# and 4), and checks it. Run by the argocd-gke workflow, after argocd-install (the controller
# and server need the gcp-token / gcp-credentials volumes of deploy/argocd/values.yaml) and a
# mirror-images-gcp run (the images). No static credential: Argo CD's pods exchange their own
# Kubernetes token for argocd-hub's (terraform-gcp-bootstrap).
#
#   1. GKE (as gha-deploy): namespace boutique-gke, argocd-hub's Role there, the PriorityClass.
#      The old connection probe (argocd-probe) is removed, on both clusters.
#   2. EKS: the credential file (ConfigMap gcp-wif-credentials), no secret in it.
#   3. Preflight, before Argo CD is involved: argocd-k8s-auth gcp inside the controller and
#      server pods, then direct calls to the GKE API with the controller's token: /version,
#      a read in boutique-gke (must work), a cluster-wide list (must be refused).
#   4. EKS: the cluster Secret (boutique-gke only), project boutique-gcp, Application
#      boutique-gke; then Argo CD's own status (Synced, Healthy, no error).
#   5. The shop, through a port-forward (nothing is public): the home page, a product, the cart
#      (Redis). And where every running image was pulled from: all from Artifact Registry?
#
# Needs kubectl (EKS: the default context; GKE: $GKE_KUBECONFIG), helm, gcloud (signed in as
# gha-deploy), jq, curl, envsubst, and:
#   GKE_KUBECONFIG     kubeconfig of the GKE cluster (DNS-based endpoint, gcloud credentials)
#   GKE_DNS_ENDPOINT   the control plane's DNS-based endpoint (host name)
#   ARGOCD_SA          argocd-hub's email (terraform-gcp-bootstrap output GCP_ARGOCD_SA)
#   EKS_WIF_PROVIDER   the eks-argocd pool's provider (output GCP_EKS_WIF_PROVIDER)
#   AR_REGISTRY        <region>-docker.pkg.dev/<project>/boutique (the mirror)
#   REPO_URL           this repository (Argo CD's repository credential)
# The logs are public: no token is printed (masked as soon as it exists), only HTTP statuses
# and counts; the workflow masks the project and account IDs.
# shellcheck disable=SC2016 # ${ARGOCD_SA}, ${REPO_URL} and ${AR_REGISTRY} are envsubst's, not the shell's
set -euo pipefail

: "${GKE_KUBECONFIG:?}" "${GKE_DNS_ENDPOINT:?}" "${ARGOCD_SA:?}" "${EKS_WIF_PROVIDER:?}" "${AR_REGISTRY:?}" "${REPO_URL:?}"
NS=argocd
APP_NS=boutique-gke
# Release "argo-cd" (deploy/argocd.sh): workloads are argo-cd-argocd-*, their service accounts
# argocd-application-controller and argocd-server (the subjects terraform-gcp-bootstrap trusts).
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "${here}/.." && pwd)
gke() { kubectl --kubeconfig "$GKE_KUBECONFIG" "$@"; }
CRED=/etc/gcp/credentials.json # mount of gcp-credentials (deploy/argocd/values.yaml)
HINT="If the error is about the token or its issuer: EKS was probably rebuilt. Set EKS_OIDC_ISSUER to the new issuer and re-run bootstrap-gcp (terraform-gcp-bootstrap/README.md)."
export ARGOCD_SA REPO_URL AR_REGISTRY

# --- 1. GKE: the namespace, argocd-hub's Role, the PriorityClass; the probe goes -------------
envsubst '${ARGOCD_SA}' < "${here}/argocd/gke/namespace.yaml" | gke apply -f -
# Cluster-scoped, so never in the release: rendered alone, like deploy-env.yml does on EKS.
helm template boutique "${repo}/helm-chart" -n "$APP_NS" -f "${repo}/helm-chart/values-gcp.yaml" \
  --set guardrails.priority.render=true --show-only templates/priorityclass.yaml | gke apply -f -

# The connection probe of the previous step (Application gke-connection-probe, project
# gke-probe, namespace argocd-probe) is replaced by the real Application.
kubectl -n "$NS" delete application gke-connection-probe --ignore-not-found --wait=true >/dev/null
kubectl -n "$NS" delete appproject gke-probe --ignore-not-found >/dev/null
gke delete namespace argocd-probe --ignore-not-found --wait=false >/dev/null
echo "connection probe: removed (if it was there)"

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

# --- 3. Preflight: the auth chain inside Argo CD's own pods, then the GKE API -----------------
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
check "/api/v1/namespaces/${APP_NS}/configmaps" 200 "RBAC: argocd-hub reaches the shop's namespace"
check /api/v1/namespaces 403 "nothing cluster-wide: no access beyond its namespace"
unset token
[ "$failed" = 0 ] || { echo "$HINT"; exit 1; }

# --- 4. EKS: register the cluster, the project and the Application ----------------------------
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
  --from-literal=namespaces="$APP_NS" \
  --from-literal=clusterResources=false \
  --from-literal=config="$config" \
  --dry-run=client -o yaml \
  | kubectl label --local -f - argocd.argoproj.io/secret-type=cluster -o yaml \
  | kubectl apply -f - >/dev/null
echo "cluster Secret: boutique-gke (namespace ${APP_NS} only, no cluster-scoped resources)"

envsubst '${REPO_URL}' < "${here}/argocd/gke/project.yaml" | kubectl apply -f -
envsubst '${REPO_URL} ${AR_REGISTRY}' < "${here}/argocd/gke/boutique-gke.yaml" | kubectl apply -f -
kubectl -n "$NS" annotate application boutique-gke argocd.argoproj.io/refresh=hard --overwrite >/dev/null

# Autopilot starts nodes for the new pods: allow a few minutes.
app_state() {
  kubectl -n "$NS" get application boutique-gke -o json \
    | jq -r '[.status.sync.status // "-", .status.health.status // "-", ([.status.conditions[]? | .type + ": " + .message] | join("; "))] | @tsv'
}
sync="-" health="-" conditions=""
for _ in $(seq 1 90); do
  IFS=$'\t' read -r sync health conditions <<<"$(app_state)"
  [ "$sync" = Synced ] && [ "$health" = Healthy ] && [ -z "$conditions" ] && break
  sleep 10
done
if [ "$sync" != Synced ] || [ "$health" != Healthy ] || [ -n "$conditions" ]; then
  echo "::error::Argo CD: boutique-gke is ${sync}/${health} after 15 minutes. ${conditions}"
  kubectl -n "$NS" get application boutique-gke -o json \
    | jq -r '.status.resources[]? | select(.health.status != null and .health.status != "Healthy") | "  \(.kind)/\(.name): \(.health.status) \(.health.message // "")"' || true
  gke -n "$APP_NS" get pods 2>/dev/null || true
  exit 1
fi
echo "Argo CD: boutique-gke Synced and Healthy on the GKE cluster."

# --- 5. The shop, through a port-forward; where the images came from --------------------------
gke -n "$APP_NS" port-forward svc/frontend 18080:80 >/dev/null 2>&1 &
pf=$!
trap 'kill "$pf" 2>/dev/null || true' EXIT
for _ in $(seq 1 15); do curl -s -o /dev/null http://127.0.0.1:18080/ >/dev/null 2>&1 && break; sleep 2; done
failed=0
page() { # path, what it proves
  local got; got=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "http://127.0.0.1:18080$1")
  if [ "$got" = 200 ]; then echo "shop ${1}: 200 (${2})"; else echo "::error::shop ${1}: ${got}, expected 200 (${2})"; failed=1; fi
}
page / "frontend, catalog, currency, ads, recommendations"
page /product/OLJCESPC7Z "a product page"
page /cart "the cart: cartservice and its Redis"

# Every running container (init containers included): the registry its image was pulled from.
gke -n "$APP_NS" get pods -o json | jq -r '.items[].status | ((.initContainerStatuses // []) + (.containerStatuses // []))[] | .imageID' > image-ids.txt
total=$(grep -c . image-ids.txt || true)
outside=$(grep -vc "^${AR_REGISTRY%%/*}/" image-ids.txt || true)
rm -f image-ids.txt
if [ "$outside" = 0 ]; then
  echo "images: all ${total} running containers pulled from Artifact Registry, none from Docker Hub"
else
  echo "::warning::images: ${outside} of ${total} running containers pulled from outside Artifact Registry (Cloud NAT is still needed)"
fi
[ "$failed" = 0 ] || exit 1
echo "boutique-gke: deployed by Argo CD and serving."
