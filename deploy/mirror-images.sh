#!/usr/bin/env bash
# Mirrors the images of the GKE portable profile from ECR into Artifact Registry (ADR 0014,
# decision 5), by digest, with their cosign signature and SBOM attestation.
#
#   deploy/mirror-images.sh <ecr-registry> <tag> <ar-registry>
#     ecr-registry  <account>.dkr.ecr.<region>.amazonaws.com/<prefix>   (images.repository of prod)
#     tag           the image tag prod runs (12-character commit SHA)
#     ar-registry   <region>-docker.pkg.dev/<project>/boutique
#
# Signed images (the 10 services and the loadgenerator), each one:
#   1. the digest ECR holds for <tag>, verified there first (deploy/sign-image.sh verify): only
#      what deploy.yml signed and verified is copied;
#   2. `cosign copy` of the image, its .sig and its .att (classic storage, like sign-image.sh) to
#      <ar-registry>/<service>:<tag>. Same digest, so the signature stays valid;
#   3. the tag in Artifact Registry must name that same digest (a re-run copies nothing, and
#      cosign copy does not fail when the tag already holds another image), then verified again
#      there, with the same identity and issuer.
# Public images (unsigned): redis and busybox at the digests the chart pins
# (helm-chart/templates/redis.yaml, loadgenerator.yaml), copied with crane, digest checked.
#
# Needs: cosign, crane, registry logins for both sides, SIGNER_IDENTITY / SIGNER_ISSUER.
# The logs are public: no digest is printed, and errors are shown with digests removed (the
# workflow also masks the account and project IDs).
set -uo pipefail

src=${1:?usage: mirror-images.sh <ecr-registry> <tag> <ar-registry>}
tag=${2:?image tag}
dst=${3:?Artifact Registry path}
: "${SIGNER_IDENTITY:?}" "${SIGNER_ISSUER:?}"
here=$(cd "$(dirname "$0")" && pwd)

[[ "$tag" =~ ^[0-9a-f]{12}$ ]] || { echo "::error::image tag must be a 12-character commit SHA"; exit 1; }

# The GKE portable profile (ADR 0014, decision 1), by ECR repository name.
signed_images=(adservice cartservice checkoutservice currencyservice emailservice frontend
               paymentservice productcatalogservice recommendationservice shippingservice
               loadgenerator)

redact() { sed -E 's/sha256[:-][0-9a-f]{64}/sha256:<digest>/g'; }
log=$(mktemp)
trap 'rm -f "$log"' EXIT
# Runs a command with its output kept out of the log; on failure shows it, without digests.
quiet() { "$@" > "$log" 2>&1 || { redact < "$log" | tail -15 >&2; return 1; }; }
digest_of() { crane digest "$1" 2>/dev/null; }
is_digest() { [[ "$1" =~ ^sha256:[0-9a-f]{64}$ ]]; }

failed=0
summary=("| Image | Result |" "|---|---|")
result() { summary+=("| $1 | $2 |"); echo "$1: $2"; }
fail() { result "$1" "FAILED: $2"; echo "::error::$1: $2"; failed=1; }

# Before a copy: a tag that already exists in Artifact Registry (immutable) must hold this digest.
tag_free_or_same() {
  local have; have=$(digest_of "$1") || return 0 # not there yet
  [ "$have" = "$2" ]
}

for svc in "${signed_images[@]}"; do
  d=$(digest_of "${src}/${svc}:${tag}") || true
  is_digest "$d" || { fail "$svc" "no image ${svc}:${tag} in ECR"; continue; }

  quiet bash "$here/sign-image.sh" verify "${src}/${svc}@${d}" \
    || { fail "$svc" "not signed and attested by the deploy workflow in ECR: not copied"; continue; }
  tag_free_or_same "${dst}/${svc}:${tag}" "$d" \
    || { fail "$svc" "${svc}:${tag} in Artifact Registry is another image (tags are immutable)"; continue; }

  quiet cosign copy "${src}/${svc}@${d}" "${dst}/${svc}:${tag}" \
    || { fail "$svc" "cosign copy failed"; continue; }

  [ "$(digest_of "${dst}/${svc}:${tag}")" = "$d" ] \
    || { fail "$svc" "the copy in Artifact Registry has another digest"; continue; }
  quiet bash "$here/sign-image.sh" verify "${dst}/${svc}@${d}" \
    || { fail "$svc" "copied, but the signature or the SBOM attestation does not verify in Artifact Registry"; continue; }
  result "$svc" "copied, same digest, signature and SBOM attestation verified"
done

# Public images: the exact references the chart pins (name:tag@sha256:...).
chart="${here}/../helm-chart/templates"
# busybox's repository is a value (loadGenerator.busybox.repository): its tag and digest are not.
public_images=(
  "$(grep -oE 'redis:alpine@sha256:[0-9a-f]{64}' "${chart}/redis.yaml" | head -1)"
  "busybox$(grep -oE '\}\}:latest@sha256:[0-9a-f]{64}' "${chart}/loadgenerator.yaml" | head -1 | cut -c3-)"
)
for ref in "${public_images[@]}"; do
  [[ "$ref" =~ ^[a-z]+:[a-z0-9.-]+@sha256:[0-9a-f]{64}$ ]] || { fail "public image" "pinned reference not found in the chart"; continue; }
  name=${ref%%@*} d=${ref#*@}          # redis:alpine, sha256:...
  tag_free_or_same "${dst}/${name}" "$d" \
    || { fail "$name" "${name} in Artifact Registry is another image (tags are immutable)"; continue; }
  quiet crane copy "docker.io/library/${ref}" "${dst}/${name}" \
    || { fail "$name" "crane copy from Docker Hub failed"; continue; }
  [ "$(digest_of "${dst}/${name}")" = "$d" ] \
    || { fail "$name" "the copy in Artifact Registry has another digest"; continue; }
  result "$name" "copied from Docker Hub at the chart's pinned digest (unsigned upstream)"
done

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { echo "### Images mirrored to Artifact Registry (tag ${tag})"; echo; printf '%s\n' "${summary[@]}"; } >> "$GITHUB_STEP_SUMMARY"
fi
exit "$failed"
