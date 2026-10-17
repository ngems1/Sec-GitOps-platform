# 0008: Argo Rollouts canary for the frontend, traffic split by the ALB

Status: accepted (Phase 1, GitOps with Argo CD + Argo Rollouts + canary). Date: 2026-10-15.
Follows ADR 0001 (dev on Argo CD) and ADR 0007 (prod from `env/prod`).

## Context

A new frontend version replaced every pod at once (Deployment rolling update): a bad
release reached all users before anyone could see an error rate. Argo CD already deploys
dev (from `main`) and prod (from `env/prod`, after approval). The frontend is reached
through one ALB per environment, made by the AWS Load Balancer Controller from the Ingress
`frontend`. Istio (ambient + waypoints, D-05) is planned but not installed.

The analysis needed per-version HTTP numbers. Prometheus (kube-prometheus-stack) scraped
only inventoryservice and productcatalogservice; the frontend exported nothing. The ALB's
CloudWatch metrics exist, but per load balancer (stable and canary mixed) and 1-3 minutes
late.

## Options considered

1. **Argo Rollouts, ALB traffic routing** (weighted target groups of the Load Balancer
   Controller), analysis on Prometheus metrics of the canary pods.
   - Real share of user traffic per step; the ALB is already there; no new data plane.
   - The controller edits the Ingress action annotation and the Service selectors, which
     Argo CD must ignore.
2. **Argo Rollouts without traffic routing** (canary by replica count).
   - Simpler; the split is only approximate (1 canary pod of 2 = 50%), not the step's weight.
3. **Wait for Istio** and route with a VirtualService.
   - Finer routing (headers, mirroring), but Istio is a later phase.
4. Analysis on **CloudWatch ALB metrics** instead of Prometheus.
   - No code change, but stable and canary are mixed and the data is late.

## Decision

Option 1, with the frontend instrumented for Prometheus (user decision, 2026-10-15):

- **Traffic for the analysis:** a browse-only loadgenerator (no orders, no cart writes) in dev
  (10 shoppers, ~1.5 requests/s) and prod (5, ~0.8 requests/s) shops through the ALB name, the only
  path where the canary gets its share. It needs the domain.
  Update 2026-10-17: 15 shoppers in both (about 2.1 requests/s). With 5, the first request-volume
  check expected about 12.6 requests for a gate of 10 and aborted a healthy prod canary;
  15 gives about 38 (RUNBOOK section 10, checked in CI).
- **Controller:** argo-rollouts Helm chart, pinned (`ARGO_ROLLOUTS_CHART_VERSION: 2.41.1` in
  `argocd-install.yml`), namespace `argo-rollouts`, installed by `deploy/argocd.sh` before the
  Applications. Argo CD shows Rollout health natively (Progressing / Suspended during a step,
  Degraded when aborted, Healthy when done).
- **Rollout:** `frontend` with `workloadRef` to the existing Deployment (`scaleDown:
  progressively`): same pod template, labels and guardrails; each pod is replaced once. The HPA
  targets the Rollout. Other services stay Deployments. The Deployment keeps no `replicas` in
  Git and both Applications ignore its `/spec/replicas`: the Rollouts controller scales it to 0
  as the Rollout's pods become ready. (Rendering `replicas: 0` instead would stop the old pods in
  the same Argo CD sync that creates the Rollout, before its pods are ready: a gap.)
- **Traffic:** stable Service `frontend`, canary Service `frontend-canary`; the Ingress backend
  is the forward action `actions.frontend`, whose weights the controller sets. Argo CD
  `ignoreDifferences` (+ `RespectIgnoreDifferences`) on that annotation and on the Services'
  `rollouts-pod-template-hash` selector. `frontend.canary.trafficRouter: alb` keeps the switch
  for Istio later.
- **Steps:** 20% → pause 2m → 50% → pause 2m → 100%. Only time-limited pauses (CI fails an
  indefinite one); `progressDeadlineAbort` after 10 min. `ARGOCD_WAIT_SECONDS` is 900 in
  `deploy-env.yml`.
- **Analysis (background, from the first step):** `frontend_http_requests_total` and
  `frontend_http_request_duration_seconds` (new, `src/frontend/metrics.go`, hand-written
  exposition, no new Go module), scraped with the pod's `rollouts_pod_template_hash`, so only the
  canary is measured. At least 10 requests in 2 min, success rate >= 99% and p95 <= 1 s, every
  30 s; no data is a failure, a second failure aborts.
- **Promotion and rollback:** unchanged. dev changes on `main`, prod only through the approved
  `env/prod` promotion. While a canary runs, `argocd-wait.sh` judges the Rollout and its
  AnalysisRuns, not the Application health (other resources can be Degraded during a normal
  pause: the first canary after PR #30 was rolled back that way). Aborted, Degraded or a
  Failed/Error AnalysisRun = failure, and `deploy-env.yml` rolls back (dev: revert the tag commit; prod: move
  `env/prod` back).

## Consequences

- A bad frontend reaches 20% of users for at most a minute or two, then traffic goes back to
  stable by itself.
- Deploys take about 6 minutes longer when the frontend changes.
- The analysis depends on Prometheus (deploy workflow, job "monitoring", now before dev) at
  `monitoring-kube-prometheus-prometheus.monitoring.svc:9090` (CI checks the address against the
  rendered monitoring chart; deploy-env queries it before any canary): without it every
  canary errors and aborts.
- The loadgenerator is permanent traffic on both shops (read-only); it shows in the ALB and
  Grafana numbers. Without it (or without the domain) every frontend canary aborts for lack of data.
- `FAULT_INJECT_500_PERCENT` exists for the demo; it is 0 (off) everywhere by default.
- Two controllers write the frontend's Ingress and Services; the ignored fields must stay in
  step with the chart (frontend name, Service names).

## Revisit when

- Istio ambient with waypoints is installed (D-05): switch `trafficRouter` to Istio routing.
- More services need canaries: move them to Rollouts the same way, or to one ApplicationSet.
