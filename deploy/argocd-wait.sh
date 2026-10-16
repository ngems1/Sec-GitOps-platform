#!/usr/bin/env bash
# Waits until an Argo CD Application is Synced and Healthy at a Git revision (or a later
# commit of main). Fails on a failed sync, on a failed Argo Rollouts canary, on Degraded
# health at that revision when no canary is running, or after the timeout
# (ARGOCD_WAIT_SECONDS, default 10 min).
#   argocd-wait.sh <application> <revision> [checkout of the repo, default gitops-repo]
# ARGOCD_WAIT_EXACT=1: only <revision> itself counts (a prod rollback moves the promotion
# branch back, so a later commit of main must not count as reached).
#
# "At a revision" means status.sync.revision: the commit Argo CD last compared the cluster
# against. Not operationState.syncResult.revision (the last sync operation): a commit that
# does not change this Application's manifests (another environment's gitops file, a
# promotion with the same tag) starts no sync, so the last operation stays on an older
# commit while the Application is already Synced at the new one.
#
# Canary (Argo Rollouts, ADR 0008): once Argo CD has applied the revision, a Rollout of the
# Application's namespace decides while its canary runs, not the Application's health
# (which other resources can turn Degraded or Progressing during a normal pause):
#   success  every Rollout Healthy, its canary promoted (current pod hash = stable)
#   failure  a Rollout aborted, a Rollout Degraded, or a Failed/Error AnalysisRun of the
#            canary's pod hash
#   wait     Paused or Progressing with the analysis Running (or not started yet)
# Then the Application must be Healthy as before.
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

# The Application's resources that are not Healthy (kind/name: health, message).
unhealthy() {
  jq -r '.status.resources // [] | .[] | select(.health.status != null and .health.status != "Healthy")
    | "  \(.kind)/\(.name): \(.health.status) \(.health.message // "")"' <<<"$status"
}

# State of the Rollouts in namespace $1, as "<state> <detail>": none (no Rollout or no
# Argo Rollouts), done, wait, or failed. One line per call.
rollouts_state() {
  local ns=$1 rollouts runs
  [ -n "$(kubectl get crd rollouts.argoproj.io --ignore-not-found -o name 2>/dev/null)" ] || { echo "none"; return; }
  rollouts=$(kubectl -n "$ns" get rollouts -o json)
  [ "$(jq '.items | length' <<<"$rollouts")" -gt 0 ] || { echo "none"; return; }
  runs=$(kubectl -n "$ns" get analysisruns -o json)
  jq -r --argjson runs "$runs" '
    [ .items[] |
      (.metadata.name) as $name |
      (.status.currentPodHash // "") as $hash |
      # The newest AnalysisRun of this canary (names are <rollout>-<pod hash>-<revision>):
      # an older run of the same hash (a redeploy of a tag that failed before) does not count.
      ([$runs.items[] | select(.metadata.name | startswith($name + "-" + $hash + "-"))]
        | sort_by(.metadata.creationTimestamp) | last) as $run |
      ((.status.observedGeneration // "") | tostring) as $observed |
      if ($observed | test("^[0-9]+$")) and $observed != (.metadata.generation | tostring) then
        "wait \($name): new spec not observed yet"
      elif .status.abort == true then
        "failed \($name): aborted: \(.status.message // "")"
      elif $run != null and ($run.status.phase == "Failed" or $run.status.phase == "Error") then
        "failed \($name): AnalysisRun \($run.metadata.name) \($run.status.phase): \($run.status.message // "")"
      elif .status.phase == "Degraded" then
        "failed \($name): Degraded: \(.status.message // "")"
      elif .status.phase == "Healthy" and $hash == (.status.stableRS // "") then
        "done \($name): Healthy at \($hash)"
      else
        "wait \($name): \(.status.phase // "?") step \(.status.currentStepIndex // "-")/\(.spec.strategy.canary.steps // [] | length) canary \($hash) stable \(.status.stableRS // "-") \(.status.message // "")"
      end
    ] |
    (map(select(startswith("failed")))[0] // map(select(startswith("wait")))[0] // map(select(startswith("done")))[0])
  ' <<<"$rollouts"
}

# The first look is a hard refresh (manifests generated again from Git, the target branch
# resolved again); later ones are normal refreshes, which also re-resolve the branch.
refresh=hard
degraded=0
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
  ns=$(jq -r '.spec.destination.namespace // ""' <<<"$status")
  echo "sync=${sync} health=${health} at ${compared:0:12} (last sync operation: ${phase:-none} at ${synced:0:12})"

  # A sync of the wanted revision (or a later one) that failed will not fix itself.
  if reached "$synced" && { [ "$phase" = Failed ] || [ "$phase" = Error ]; }; then
    echo "::error::${app}: sync ${phase} at ${synced:0:12}: $(jq -r '.status.operationState.message // ""' <<<"$status")"
    exit 1
  fi

  # Argo CD has applied the wanted revision (a sync operation still running is never done).
  applied=false
  if reached "$compared" && [ "$sync" = Synced ] && [ "$phase" != Running ]; then applied=true; fi

  rollout="none"
  [ "$applied" = false ] || [ -z "$ns" ] || rollout=$(rollouts_state "$ns")
  [ "$rollout" = none ] || echo "  rollout: ${rollout}"

  case "$rollout" in
    failed*)
      echo "::error::${app}: canary failed at ${compared:0:12}: ${rollout#failed }"
      unhealthy
      exit 1
      ;;
    wait*)
      # Canary running: the Application's health is not the judge now (see the header).
      degraded=0
      ;;
    *)
      if [ "$applied" = true ] && [ "$health" = Healthy ]; then
        echo "${app}: Synced and Healthy at ${compared:0:12}"
        exit 0
      fi
      # Degraded at the wanted revision with no canary running, twice in a row (not a
      # passing blip).
      if [ "$applied" = true ] && [ "$health" = Degraded ]; then
        degraded=$(( degraded + 1 ))
        if [ "$degraded" -ge 2 ]; then
          echo "::error::${app} is Degraded at ${compared:0:12} (no canary running). Not Healthy:"
          unhealthy
          exit 1
        fi
      else
        degraded=0
      fi
      ;;
  esac

  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "::error::${app} is not Synced and Healthy at ${want:0:12} after ${timeout}s (Argo CD compared ${compared:0:12}${rollout:+; rollout: ${rollout}})."
    jq -r '.status.conditions // [] | .[] | "\(.type): \(.message)"' <<<"$status"
    unhealthy
    exit 1
  fi
done
