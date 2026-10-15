# 0007: prod is deployed by Argo CD from a promotion branch

Status: accepted (Phase 1, Day 4). Date: 2026-10-15. Follows ADR 0001 (dev on Argo CD).

## Context

dev is deployed by Argo CD from `main` (ADR 0001): the Application `boutique-dev` syncs
`helm-chart/` with `gitops/dev/values.yaml`, automated, with prune and self-heal. prod was still
deployed by `helm upgrade` from `deploy-env.yml`, after a reviewer approves the `prod` GitHub
environment. DESIGN section 3.3 says "prod syncs after approval".

If `boutique-prod` tracked `main` with automated sync, only image tags would wait for that
approval: any merged change to `helm-chart/` or `values-prod.yaml` would reach prod at merge time.

## Options considered

1. **Track `main`, automated sync** (like dev).
   - Simplest; one revision for both environments.
   - Chart and prod-values changes skip the prod approval. Rejected.
2. **Track `main`, manual sync** triggered by the deploy job after approval.
   - Approval gates every change.
   - No self-heal (Argo CD only self-heals with automated sync); the workflow needs sync
     rights on Argo CD and an API call path; drift stays until the next deploy.
3. **Track a promotion branch, automated sync**: only the approved prod deploy job moves the
   branch (fast-forward) to the `main` commit that dev runs, after writing
   `gitops/prod/values.yaml` on `main`.
   - Chart, `values-prod.yaml` and image tag reach prod together, only after the approval.
   - Self-heal works; Git (the branch) always says what prod runs; rollback moves the branch back.
   - One more ref to protect; promotion fails if `main` changed outside `gitops/` since dev was
     checked (deploy again so dev checks it first).

## Decision

Option 3. The branch is `env/prod`, the `targetRevision` of `deploy/argocd/boutique-prod.yaml`
(read from there by `deploy/gitops-commit.sh` and `deploy/argocd.sh`).

- **Application `boutique-prod`**, project `boutique` (now with destination `boutique-prod`), same
  chart and release name as Helm used (`boutique`), values `values-aws.yaml`, `values-prod.yaml`,
  `../gitops/prod/values.yaml`, `CreateNamespace=false`.
- **Sync policy: automated, `selfHeal: true`, `prune: false`.** Self-heal: a manual change in the
  prod cluster is reverted to Git, so Git stays the truth. No prune: an object that disappears from
  the rendered chart (a deleted template, a wrong value) is shown OutOfSync and kept, never deleted
  by itself; deletions in prod are a deliberate manual sync with prune. dev keeps prune, because
  losing a dev object is cheap and catches chart mistakes early.
- **Promotion** (`deploy-env.yml`, prod, after the approval): `boutique-dev` must be Synced and
  Healthy at a commit whose `gitops/dev/values.yaml` has this run's image tag (prod only gets an
  image that already runs in dev; images are never rebuilt for prod: `deploy.yml` passes the same
  tag). `main` may differ from that commit only in `gitops/`. Then the GitHub App
  (`boutique-gitops-dev[bot]`, the bypass actor of the `main` ruleset) commits
  `gitops/prod/values.yaml` ("gitops: prod image tag ... [skip ci]") and moves the branch to it.
- **Rollback**: the branch is put back where it was (force-with-lease) and the tag commit on
  `main` is reverted.
- **Handover from Helm**, as for dev: while Helm deploys prod, each successful approved prod
  deploy from `main` records its tag and moves the branch; `argocd-install` creates
  `boutique-prod` only when the branch exists with a tag, so Argo CD adopts exactly what Helm last
  deployed, and from then on the Helm steps are skipped for prod. Never both.

## Consequences

- No change reaches prod without the prod approval and a passing dev.
- The App now also writes in the `prod` environment: `GITOPS_APP_ID` and `GITOPS_APP_PRIVATE_KEY`
  must be set there too.
- The promotion branch is not covered by the `main` ruleset: it needs its own ruleset (only the
  App may update it), otherwise anyone with write access could move prod (G-03 family).
- Like dev, prod sends no SES order emails under Argo CD: the recipient addresses stay out of Git.
- `argocd-install` runs in the `dev` environment and creates `boutique-prod`, but it never moves
  the branch, so it cannot change what prod runs.
- A merge that touches the chart between the dev deploy and the prod approval makes the
  promotion fail on purpose; deploy again.

## Revisit when

- Argo CD runs in more than one cluster (an ApplicationSet with one entry per environment).
- Secrets and SES recipients move to External Secrets (DESIGN D-06 revisit).
