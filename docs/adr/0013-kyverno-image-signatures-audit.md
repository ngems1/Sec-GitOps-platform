# 0013: Kyverno checks image signatures and SBOMs, in audit mode

Status: accepted. Date: 2026-10-18. Phase 5, PR 2 of 3 (PR 1: ADR 0012 signs; PR 3: enforce).

## Context

- **Signing:** since ADR 0012, the `deploy` workflow signs every image it builds (13 ECR
  repositories `boutique/<service>`, the 12 services and the loadgenerator) with cosign keyless,
  and attests its SPDX SBOM.
  - The storage is classic cosign: the `.sig` and `.att` tags.
  - The values are in docs/week3/IMAGE-SIGNING.md.
- **Nothing in the cluster checks it yet.**
- **How add-ons are installed:** Argo CD manages only the shop. Its AppProject `boutique` allows
  the two boutique namespaces and no cluster-scoped objects. The cluster add-ons are installed by
  workflows with `helm upgrade --install` at an exact chart version:
  - Argo CD and Argo Rollouts (`deploy/argocd.sh`);
  - the Load Balancer Controller and metrics-server (`deploy-env.yml`);
  - kube-prometheus-stack, Tempo and the collector (`deploy/monitoring.sh`).
- **Third-party images in the boutique namespaces** (not built here, not signed by us):
  - `public.ecr.aws/docker/library/mysql:8.4`: the db-migrate, catalog and order-flow Jobs;
  - `ghcr.io/open-telemetry/.../telemetrygen`: the tracing smoke test;
  - `public.ecr.aws/docker/library/python:3.12-slim`: the isolation test's probe.

  The chart itself renders only our 13 ECR images (Redis is ElastiCache on AWS).

## Decision

1. **Kyverno 1.19.1 (chart `kyverno` 3.9.1, pinned)**, installed like the other add-ons.
   - A job `policies` in the deploy workflow runs `deploy/kyverno.sh`: Helm into namespace
     `kyverno`, then the policy.
   - It runs beside the deploy; nothing waits for it.
   - It's not an Argo CD Application: the project allows no cluster-scoped objects, and no add-on
     is managed that way today.
2. **One `ImageValidatingPolicy`** (`policies.kyverno.io/v1`), `boutique-image-signatures`
   (`deploy/kyverno/image-signatures.yaml`).
   - The classic `ClusterPolicy` with `verifyImages` is deprecated in Kyverno 1.19.
   - **Signature:** cosign keyless, subject exactly
     `https://github.com/ngems1/Sec-GitOps-platform/.github/workflows/deploy.yml@refs/heads/main`,
     issuer exactly `https://token.actions.githubusercontent.com`, public Rekor.
   - **SBOM:** an in-toto attestation of type `https://spdx.dev/Document` from the same identity.
   - **Which images:** the shop's ECR repositories only, `<account>.dkr.ecr.<region>.amazonaws.com/boutique/*`.
     The registry is the Terraform output `ecr_registry`, filled in at install, so it covers
     exactly the 13 repositories.
   - **Filtered in the CEL as well.** Kyverno counts an image outside `matchImageReferences` as
     0 verified signatures (`pkg/cel/libs/imageverify/impl.go`), so a pod with a mysql sidecar
     would otherwise fail. Checked with the Kyverno CLI.
   - **Pods only** (`autogen` off), in `boutique-dev` and `boutique-prod`, at admission and in the
     hourly background scan.
3. **Audit only: it never blocks or changes a pod.**
   - `validationActions: [Audit]`.
   - `failurePolicy: Ignore`, and `forceFailurePolicyIgnore` for every Kyverno webhook: Kyverno
     down or slow means the pod is admitted.
   - Kyverno's webhooks see only the two boutique namespaces.
   - No digest mutation (`mutateDigest: false`), and tags are allowed (`verifyDigest: false`).
     The signature itself is still checked on the digest the tag points to.
   - `deploy/kyverno.sh` refuses to apply a policy that isn't Audit only, fail open and
     non-mutating. CI step "Kyverno policy (audit only, signing identity)" checks the same, and
     that the identity, issuer and SBOM type equal `deploy.yml`'s `SIGNER_*`.
