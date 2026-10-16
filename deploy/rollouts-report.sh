#!/usr/bin/env bash
# Read-only report of the Argo Rollouts canary in a namespace (ADR 0008):
#   rollouts-report.sh <namespace>
# - every Rollout: phase, abort / status message, step, stable and canary pod-template hash
# - every AnalysisRun (newest first): phase, message, and per metric its phase, counts and
#   last measured values (what the analysis actually saw)
# - the Prometheus address each AnalysisTemplate queries, and the Prometheus Services that exist
# - the Argo CD Application's health and every resource that is not Healthy
# - the frontend pods with their pod-template hash (which is canary, which is stable)
# - Rollout / AnalysisRun events
# - the last 30 lines of the loadgenerator (the canary's traffic)
# Only get / logs: nothing is changed. No Secret is read. Called by deploy-env.yml when a
# deploy fails (before the rollback resets the Rollout) and by cluster-status.yml.
set -u
ns="${1:?namespace}"

if [ -z "$(kubectl get crd rollouts.argoproj.io --ignore-not-found -o name 2>/dev/null)" ]; then
  echo "Argo Rollouts is not installed (no rollouts.argoproj.io CRD)."
  exit 0
fi

echo "=== ${ns}: Rollouts ==="
if ! rollouts=$(kubectl -n "$ns" get rollouts -o json 2>&1); then
  echo "$rollouts"
else
  jq -r '
    if (.items | length) == 0 then "no Rollout" else
    .items[] |
      "\(.metadata.name): phase=\(.status.phase // "?") aborted=\(.status.abort // false) step=\(.status.currentStepIndex // "-")/\(.spec.strategy.canary.steps // [] | length)" +
      " stable=\(.status.stableRS // "-") canary=\(.status.currentPodHash // "-")" +
      " replicas=\(.status.replicas // 0) ready=\(.status.readyReplicas // 0)" +
      "\n  message: \(.status.message // "-")" +
      ((.status.conditions // []) | map("\n  condition \(.type)=\(.status) (\(.reason // "")): \(.message // "")") | join(""))
    end' <<<"$rollouts"
fi

echo
echo "=== ${ns}: AnalysisRuns (newest first, last 5 measurements per metric) ==="
if ! runs=$(kubectl -n "$ns" get analysisruns -o json 2>&1); then
  echo "$runs"
else
  jq -r '
    if (.items | length) == 0 then "no AnalysisRun" else
    .items | sort_by(.metadata.creationTimestamp) | reverse | .[] |
      "\(.metadata.name) (created \(.metadata.creationTimestamp)): phase=\(.status.phase // "?")" +
      (if .status.message then "\n  message: \(.status.message)" else "" end) +
      ((.status.metricResults // []) | map(
        "\n  metric \(.name): phase=\(.phase // "?") successful=\(.successful // 0) failed=\(.failed // 0) inconclusive=\(.inconclusive // 0) error=\(.error // 0)" +
        (if .message then " message: \(.message)" else "" end) +
        ((.measurements // [])[-5:] | map("\n    \(.startedAt // "-") \(.phase // "?") value=\(.value // "-")" + (if .message then " (\(.message))" else "" end)) | join(""))
      ) | join(""))
    end' <<<"$runs"
fi

echo
echo "=== Prometheus: the analysis address and the Prometheus Services in the cluster ==="
kubectl -n "$ns" get analysistemplates -o json 2>/dev/null \
  | jq -r '.items[] | .metadata.name as $t | .spec.metrics[] | select(.provider.prometheus)
      | "\($t)/\(.name): \(.provider.prometheus.address)"' | sort -u
kubectl get svc -A -o json 2>/dev/null | jq -r '
  [.items[] | select(.metadata.name | test("prometheus"))
    | "\(.metadata.namespace)/\(.metadata.name) ports \([.spec.ports[] | "\(.port)/\(.name // "-")"] | join(","))"]
  | if length == 0 then "no Service named *prometheus* in any namespace (is monitoring installed?)" else .[] end'

echo
# The Application has the namespace's name (boutique-dev, boutique-prod). Which of its
# resources make it not Healthy (e.g. Degraded during a normal canary pause).
echo "=== Argo CD Application ${ns}: health and the resources that are not Healthy ==="
if ! appjson=$(kubectl -n argocd get application "$ns" -o json 2>&1); then
  echo "no Application ${ns} (deployed by Helm?)"
else
  jq -r '
    "health=\(.status.health.status // "?") \(.status.health.message // "") sync=\(.status.sync.status // "?") at \(.status.sync.revision // "-" | .[0:12])",
    ([.status.resources // [] | .[] | select(.health.status != null and .health.status != "Healthy")]
      | if length == 0 then "  every resource with a health status is Healthy"
        else .[] | "  \(.kind)/\(.name): \(.health.status) \(.health.message // "")" end)' <<<"$appjson"
fi

echo
echo "=== ${ns}: frontend pods (rollouts-pod-template-hash = canary or stable) ==="
kubectl -n "$ns" get pods -l app=frontend -L rollouts-pod-template-hash -o wide 2>&1

echo
echo "=== ${ns}: Rollout and AnalysisRun events ==="
kubectl -n "$ns" get events --sort-by=.lastTimestamp 2>&1 \
  | awk 'NR == 1 || /Rollout|AnalysisRun/' | tail -25

echo
echo "=== ${ns}: loadgenerator (last 30 lines) ==="
if [ -n "$(kubectl -n "$ns" get deploy loadgenerator --ignore-not-found -o name 2>/dev/null)" ]; then
  kubectl -n "$ns" get deploy loadgenerator \
    -o jsonpath='image={.spec.template.spec.containers[0].image}{"\n"}' 2>&1
  kubectl -n "$ns" logs deploy/loadgenerator --tail=30 2>&1
else
  echo "no loadgenerator Deployment"
fi
