# 0006: The deploy workflow owns the PriorityClasses

Status: accepted (Phase 1, Day 2 leftover). Date: 2026-10-14.

## Context

The namespace guardrails (DESIGN section 3.4) give every pod `priorityClassName: <namespace>`:
`boutique-dev` (value 1000, never preempts) and `boutique-prod` (value 100000, may preempt
dev). A PriorityClass is cluster-scoped. Dev is deployed by Argo CD (ADR 0001) in the project
`boutique`, which has `clusterResourceWhitelist: []`, so Argo CD refuses to sync a
PriorityClass from the chart. Prod is still deployed by Helm, which could create it.

## Options considered

- (a) **The deploy workflow creates the PriorityClass**, in the same step as the namespace
  and its labels, which it already owns (`CreateNamespace=false`). The chart keeps the
  template but never renders it in the release; the workflow renders that one file with the
  environment's values and applies it.
  - Argo CD keeps no cluster-wide rights; one owner for each PriorityClass in dev and prod.
  - Day 4 (Argo CD for prod) does not have to take a PriorityClass over from Helm.
  - A chart change reaches dev when merged, possibly before the workflow has created the
    class: pods naming it are refused until it exists, then the ReplicaSet controller retries.
- (b) **Allow `scheduling.k8s.io/PriorityClass` in the AppProject.**
  - Everything stays in the chart.
  - The whitelist is per kind, not per name: anything merged to `main` could create any
    PriorityClass, including `globalDefault: true` or a value above prod's, until an
    admission policy (Kyverno, Phase 2) limits it.
  - `project.yaml` is applied only by the manual `argocd-install.yml`; it must be rerun before
    the first sync, or the sync fails and the deploy workflow reverts the tag commit.
  - Prod's class would still come from Helm, and Day 4 would move its ownership.

## Decision

Option (a). `helm-chart/templates/priorityclass.yaml` renders only with
`guardrails.priority.render=true`. The `PriorityClass` step in `deploy-env.yml` sets it,
renders `--show-only templates/priorityclass.yaml` with the same values files as the
release, and runs `kubectl apply`. CI fails if the release renders a PriorityClass, or if
the workflow's render does not produce `boutique-<env>`.

## Consequences

- The Argo CD project still allows no cluster-wide objects.
- The PriorityClasses exist before any pod uses them (the guardrails PR adds
  `priorityClassName`), so landing this first removes the ordering problem above.
- A PriorityClass `value` cannot be changed in place: changing it in values makes the step
  fail until the class is deleted and recreated.
- `cluster-status.yml` shows the classes, quotas, limits, disruption budgets and the Argo CD
  sync state, for checks without local cluster access.

## Revisit when

- prod moves to Argo CD (Day 4): the step stays; check that no Application renders the class.
- An admission policy can restrict PriorityClass names and values: option (b) becomes safe.
