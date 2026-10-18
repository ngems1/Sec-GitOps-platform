#!/usr/bin/env bash
# Signs an image and attests its SBOM with cosign keyless, then verifies both (ADR 0012).
#
#   deploy/sign-image.sh sign   <registry/repo@sha256:...> <sbom.spdx.json>
#   deploy/sign-image.sh verify <registry/repo@sha256:...>
#   deploy/sign-image.sh status <registry/repo@sha256:...>   exit 0 when already signed AND attested
#                                                            by the expected identity (quiet; rollbacks)
#
# Needs: cosign on PATH, registry credentials (docker login), and in GitHub Actions the
# id-token: write permission (cosign asks GitHub for an OIDC token, Fulcio turns it into a
# short-lived certificate, Rekor logs the signature). No key, no secret.
#   SIGNER_IDENTITY  the certificate identity to expect (docs/week3/IMAGE-SIGNING.md)
#   SIGNER_ISSUER    the OIDC issuer to expect
#
# By digest only: a tag can be moved, a digest cannot. Classic cosign storage (the
# sha256-<digest>.sig and .att tags): ECR tags are immutable, and the newer bundle format writes
# every signature and attestation of an image under one sha256-<digest> tag when the registry
# has no referrers API, so the second push would be refused. Each tag is pushed once: what
# already verifies is not signed again (a re-run of the same build changes nothing).
# Nothing secret is printed: cosign's stdout (payloads, certificates) goes to /dev/null.
set -euo pipefail

mode=${1:?usage: sign-image.sh sign|verify|status <image@sha256:digest> [sbom]}
ref=${2:?image reference by digest}
: "${SIGNER_IDENTITY:?}" "${SIGNER_ISSUER:?}"

if ! [[ "$ref" =~ ^[^@[:space:]]+@sha256:[0-9a-f]{64}$ ]]; then
  echo "::error::${ref}: sign and verify by digest only (<repo>@sha256:<64 hex>), never by tag"
  exit 1
fi

store=(--new-bundle-format=false)            # classic .sig / .att tags (see above)
sign_flags=("${store[@]}" --use-signing-config=false --yes)
expect=(--certificate-identity "$SIGNER_IDENTITY" --certificate-oidc-issuer "$SIGNER_ISSUER")

signed()   { cosign verify "${store[@]}" "${expect[@]}" "$ref" >/dev/null 2>&1; }
attested() { cosign verify-attestation "${store[@]}" "${expect[@]}" --type spdxjson "$ref" >/dev/null 2>&1; }

case "$mode" in
  sign)
    sbom=${3:?SBOM file (SPDX JSON)}
    [ -s "$sbom" ] || { echo "::error::${sbom}: empty or missing SBOM"; exit 1; }
    if signed; then
      echo "Signature already in place for ${ref##*@} (re-run): not signed again."
    else
      cosign sign "${sign_flags[@]}" "$ref" >/dev/null
      echo "Signed ${ref##*@}."
    fi
    if attested; then
      echo "SBOM attestation already in place for ${ref##*@} (re-run): not attested again."
    else
      cosign attest "${sign_flags[@]}" --type spdxjson --predicate "$sbom" "$ref" >/dev/null
      echo "SBOM attested (SPDX JSON) for ${ref##*@}."
    fi
    ;;
  verify)
    # The same check Kyverno will make: exact identity and issuer. Fails the job when either is
    # missing or was made by anything else.
    if ! cosign verify "${store[@]}" "${expect[@]}" "$ref" >/dev/null; then
      echo "::error::${ref}: no valid signature from ${SIGNER_IDENTITY}"
      exit 1
    fi
    if ! cosign verify-attestation "${store[@]}" "${expect[@]}" --type spdxjson "$ref" >/dev/null; then
      echo "::error::${ref}: no valid SPDX SBOM attestation from ${SIGNER_IDENTITY}"
      exit 1
    fi
    echo "Verified: signature and SPDX SBOM attestation of ${ref##*@} by ${SIGNER_IDENTITY}."
    ;;
  status)
    # Nothing to do for this image? Both checks, nothing printed. Not a substitute for verify.
    signed && attested
    ;;
  *)
    echo "usage: sign-image.sh sign|verify|status <image@sha256:digest> [sbom]"; exit 2 ;;
esac
