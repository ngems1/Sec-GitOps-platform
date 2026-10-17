#!/usr/bin/env bash
# Smoke test of the tracing backend (ADR 0010, step 1), run by the deploy workflow after
# deploy/monitoring.sh:
#   1. a Job in boutique-dev (telemetrygen) sends 3 normal traces and 1 error trace to the OTel
#      Collector, under a service name unique to this run;
#   2. a Job in monitoring searches Tempo for the error trace, through Grafana's Tempo data source.
# The error trace proves the whole path: collector reachable from boutique-dev, tail sampling
# keeps errors, export to Tempo, Tempo search, Grafana data source. Both Jobs (and the sender's
# NetworkPolicy) are removed at the end, pass or fail. No secret is printed: the query Job reads
# the Grafana login from its Secret.
# Needs kubectl on the cluster, envsubst, and TELEMETRYGEN_IMAGE / CURL_IMAGE (pinned in deploy.yml).
set -euo pipefail
: "${TELEMETRYGEN_IMAGE:?}" "${CURL_IMAGE:?}"
DEV_NS=boutique-dev
MON_NS=monitoring
SMOKE_SERVICE="trace-smoke-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
export SMOKE_SERVICE TELEMETRYGEN_IMAGE CURL_IMAGE

cleanup() {
  kubectl -n "$DEV_NS" delete job tracing-smoke-send --ignore-not-found --wait=false >/dev/null || true
  kubectl -n "$DEV_NS" delete networkpolicy tracing-smoke-send --ignore-not-found >/dev/null || true
  kubectl -n "$MON_NS" delete job tracing-smoke-query --ignore-not-found --wait=false >/dev/null || true
}

# wait_job NAMESPACE JOB SECONDS: 0 when the Job succeeded; its logs are printed either way.
wait_job() {
  local ns=$1 job=$2 deadline=$((SECONDS + $3)) result=timeout
  while [ $SECONDS -lt $deadline ]; do
    if [ "$(kubectl -n "$ns" get job "$job" -o jsonpath='{.status.succeeded}')" = "1" ]; then result=ok; break; fi
    if [ -n "$(kubectl -n "$ns" get job "$job" -o jsonpath='{.status.failed}')" ]; then result=failed; break; fi
    sleep 5
  done
  kubectl -n "$ns" logs "job/$job" --all-containers --prefix --tail=50 2>/dev/null || true
  [ "$result" = ok ] || { kubectl -n "$ns" describe job "$job" | tail -15; return 1; }
}

# Same as deploy-env.yml; on a brand-new cluster the namespace may not exist yet.
kubectl create namespace "$DEV_NS" --dry-run=client -o yaml | kubectl apply -f -
# Leftovers of an interrupted run.
kubectl -n "$DEV_NS" delete job tracing-smoke-send --ignore-not-found --wait=true
kubectl -n "$MON_NS" delete job tracing-smoke-query --ignore-not-found --wait=true
trap cleanup EXIT

echo "Sending test traces as service ${SMOKE_SERVICE} from ${DEV_NS}"
envsubst '${SMOKE_SERVICE} ${TELEMETRYGEN_IMAGE}' < deploy/k8s/tracing-smoke-send.yaml | kubectl -n "$DEV_NS" apply -f -
if ! wait_job "$DEV_NS" tracing-smoke-send 180; then
  echo "::error::Tracing smoke test: telemetrygen could not send traces from ${DEV_NS} to otel-collector.monitoring:4317. Check the collector pod and the NetworkPolicies (RUNBOOK, Tracing backend)."
  exit 1
fi

echo "Searching Tempo for the error trace"
envsubst '${SMOKE_SERVICE} ${CURL_IMAGE}' < deploy/k8s/tracing-smoke-query.yaml | kubectl apply -f -
if ! wait_job "$MON_NS" tracing-smoke-query 360; then
  echo "::error::Tracing smoke test: the error trace sent to the collector is not in Tempo. Check the collector logs (tail sampling, export to tempo:4317), Tempo, and Grafana's Tempo data source (RUNBOOK, Tracing backend)."
  exit 1
fi
echo "Tracing smoke test passed: collector -> tail sampling (error kept) -> Tempo -> Grafana."
