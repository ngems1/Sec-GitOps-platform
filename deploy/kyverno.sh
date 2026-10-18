#!/usr/bin/env bash
# Installs or updates Kyverno in namespace "kyverno" and its image-signature policy (ADR 0013).
# AUDIT ONLY: the policy reports unsigned images of the shop's ECR repositories in boutique-dev
# and boutique-prod; it never blocks or changes a pod.
# Needs kubectl + helm on the cluster and:
#   KYVERNO_CHART_VERSION  exact chart version (deploy.yml)
#   ECR_REGISTRY           Terraform output ecr_registry: <account>.dkr.ecr.<region>.amazonaws.com/boutique
set -euo pipefail
: "${KYVERNO_CHART_VERSION:?}" "${ECR_REGISTRY:?}"
NS=kyverno
POLICY=deploy/kyverno/image-signatures.yaml

if ! [[ "$ECR_REGISTRY" =~ ^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/[a-z0-9._-]+$ ]]; then
  echo "::error::ECR_REGISTRY is not <account>.dkr.ecr.<region>.amazonaws.com/<prefix>"
  exit 1
fi

if ! helm upgrade --install kyverno kyverno \
  --repo https://kyverno.github.io/kyverno --version "$KYVERNO_CHART_VERSION" \
  --namespace "$NS" --create-namespace -f deploy/kyverno/values.yaml \
  --wait=watcher --timeout 10m; then
  bash deploy/diagnose.sh "$NS"
  exit 1
fi
echo "kyverno: $(helm -n "$NS" list -f '^kyverno$' -o json | jq -r '.[0].chart')"

# The policy, with this account's registry. Refused if it could ever block or change a pod:
# Audit is the only action, the webhook fails open, no digest mutation (CI checks the same).
# shellcheck disable=SC2016 # ${ECR_REGISTRY} is envsubst's, not the shell's
policy=$(envsubst '${ECR_REGISTRY}' < "$POLICY")
check=$(yq -o=json -I=0 '[(.spec.validationActions | length) == 1 and .spec.validationActions[0] == "Audit",
  .spec.failurePolicy == "Ignore", .spec.validationConfigurations.mutateDigest == false]' <<< "$policy")
if [ "$check" != "[true,true,true]" ]; then
  echo "::error::${POLICY} must be Audit only, failurePolicy Ignore and mutateDigest false (ADR 0013)"
  exit 1
fi
kubectl apply -f - <<< "$policy"

# Ready once Kyverno has compiled it and configured its webhook.
for _ in $(seq 1 30); do
  ready=$(kubectl get imagevalidatingpolicy boutique-image-signatures -o jsonpath='{.status.conditionStatus.ready}' 2>/dev/null || true)
  [ "$ready" = true ] && break
  sleep 5
done
kubectl get imagevalidatingpolicy boutique-image-signatures
if [ "$ready" != true ]; then
  echo "::warning::Policy boutique-image-signatures is not ready yet (audit only, nothing is blocked):"
  kubectl get imagevalidatingpolicy boutique-image-signatures -o jsonpath='{range .status.conditionStatus.conditions[*]}{.type}: {.status} {.message}{"\n"}{end}' || true
fi
kubectl -n "$NS" get pods -o wide
