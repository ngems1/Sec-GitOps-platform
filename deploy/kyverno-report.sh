#!/usr/bin/env bash
# Read-only (get). Kyverno's audit of the shop's image signatures in one namespace (ADR 0013):
# is Kyverno running, is the policy ready, and per pod the PolicyReport result of
# boutique-image-signatures (pass / fail / error). cluster-status runs it.
#
#   deploy/kyverno-report.sh <boutique-dev|boutique-prod>
#
# fail  = an image from our ECR has no valid signature or SBOM attestation from deploy.yml on main
# error = Kyverno could not check (registry access, Sigstore): not a verdict about the image
set -uo pipefail
NS=${1:?namespace}
POLICY=boutique-image-signatures

echo "\$ kubectl -n kyverno get pods"
kubectl -n kyverno get pods -o wide 2>&1 || true
echo
if ! kubectl get crd policyreports.wgpolicyk8s.io >/dev/null 2>&1; then
  echo "Kyverno is not installed (no PolicyReport CRD): the deploy workflow's job \"policies\" installs it."
  exit 0
fi
echo "\$ kubectl get imagevalidatingpolicy ${POLICY}"
kubectl get imagevalidatingpolicy "$POLICY" 2>&1 || true
echo

reports=$(kubectl -n "$NS" get policyreports.wgpolicyk8s.io -o json 2>/dev/null || echo '{"items":[]}')
results=$(jq -c --arg p "$POLICY" '[.items[] | .scope as $s | .results[]? | select(.policy == $p)
  | {result, pod: ($s.name // "?"), message: ((.message // "") | .[0:200])}]' <<< "$reports")
pods=$(kubectl -n "$NS" get pods --field-selector=status.phase=Running -o name 2>/dev/null | wc -l)
echo "Results of ${POLICY} in ${NS} (${pods} running pods; reports refresh at admission and every hour):"
jq -r 'group_by(.result) | map("  \(.[0].result): \(length)") | .[]' <<< "$results"
[ "$(jq length <<< "$results")" -gt 0 ] || echo "  none yet: the first background scan runs within an hour of the install"
echo
jq -r '.[] | select(.result != "pass") | "  \(.result)  \(.pod)  \(.message)"' <<< "$results" | sort | head -50