4. **Results** are in Kyverno's PolicyReports, one per pod: `pass`, `fail` or `error`.
   cluster-status (`boutique-dev` or `boutique-prod`) has a step "Image signatures (Kyverno,
   audit)" (`deploy/kyverno-report.sh`). RUNBOOK section 16.
5. **Small footprint:**
   - one admission controller (100m / 128Mi, limit 384Mi) and one reports controller (100m /
     64Mi, limit 256Mi), so +200m CPU and +192Mi of requests, 2 pods;
   - no background or cleanup controller (no generate, mutate or cleanup policies).

## Consequences

- **Credentials to ECR.** The policy uses the `amazon` credential provider, which takes the AWS
  SDK's default chain in Kyverno's pods.
  - **No dedicated role:** there's no Pod Identity association for Kyverno; adding one is
    Terraform, outside this PR.
  - **So today:** Kyverno reads ECR with the node role through instance metadata, if pods can
    reach it. That's the open finding of ADR 0011, and the hop limit isn't set in the repo. The
    node role can read ECR (the nodes pull our images with it).
  - **If they can't:** every result for our images is `error`, not `pass`. Nothing is blocked,
    but nothing is proven either.
- **Admission latency:** a pod creation in the boutique namespaces waits for the check (registry
  reads, signature verification), up to the 10 s webhook timeout. Results are cached; a timeout
  admits the pod.
- **Network:** Kyverno's pods reach ECR, Rekor and the Sigstore TUF root on the internet. The
  `kyverno` namespace has no NetworkPolicy.
- **New add-on to maintain:** one more pinned chart in `deploy.yml`. Kyverno's CRDs are
  cluster-wide.

## Before enforcing (PR 3)

1. **Rollbacks are signed.** A redeploy with `image_tag` skips the `build` job and signs nothing.
   Images from before ADR 0012 are unsigned, and enforce would reject a rollback to them. Sign
   the images of an `image_tag` run in `deploy.yml` (the same identity) before `deploy-dev`.
   **Done 2026-10-18:** job `sign-rollback` (ADR 0012, note 2026-10-18).
2. **Kyverno's own ECR role:**
   - a Pod Identity association for the admission and reports controllers' service accounts,
     with `ecr:GetAuthorizationToken`, `ecr:BatchGetImage` and `ecr:GetDownloadUrlForLayer` on
     `boutique/*` (Terraform);
   - then the IMDS hop limit fix of ADR 0011, so nothing relies on the node role.
3. **Zero `fail` and zero `error`** in both namespaces for at least a week of deploys, including
   a canary and a rollback.
4. **High availability:** 3 admission replicas with a PodDisruptionBudget. Decide the failure
   policy: `Fail` blocks every deploy while Kyverno is down, `Ignore` lets unsigned images in
   while it's down.
5. **Digest pinning:** consider `mutateDigest: true`, so the pod runs exactly the digest that was
   verified, not whatever the tag points to a moment later. ECR tags are immutable, so this
   mostly matters for other registries. It changes pod specs: check the Argo CD and Rollouts
   drift settings first.
6. **Third-party images** (mysql, telemetrygen, python): pin them by digest, or add a separate
   allow-list policy. They're out of this policy on purpose.
7. **Pods started by workflows** (load-test, chaos) use the loadgenerator image at the
   frontend's tag. They pass once that tag was built after ADR 0012; older completed pods can
   show `fail` until deleted.
8. **Sigstore availability:** decide what an unreachable Rekor or TUF means in enforce mode.

## Revisit when

- The signing format moves to the cosign v3 bundle (ADR 0012): change the attestation from
  `intoto` to `referrer`.
- Kyverno removes `ClusterPolicy`, or `ImageValidatingPolicy` changes version: this policy
  already uses the new type.
