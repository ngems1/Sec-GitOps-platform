#!/usr/bin/env bash
# Waits until an Argo CD Application is Synced and Healthy at a Git revision (or a later
# commit of main). Fails on a failed sync, on Degraded health at that revision (an aborted
# Argo Rollouts canary), or after the timeout (ARGOCD_WAIT_SECONDS, default 10 min).
#   argocd-wait.sh <application> <revision> [checkout of the repo, default gitops-repo]
# ARGOCD_WAIT_EXACT=1: only <revision> itself counts (a prod rollback moves the promotion
# branch back, so a later commit of main must not count as reached).
#
# "At a revision" means status.sync.revision: the commit Argo CD last compared the cluster
# against. Not operationState.syncResult.revision (the last sync operation): a commit that
# does not change this Application's manifests (another environment's gitops file, a
# promotion with the same tag) starts no sync, so the last operation stays on an older
# commit while the Application is already Synced at the new one.
set -euo pipefail
app=${1:?application}
want=${2:?revision}
repo=${3:-gitops-repo}
timeout=${ARGOCD_WAIT_SECONDS:-600}
deadline=$(( $(date +%s) + timeout ))

# True when revision $1 is $want or (unless ARGOCD_WAIT_EXACT=1) a later commit of main.
# Needs main's history in $repo (the callers check out with fetch-depth: 0). A shallow clone
# is deepened first. History can only be missing, never invented, so a gap can make this
# answer "not reached" (the wait goes on, then times out), never "reached" by mistake;
# an unknown commit (exit 128) also counts as not reached.
reached() {
  [ "$1" = "$want" ] && return 0
  [ "${ARGOCD_WAIT_EXACT:-0}" = 1 ] && return 1
  [ -n "$1" ] || return 1
  git -C "$repo" fetch --quiet origin main 2>/dev/null || true
  if [ "$(git -C "$repo" rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
    git -C "$repo" fetch --quiet --unshallow origin main 2>/dev/null || true
  fi
  git -C "$repo" merge-base --is-ancestor "$want" "$1" 2>/dev/null
}

# The first look is a hard refresh (manifests generated again from Git, the target branch
# resolved again); later ones are normal refreshes, which also re-resolve the branch.
refresh=hard
while :; do
  kubectl -n argocd annotate application "$app" "argocd.argoproj.io/refresh=${refresh}" --overwrite >/dev/null
  refresh=normal
  sleep 10
  status=$(kubectl -n argocd get application "$app" -o json)
  sync=$(jq -r '.status.sync.status // ""' <<<"$status")
  health=$(jq -r '.status.health.status // ""' <<<"$status")
  compared=$(jq -r '.status.sync.revision // ""' <<<"$status")
  phase=$(jq -r '.status.operationState.phase // ""' <<<"$status")
  synced=$(jq -r '.status.operationState.syncResult.revision // ""' <<<"$status")
  echo "sync=${sync} health=${health} at ${compared:0:12} (last sync operation: ${phase:-none} at ${synced:0:12})"

  # A sync operation still running is never "done", whatever the compared revision says.
  if reached "$compared" && [ "$sync" = Synced ] && [ "$health" = Healthy ] && [ "$phase" != Running ]; then
    echo "${app}: Synced and Healthy at ${compared:0:12}"
    exit 0
  fi
  # A sync of the wanted revision (or a later one) that failed will not fix itself.
  if reached "$synced" && { [ "$phase" = Failed ] || [ "$phase" = Error ]; }; then
    echo "::error::${app}: sync ${phase} at ${synced:0:12}: $(jq -r '.status.operationState.message // ""' <<<"$status")"
    exit 1
  fi
  # Degraded at the wanted revision, twice in a row (not a passing blip): e.g. an Argo
  # Rollouts canary aborted by its analysis (traffic is already back on stable). A running
  # canary is Progressing or Suspended (a timed pause), so the wait simply goes on.
  if reached "$compared" && [ "$sync" = Synced ] && [ "$health" = Degraded ] && [ "$phase" != Running ]; then
    degraded=$(( ${degraded:-0} + 1 ))
    if [ "$degraded" -ge 2 ]; then
      echo "::error::${app} is Degraded at ${compared:0:12} (for an Argo Rollouts canary: aborted, traffic back on stable)."
      jq -r '.status.resources // [] | .[] | select(.health.status == "Degraded") | "\(.kind)/\(.name): \(.health.message // "")"' <<<"$status"
      exit 1
    fi
  else
    degraded=0
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "::error::${app} is not Synced and Healthy at ${want:0:12} after ${timeout}s (Argo CD compared ${compared:0:12})."
    jq -r '.status.conditions // [] | .[] | "\(.type): \(.message)"' <<<"$status"
    exit 1
  fi
done
