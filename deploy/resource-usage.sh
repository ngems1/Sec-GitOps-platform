#!/usr/bin/env bash
# Resource usage report (cluster-status, section "Resource usage"): real CPU and memory use of
# every container in boutique-dev, boutique-prod, monitoring and argo-rollouts over the last 24 h,
# against its requests and limits, with a suggested request. Data only: nothing is changed.
#   1. a Job in "monitoring" runs deploy/resource-usage/queries.txt against Prometheus (no login,
#      no secret) and prints the results in its log;
#   2. kubectl reads the current pods, workloads and nodes;
#   3. deploy/resource-usage/render.sh prints one table per namespace and the cluster totals.
# The Job and its ConfigMap are removed at the end, pass or fail. Needs kubectl, jq, envsubst,
# column, and CURL_IMAGE (pinned in cluster-status.yml).
set -euo pipefail
: "${CURL_IMAGE:?}"
NS=monitoring
work=$(mktemp -d)
export CURL_IMAGE

cleanup() {
  kubectl -n "$NS" delete job resource-usage-query --ignore-not-found --wait=false >/dev/null || true
  kubectl -n "$NS" delete configmap resource-usage-queries --ignore-not-found >/dev/null || true
  rm -rf "$work"
}
kubectl -n "$NS" delete job resource-usage-query --ignore-not-found --wait=true >/dev/null
trap cleanup EXIT

kubectl -n "$NS" create configmap resource-usage-queries --from-file=queries.txt=deploy/resource-usage/queries.txt \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
envsubst '${CURL_IMAGE}' < deploy/k8s/resource-usage-query.yaml | kubectl apply -f - >/dev/null

result=timeout
for _ in $(seq 1 60); do
  if [ "$(kubectl -n "$NS" get job resource-usage-query -o jsonpath='{.status.succeeded}')" = "1" ]; then result=ok; break; fi
  if [ -n "$(kubectl -n "$NS" get job resource-usage-query -o jsonpath='{.status.failed}')" ]; then result=failed; break; fi
  sleep 5
done
kubectl -n "$NS" logs job/resource-usage-query > "$work/log.txt" 2>/dev/null || true
if [ "$result" != ok ]; then
  grep -v '^RESULT ' "$work/log.txt" || true
  kubectl -n "$NS" describe job resource-usage-query | tail -15
  echo "::error::Resource usage: the Prometheus queries did not finish (${result}). Is Prometheus running in monitoring?"
  exit 1
fi
for name in cpu_avg cpu_p95 cpu_max mem_p95 mem_max hours; do
  grep "^RESULT ${name} " "$work/log.txt" | cut -d' ' -f3- > "$work/${name}.json"
  [ -s "$work/${name}.json" ] || { echo "::error::Resource usage: no result for ${name}"; exit 1; }
done

kubectl get pods -A -o json > "$work/pods.json"
kubectl get nodes -o json > "$work/nodes.json"
kubectl get hpa -A -o json > "$work/hpa.json"
{
  kubectl get deployments,statefulsets,daemonsets,jobs -A -o json
  if kubectl get crd rollouts.argoproj.io >/dev/null 2>&1; then kubectl get rollouts.argoproj.io -A -o json; fi
} | jq -s '{items: (map(.items) | add)}' > "$work/workloads.json"

bash deploy/resource-usage/render.sh "$work"
