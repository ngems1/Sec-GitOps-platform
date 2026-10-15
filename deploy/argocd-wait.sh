#!/usr/bin/env bash
# Waits until an Argo CD Application has synced a Git revision (or a later commit of
# main) and is Healthy. Fails on a failed sync or after the timeout (default 10 min).
#   argocd-wait.sh <application> <revision> [checkout of the repo, default gitops-repo]
# ARGOCD_WAIT_EXACT=1: only <revision> itself counts (a prod rollback moves the promotion
# branch back, so a later commit of main must not count as reached).
set -euo pipefail
app=${1:?application}
want=${2:?revision}
repo=${3:-gitops-repo}
timeout=${ARGOCD_WAIT_SECONDS:-600}
deadline=$(( $(date +%s) + timeout ))

# True when revision $1 is $want or (unless ARGOCD_WAIT_EXACT=1) a later commit of main.
reached() {
  [ "$1" = "$want" ] && return 0
  [ "${ARGOCD_WAIT_EXACT:-0}" = 1 ] && return 1
  [ -n "$1" ] || return 1
  git -C "$repo" fetch --quiet origin main 2>/dev/null || true
  git -C "$repo" merge-base --is-ancestor "$want" "$1" 2>/dev/null
}

while :; do
  # Look at Git now rather than at the next poll.
  kubectl -n argocd annotate application "$app" argocd.argoproj.io/refresh=normal --overwrite >/dev/null
  sleep 10
  status=$(kubectl -n argocd get application "$app" -o json)
  sync=$(jq -r '.status.sync.status // ""' <<<"$status")
  health=$(jq -r '.status.health.status // ""' <<<"$status")
  phase=$(jq -r '.status.operationState.phase // ""' <<<"$status")
  synced=$(jq -r '.status.operationState.syncResult.revision // ""' <<<"$status")
  echo "sync=${sync} health=${health} last sync=${phase:-none} at ${synced:0:12}"

  if reached "$synced"; then
    if [ "$phase" = Succeeded ] && [ "$sync" = Synced ] && [ "$health" = Healthy ]; then
      echo "${app}: Synced and Healthy at ${synced:0:12}"
      exit 0
    fi
    if [ "$phase" = Failed ] || [ "$phase" = Error ]; then
      echo "::error::${app}: sync ${phase}: $(jq -r '.status.operationState.message // ""' <<<"$status")"
      exit 1
    fi
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "::error::${app} is not Synced and Healthy at ${want:0:12} after ${timeout}s."
    jq -r '.status.conditions // [] | .[] | "\(.type): \(.message)"' <<<"$status"
    exit 1
  fi
done
