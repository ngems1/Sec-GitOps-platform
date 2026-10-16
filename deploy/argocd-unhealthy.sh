#!/usr/bin/env bash
# Why an Argo CD Application is not Healthy (read-only):
#   argocd-unhealthy.sh <application>
# - the Application's health status and message
# - every resource whose health is not Healthy (Degraded, Progressing, Suspended, Missing,
#   Unknown): kind, namespace/name, status, message
# - since Argo CD 3, per-resource health is only in the Application when
#   controller.resource.health.persist is true (deploy/argocd/values.yaml sets it). Without it
#   the list is empty while the Application is Degraded, so the usual suspects are always
#   checked directly too: HorizontalPodAutoscaler conditions that are False, Deployments not
#   available or past their progress deadline, Rollouts not Healthy.
# Called by argocd-wait.sh (failures, timeout) and deploy/rollouts-report.sh. No Secret is read.
set -u
app=${1:?application}

if ! status=$(kubectl -n argocd get application "$app" -o json 2>&1); then
  echo "  no Application ${app}: ${status}"
  exit 0
fi
ns=$(jq -r '.spec.destination.namespace // ""' <<<"$status")

jq -r '
  "  Application \(.metadata.name): health=\(.status.health.status // "?")" +
    (if .status.health.message then " (\(.status.health.message))" else "" end),
  ([.status.resources // [] | .[] | select((.health.status // "") != "" and .health.status != "Healthy")]
    | if length == 0 then empty
      else .[] | "  \(.kind) \(.namespace // "-")/\(.name): \(.health.status) \(.health.message // "")" end),
  (if ([.status.resources // [] | .[] | select(.health.status)] | length) == 0
   then "  (no per-resource health in the Application: Argo CD 3 keeps it only with controller.resource.health.persist=true)"
   else empty end)' <<<"$status"

[ -n "$ns" ] || exit 0
echo "  Direct checks in ${ns}:"
kubectl -n "$ns" get hpa -o json 2>/dev/null | jq -r '
  .items[] | . as $h | (.status.conditions // [])[] | select(.status == "False")
  | "    HorizontalPodAutoscaler \($h.metadata.name): \(.type)=False \(.reason // ""): \(.message // "")"'
kubectl -n "$ns" get deploy -o json 2>/dev/null | jq -r '
  .items[] | . as $d | (.status.conditions // [])[]
  | select((.type == "Progressing" and (.status == "False" or .reason == "ProgressDeadlineExceeded"))
        or (.type == "Available" and .status == "False" and (($d.spec.replicas // 1) > 0)))
  | "    Deployment \($d.metadata.name) (replicas \($d.spec.replicas // "-")): \(.type)=\(.status) \(.reason // ""): \(.message // "")"'
if [ -n "$(kubectl get crd rollouts.argoproj.io --ignore-not-found -o name 2>/dev/null)" ]; then
  kubectl -n "$ns" get rollouts -o json 2>/dev/null | jq -r '
    .items[] | select((.status.phase // "") != "Healthy")
    | "    Rollout \(.metadata.name): \(.status.phase // "?") aborted=\(.status.abort // false) \(.status.message // "")"'
fi
echo "  (end of direct checks)"
