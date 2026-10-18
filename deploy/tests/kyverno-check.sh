#!/usr/bin/env bash
# CI check: Kyverno stays audit-only and checks exactly what the deploy workflow signs (ADR 0013).
#
#   deploy/tests/kyverno-check.sh [policy] [kyverno values]
#   default: deploy/kyverno/image-signatures.yaml deploy/kyverno/values.yaml
#
# Audit only: no Deny or Enforce anywhere, fail-open webhooks, no digest mutation, webhooks limited
# to boutique-dev and boutique-prod. The identity, issuer and SBOM type equal the signing ones
# (SIGNER_IDENTITY / SIGNER_ISSUER in deploy.yml, docs/week3/IMAGE-SIGNING.md, ADR 0012), and
# the images checked are exactly the shop's ECR repositories.
set -euo pipefail

cd "$(dirname "$0")/../.."
policy=${1:-deploy/kyverno/image-signatures.yaml}
values=${2:-deploy/kyverno/values.yaml}
fail=0
err() { echo "::error file=$1::$2"; fail=1; }
p() { yq -o=json -I=0 "$1" "$policy"; }

# Never blocking (this phase).
if grep -hvE '^\s*#' "$policy" "$values" | grep -qE '\b(Deny|Enforce|enforce)\b'; then
  err "$policy" "Deny/Enforce found: this phase is audit only (ADR 0013)"
fi
[ "$(p '.spec.validationActions')" = '["Audit"]' ] || err "$policy" "validationActions must be exactly [Audit]"
[ "$(p '.spec.failurePolicy')" = '"Ignore"' ] || err "$policy" "failurePolicy must be Ignore (fail open)"
[ "$(p '.spec.validationConfigurations.mutateDigest')" = false ] || err "$policy" "mutateDigest must be false (pods are never changed)"
[ "$(yq '.features.forceFailurePolicyIgnore.enabled' "$values")" = true ] \
  || err "$values" "features.forceFailurePolicyIgnore.enabled must be true (every Kyverno webhook fails open)"
for f in "$policy" "$values"; do
  case "$f" in
    "$policy") ns=$(p '[.spec.matchConstraints.namespaceSelector.matchExpressions[] | select(.key == "kubernetes.io/metadata.name" and .operator == "In") | .values[]] | sort') ;;
    *) ns=$(yq -o=json -I=0 '[.config.webhooks.namespaceSelector.matchExpressions[] | select(.key == "kubernetes.io/metadata.name" and .operator == "In") | .values[]] | sort' "$f") ;;
  esac
  [ "$ns" = '["boutique-dev","boutique-prod"]' ] || err "$f" "namespaces must be exactly boutique-dev and boutique-prod (got ${ns})"
done

# What is checked: the signing identity, issuer and SBOM type (one source: deploy.yml).
want_id=$(yq '.env.SIGNER_IDENTITY' .github/workflows/deploy.yml)
want_iss=$(yq '.env.SIGNER_ISSUER' .github/workflows/deploy.yml)
[ "$(p '[.spec.attestors[].cosign.keyless.identities[]] | length')" = 1 ] || err "$policy" "exactly one keyless identity"
[ "$(p '.spec.attestors[0].cosign.keyless.identities[0].subject')" = "\"${want_id}\"" ] \
  || err "$policy" "subject must be SIGNER_IDENTITY of deploy.yml (${want_id}), exact, no regexp"
[ "$(p '.spec.attestors[0].cosign.keyless.identities[0].issuer')" = "\"${want_iss}\"" ] \
  || err "$policy" "issuer must be SIGNER_ISSUER of deploy.yml (${want_iss})"
[ "$(p '.spec.attestors[0].cosign.keyless.identities[0] | has("subjectRegExp") or has("issuerRegExp")')" = false ] \
  || err "$policy" "no subjectRegExp/issuerRegExp: the identity is exact (IMAGE-SIGNING.md)"
grep -qF "$want_id" docs/week3/IMAGE-SIGNING.md || err docs/week3/IMAGE-SIGNING.md "does not show the signing identity ${want_id}"
[ "$(p '[.spec.attestations[] | select(.name == "sbom") | .intoto.type][0]')" = '"https://spdx.dev/Document"' ] \
  || err "$policy" "attestation sbom must be intoto type https://spdx.dev/Document (cosign --type spdxjson)"

# Which images: our ECR repositories only, the same prefix in the match and in the filter.
# shellcheck disable=SC2016 # the literal placeholder ${ECR_REGISTRY} (envsubst at install)
{ [ "$(p '.spec.matchImageReferences')" = '[{"glob":"${ECR_REGISTRY}/*"}]' ] \
  || err "$policy" 'matchImageReferences must be exactly [{glob: "${ECR_REGISTRY}/*"}]'; }
p '.spec.variables[] | select(.name == "ours") | .expression' | grep -qF "startsWith('\${ECR_REGISTRY}/')" \
  || err "$policy" "variable ours must keep only images under \${ECR_REGISTRY}/ (third-party images are not ours to check)"
[ "$(p '[.spec.validations[].expression] | map(test("variables\\.ours\\.all")) | all')" = true ] \
  || err "$policy" "every validation must run on variables.ours only"
[ "$(p '.spec.credentials.providers')" = '["amazon"]' ] || err "$policy" "credentials.providers must be [amazon] (ECR)"

# Pinned: an exact chart version, no "latest" image.
v=$(yq '.jobs.policies.env.KYVERNO_CHART_VERSION' .github/workflows/deploy.yml)
[[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || err .github/workflows/deploy.yml "KYVERNO_CHART_VERSION must be an exact version, got '${v}'"

[ "$fail" -eq 0 ] || exit 1
echo "Kyverno: audit only, fail open, ${want_id} on the shop's ECR images, chart ${v} (${policy}, ${values})."
