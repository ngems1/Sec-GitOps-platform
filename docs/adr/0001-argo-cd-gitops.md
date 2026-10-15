# 0001: Argo CD deploys dev from Git

Status: accepted (Phase 1, Day 3). Scope: dev only; prod follows on Day 4.

## Context

Dev was deployed by `helm upgrade` in `deploy-env.yml`, with values built from the
Terraform state at deploy time and the image tag passed as `--set`. Nothing in Git said
which version ran in dev. The plan (DESIGN D-03) is pull-based GitOps with Argo CD.

## Options considered

- **Image tag in Git**
  - (a) the deploy workflow commits the tag to a values file, with a GitHub App that is
    the only bypass actor on the `main` ruleset;
  - (b) Argo CD Image Updater: another controller, ECR token refresh, and SHA tags have
    no order to pick the newest from;
  - (c) one pull request per tag change: no bypass, but a PR for every deploy and a
    token that can trigger `ci-ok`.
- **Terraform names:** committed to Git, or injected by the workflow into the Application.
- **Repository access:** a read-only deploy key, or a GitHub App.

## Decision

- Argo CD in namespace `argocd` (argo-cd chart, pinned), installed by a manual workflow.
  No public UI; access with `kubectl port-forward`.
- Application `boutique-dev`: `helm-chart/` + `values-aws.yaml` + `values-dev.yaml` +
  `gitops/dev/values.yaml`, automated sync with prune and self-heal, annotation tracking,
  in a project limited to this repository and `boutique-dev`.
- `gitops/dev/values.yaml` holds the Terraform names (without `sesRecipients`) and the
  image tag. The deploy workflow writes it with option (a).
- Argo CD reads the repository with a read-only deploy key kept in AWS Secrets Manager
  (dev KMS key) and copied into the cluster by the install workflow.
- The workflow keeps what is not the chart: namespace and labels, `redis-auth`,
  `emailservice-slack`, DB migrations, the Load Balancer Controller, monitoring.
- Until the Application exists, dev keeps the Helm steps.

## Consequences

- Git records every dev version; rollback is a revert of the tag commit.
- One actor (the App) can push to `main` without a pull request. It is limited to
  Contents, used only by the deploy job in the `dev` environment, and its commits only
  change `gitops/dev/values.yaml`.
- AWS account and resource names are committed (private repository; they are names,
  not secrets). The deploy workflow already prints them in its log.
- Dev sends no SES order emails under Argo CD (no recipients in Git).
- Chart changes reach dev when merged, before images are built or migrations run.

## Revisit when

- prod moves to Argo CD (Day 4, done: ADR 0007): add `boutique-prod` to the project, decide how prod
  promotion is approved.
- Secrets move to External Secrets or similar (DESIGN D-06 revisit).
