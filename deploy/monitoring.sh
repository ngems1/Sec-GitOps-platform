#!/usr/bin/env bash
# Installs or updates the monitoring stack in namespace "monitoring":
#   kube-prometheus-stack (Prometheus + Grafana, monitoring/kube-prometheus-stack.values.yaml),
#   the "Boutique" dashboard (monitoring/dashboards/*.json), and Grafana's own ALB
#   restricted to MONITORING_ALLOWED_CIDR (monitoring/grafana-ingress.yaml).
# Needs kubectl + helm on the cluster and:
#   GRAFANA_ADMIN_PASSWORD   Grafana login (GitHub secret). Required.
#   MONITORING_ALLOWED_CIDR  e.g. 203.0.113.7/32 (GitHub variable). Empty = Grafana not exposed.
#   KPS_VERSION              kube-prometheus-stack chart version (constraint)
set -euo pipefail
: "${GRAFANA_ADMIN_PASSWORD:?}" "${KPS_VERSION:?}"
NS=monitoring
MONITORING_ALLOWED_CIDR=${MONITORING_ALLOWED_CIDR:-}
# People's IPs, and the Actions logs are public: masked, never printed.
if [ -n "$MONITORING_ALLOWED_CIDR" ]; then
  echo "::add-mask::${MONITORING_ALLOWED_CIDR}"
  for c in ${MONITORING_ALLOWED_CIDR//,/ }; do echo "::add-mask::${c}"; done
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# Grafana admin login: from a private file, never on a command line.
umask 077
printf 'admin-user=admin\nadmin-password=%s\n' "$GRAFANA_ADMIN_PASSWORD" > grafana-admin.env
kubectl -n "$NS" create secret generic grafana-admin --from-env-file=grafana-admin.env \
  --dry-run=client -o yaml | kubectl apply -f -
rm -f grafana-admin.env

# Dashboards: one ConfigMap per JSON file, picked up by Grafana's sidecar (label grafana_dashboard=1).
for f in monitoring/dashboards/*.json; do
  name="dashboard-$(basename "$f" .json)"
  kubectl -n "$NS" create configmap "$name" --from-file="$(basename "$f")=$f" --dry-run=client -o yaml \
    | kubectl label --local -f - grafana_dashboard=1 -o yaml \
    | kubectl apply --server-side --force-conflicts -f -
done

if ! helm upgrade --install monitoring kube-prometheus-stack \
  --repo https://prometheus-community.github.io/helm-charts --version "$KPS_VERSION" \
  --namespace "$NS" -f monitoring/kube-prometheus-stack.values.yaml \
  --wait=watcher --timeout 10m; then
  # Show why (pods not ready, events, logs) directly in this log.
  bash deploy/diagnose.sh "$NS"
  exit 1
fi
echo "kube-prometheus-stack: $(helm -n "$NS" list -f '^monitoring$' -o json | jq -r '.[0].chart')"
# Restart Grafana so it always loads the current data sources (and its Pod Identity
# credentials, if the IAM link was created after the pod). A few seconds of downtime.
kubectl -n "$NS" rollout restart deployment -l app.kubernetes.io/name=grafana
kubectl -n "$NS" rollout status deployment -l app.kubernetes.io/name=grafana --timeout=5m
kubectl -n "$NS" get pods -o wide

# Grafana's ALB: only from the allowed addresses (one or more CIDRs, comma-separated,
# deploy/cidrs.sh), never from everywhere.
if [ -z "$MONITORING_ALLOWED_CIDR" ]; then
  kubectl -n "$NS" delete ingress grafana --ignore-not-found
  echo "::notice::Grafana is not exposed: set the repository variable MONITORING_ALLOWED_CIDR (e.g. your-ip/32)."
  exit 0
fi
source deploy/cidrs.sh
MONITORING_ALLOWED_CIDR=$(allowed_cidrs MONITORING_ALLOWED_CIDR "$MONITORING_ALLOWED_CIDR") || exit 1
export MONITORING_ALLOWED_CIDR
envsubst '${MONITORING_ALLOWED_CIDR}' < monitoring/grafana-ingress.yaml | kubectl apply -f -
# HTTPS with our domain (terraform-aws/dns.tf), when set: same settings as the shop.
if [ -n "${CERT_ARN:-}" ] && [ -n "${GRAFANA_HOST:-}" ]; then
  kubectl -n "$NS" annotate ingress grafana --overwrite \
    alb.ingress.kubernetes.io/listen-ports='[{"HTTP": 80}, {"HTTPS": 443}]' \
    alb.ingress.kubernetes.io/certificate-arn="$CERT_ARN" \
    alb.ingress.kubernetes.io/ssl-redirect=443 \
    alb.ingress.kubernetes.io/ssl-policy=ELBSecurityPolicy-TLS13-1-2-2021-06
fi

host=""
for _ in $(seq 1 30); do
  host=$(kubectl -n "$NS" get ingress grafana -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [ -n "$host" ] && break
  sleep 10
done
if [ -z "$host" ]; then
  echo "::warning::Grafana's ALB has no address yet. Check: kubectl -n kube-system logs deploy/aws-load-balancer-controller"
  exit 0
fi
grafana_url="http://${host}"
if [ -n "${CERT_ARN:-}" ] && [ -n "${GRAFANA_HOST:-}" ]; then
  bash deploy/dns-record.sh upsert "$GRAFANA_HOST" "$host"
  grafana_url="https://${GRAFANA_HOST}"
fi
echo "GRAFANA_URL=${grafana_url}" >> "${GITHUB_OUTPUT:-/dev/null}"
{
  echo "### Monitoring"
  echo "- Grafana: ${grafana_url} (user \`admin\`, password = the GRAFANA_ADMIN_PASSWORD secret)"
  echo "- Reachable only from the addresses in MONITORING_ALLOWED_CIDR. A new ALB needs 2-3 minutes before it answers."
  echo "- Dashboard: **Boutique: platform overview** (Dashboards > Browse)"
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
