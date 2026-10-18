# 0012: Image signing and SBOMs (cosign keyless, SPDX attestations)

Status: accepted. Date: 2026-10-18. Phase 5, PR 1 of 3 (PR 2: Kyverno verifies; PR 3: enforce).

## Context

- **Builds:** the `deploy` workflow builds 13 images (the 12 services and the loadgenerator) in
  one matrix job `build`, on every push to `main` that touches `src/`, `helm-chart/`, `db/`,
  `deploy/`, `monitoring/` or the deploy workflows. It builds all 13, not only the changed ones.
- **Registry:** each image goes to ECR `boutique/<service>` with the 12-character commit SHA as
  its tag.
  - The tags are `IMMUTABLE`, every image is scanned on push, and a CRITICAL finding stops the
    deploy.
  - A lifecycle rule keeps the 20 most recent images per repository.
- **Today nothing proves an image in the cluster came from this repo's pipeline.** Anyone with
  ECR push rights could put an image there, and nothing lists what is inside one.
- **Credentials:** the job already runs with GitHub OIDC (`id-token: write`, for the AWS deploy
  role). That role is AdministratorAccess under a boundary that allows `ecr:*`.

## Decision

1. **Keyless signing with the public Sigstore instance.**
   - cosign gets the job's GitHub OIDC token. Fulcio issues a short-lived certificate for the
     workflow identity, and Rekor records the signature.
   - No signing key exists, so none can leak, be rotated or be stored as a secret.
   - The identity Kyverno will check is the workflow file on `main`:
     `https://github.com/ngems1/Sec-GitOps-platform/.github/workflows/deploy.yml@refs/heads/main`,
     issuer `https://token.actions.githubusercontent.com` (docs/week3/IMAGE-SIGNING.md).
2. **An SBOM per image, SPDX JSON, made by Syft.**
   - It's attached to the image as a signed in-toto attestation (`cosign attest --type
     spdxjson`), so the SBOM is tied to the digest and to the same identity as the signature.
   - It's also uploaded as a workflow artifact for people to read.
3. **By digest, never by tag.** The digest is read from ECR for the commit's tag, then signed,
   attested and verified. A tag can be repointed; a digest cannot.
4. **Verified in the same job:** `cosign verify` and `cosign verify-attestation` with the exact
   identity and issuer. A broken signing setup fails the build, and so the deploy.
5. **After the scan gate:** only images that passed it are signed.
6. **Pinned tools:** cosign 3.1.3 and Syft 1.54.1.
   - Downloaded from their GitHub releases and checked against a SHA-256 written in the
     workflow, as for promtool and the Java agent.
   - No third-party action runs with the AWS credentials (the reasoning of DEPLOY.md, step 2).
7. **The classic cosign storage format, not the cosign v3 default (the Sigstore bundle as an
   OCI 1.1 referrer).**
   - **What it writes:** two tags per image, `sha256-<digest>.sig` and `sha256-<digest>.att`,
     each pushed once.
   - **Why not the v3 default:** on a registry without the OCI referrers API it falls back to
     one tag, `sha256-<digest>`, and rewrites it for each new signature or attestation. ECR's
     immutable tags refuse the second push. Tested locally: cosign 3.1.3 rewrote that tag on a
     second signing.
   - **Kyverno:** classic signatures are the format Kyverno's `verifyImages` has supported the
     longest.
   - **Cost:** cosign 3.1.3 prints a deprecation warning for `--new-bundle-format=false`.
8. **Idempotent:** what already verifies is not signed or attested again. A re-run of the same
   build pushes nothing, so the immutable tags never refuse it.

## Consequences

- **Signing publishes the image digest and this repo's workflow identity to a public
  transparency log (Rekor): acceptable, the repo is public.**
  - The SBOM attestation is logged too.
  - Rekor stores the attestation body only below its size limit (100 KB by default); the large
    SBOMs here are logged as hashes and signatures.
  - Treat the SBOMs as public: they list package names and versions, already readable from the
    public Dockerfiles.
- **Dependency on public Sigstore:** if Fulcio or Rekor is down, the build fails, and so does the
  deploy. Retry the run: the build is skipped for images that already exist, and only the missing
  signatures are added.
- **Third-party code with AWS credentials:** cosign and Syft are third-party binaries running in
  a job that holds the deploy role's credentials. They're pinned by SHA-256, and only the
  official release binaries run, no actions.
- **CI time:** about 1 to 1.5 minutes per build job, in parallel, so about the same on the whole
  run.
  - Installing: about 5 s (cosign is about 140 MB).
  - The SBOM: 3 s locally for a Python image, more from ECR and for the JVM and .NET images.
  - Signing and attesting: two Fulcio and Rekor round trips.
  - Four verifications.
- **ECR:** each build adds two more tagged artifacts per repository (`.sig`, `.att`). The
  lifecycle rule counts them as images, so 20 now keeps about 6 to 7 builds instead of 20. The
  rule's order (oldest first) can also expire an image's signature after the image itself. That
  is a Terraform change, outside this PR.
- **Images built before this ADR are unsigned:** including those running in dev and prod today,
  and rollbacks to them (`image_tag`). They must be signed (or rebuilt) before Kyverno enforces.

## Revisit when

- ECR serves the OCI 1.1 referrers API for these repositories and the Kyverno version in use
  verifies Sigstore bundles: move to the cosign default format (one change in
  `deploy/sign-image.sh` and in the policy).
- cosign 4 drops the classic format: decide that move before upgrading.
- The repo becomes private: public Rekor entries would expose the repo name and digests;
  consider `--tlog-upload=false` with a private trust root, or a private Sigstore.
