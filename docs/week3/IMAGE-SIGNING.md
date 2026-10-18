# Image signing and SBOMs (ADR 0012)

Every image the `deploy` workflow builds is signed with **cosign keyless** and gets a signed
**SPDX SBOM attestation**. Both are made by image digest and stored in ECR, next to the image. The
Kyverno policy `deploy/kyverno/image-signatures.yaml` (ADR 0013, audit only for now) checks exactly
the values below; CI keeps them equal (`deploy/tests/kyverno-check.sh`).

## Verification values

| What | Value |
|---|---|
| Certificate identity (exact) | `https://github.com/ngems1/Sec-GitOps-platform/.github/workflows/deploy.yml@refs/heads/main` |
| OIDC issuer (exact) | `https://token.actions.githubusercontent.com` |
| Sigstore | the public instance: Fulcio `https://fulcio.sigstore.dev`, Rekor `https://rekor.sigstore.dev` (cosign's built-in trust root) |
| Signature format | classic cosign: tag `sha256-<digest>.sig` in the image's repository |
| Attestation | predicate type `https://spdx.dev/Document` (cosign `--type spdxjson`), tag `sha256-<digest>.att` |
| Images | `<account>.dkr.ecr.<region>.amazonaws.com/<ecr_prefix>/<service>` (the 12 services and the loadgenerator) |

- **Why the identity is fixed:** the certificate names the workflow file and the ref.
  - Only `deploy.yml` on `main` can sign: the deploy role trusts `main` only, and the signing
    step refuses any other workflow ref.
  - Use the exact identity, not a regular expression. A regexp such as `.../deploy.yml@.*` would
    also accept a signature made from another branch.
- **The values change only when the repo or the workflow does:** a renamed repository, a moved
  `deploy.yml`, or signing from another branch or workflow. Change it in three places together:
  `SIGNER_IDENTITY` in `.github/workflows/deploy.yml`, this page, and the Kyverno policy.
- **Classic format, not the cosign v3 bundle:** the Kyverno policy reads the classic
  cosign signature and the `intoto` attestation (tags, not OCI 1.1 referrers). Why: ADR 0012.

## Check an image by hand

Any machine with cosign 3.1.3 and ECR read access (`aws ecr get-login-password | docker login ...`):

```bash
IMG=<account>.dkr.ecr.us-east-1.amazonaws.com/boutique/frontend
DIGEST=$(aws ecr describe-images --repository-name boutique/frontend \
  --image-ids imageTag=<12-char sha> --query 'imageDetails[0].imageDigest' --output text)
ID=https://github.com/ngems1/Sec-GitOps-platform/.github/workflows/deploy.yml@refs/heads/main
ISSUER=https://token.actions.githubusercontent.com

cosign verify --new-bundle-format=false \
  --certificate-identity "$ID" --certificate-oidc-issuer "$ISSUER" "$IMG@$DIGEST" > /dev/null
cosign verify-attestation --new-bundle-format=false --type spdxjson \
  --certificate-identity "$ID" --certificate-oidc-issuer "$ISSUER" "$IMG@$DIGEST" > /dev/null
```

- **`> /dev/null`:** the output is the signed payloads and the certificate. Nothing in them is
  secret, but there's no need to paste it anywhere.
- **The SBOM to read:** the `deploy` run > Artifacts > `sbom-<service>` (SPDX JSON, 30 days), or
  from the attestation:
  `cosign verify-attestation ... | jq -r .payload | base64 -d | jq .predicate`.
- **The ECR prefix:** `boutique` (Terraform `ecr_prefix`); the registry is the Terraform output
  `ecr_registry` (`<registry>/<prefix>`).

## In the workflow

`deploy` > job `build` (one per service), after the scan gate:

1. **Install cosign and Syft:** exact versions, checked by SHA-256.
2. **Image digest:** read from ECR for the commit's tag.
3. **SBOM:** Syft, SPDX JSON, uploaded as the workflow artifact `sbom-<service>`.
4. **Sign and attest:** `deploy/sign-image.sh sign`.
   - cosign gets the job's GitHub OIDC token (`id-token: write`, already granted for AWS).
   - Fulcio issues a 10-minute certificate, and Rekor logs the signature.
   - No key, no secret.
5. **Verify:** `deploy/sign-image.sh verify`, with the exact values above. A missing or wrong
   signature or attestation fails the job, and with it the deploy.

- **A re-run of the same build signs nothing new:** what already verifies is left as it is. ECR's
  immutable tags would refuse a second `.sig` or `.att` push.
- **An image built before this change is not signed** until a build of its commit runs the steps
  above. A redeploy with the `image_tag` input (the rollback button) skips the `build` job, so it
  signs nothing. Images from before ADR 0012 have no signature.
