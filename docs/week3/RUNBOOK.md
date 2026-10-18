# Runbook

What to do when something breaks. Each section: **symptom → check → fix**.
The first tool for almost everything is **Actions → cluster-status** (pick the namespace): pods,
events, autoscalers, restarted containers with their last exit reason, logs of unhealthy pods,
Helm history. Use it before changing anything.

Names used below: environment prefix `week3-boutique-dev` / `week3-boutique-prod`, namespaces
`boutique-dev` / `boutique-prod` / `monitoring`, Helm release `boutique`, cluster `week3-boutique-eks`.

Optional CloudShell access (needs your identity in `ADMIN_PRINCIPAL_ARN`):

```bash
aws eks update-kubeconfig --name week3-boutique-eks --region us-east-1
```

## 1. A deploy failed

| Failed step | Likely cause | Fix |
|---|---|---|
| `Configure AWS credentials` | The run isn't on `main` (or an approved environment): the OIDC roles only trust those | Re-run from `main`. Branches only get the read-only plan role |
| Any step: `AccessDenied ... with an explicit deny in a permissions boundary` | The deploy (or plan) role's boundary does not allow that action: a new AWS service, or something the boundary protects on purpose (SECURITY.md section 2a) | Add the action or service to `terraform-bootstrap/boundaries.tf` (never to the deny statements), merge, run **bootstrap** (plan, then apply), then re-run the failed job |
| Build | Code doesn't compile; Docker Hub / package registry hiccup | Read the build log; re-run failed jobs for a transient error |
| Scan gate | ECR found a CRITICAL vulnerability | Update the base image or dependency. Emergency only: `SCAN_BLOCKING=false` |
| `Read Terraform outputs` | Infrastructure not created (or destroyed) | Actions → infra → `apply`, then re-run deploy |
| `AWS Load Balancer Controller`: `UPGRADE FAILED: error validating "": error validating data: the server is currently unable to handle the request` | Helm's client-side OpenAPI validation reads `/openapi/v2`, which the EKS metrics-server add-on broke (section 7), even with every APIService `Available=True` | The step passes `--disable-openapi-validation` (the API server still validates on apply). Remove the flag once eks-openapi-fix `check` shows protobuf OK 10/10. If it comes back: eks-openapi-fix `diagnose` names the definition that breaks it |
| `metrics-server`: "The EKS add-on metrics-server is still installed" | `infra` apply has not removed the add-on yet (merging the fix starts `infra` and `deploy` at the same time) | Wait for Actions → infra (apply) to finish green, then re-run the failed deploy jobs (section 7, "Rollout order") |
| `Database migrations` | RDS not reachable, or SQL error | Section 3. The Job's log is printed in the step |
| `Deploy with Helm` (timeout) | New pods never became Ready. Helm already rolled back (`--rollback-on-failure`) | The `Diagnostics` step ran `deploy/diagnose.sh`: read pods / events / logs; then section 2 |
| `Smoke test` | The ALB, HTTPS name, a page or inventory `/stock` failed. The `Roll back` step restored the previous revision | A new ALB needs 2-3 min: re-run once. Otherwise read which URL failed |

**Manual rollback to a known version** (no build): Actions → deploy → Run workflow →
`image_tag` = the 12-character SHA shown in the shop footer or the Slack "Deployed" message,
`target` = `dev-only` (then `dev-then-prod` once checked). Verify with cluster-status → Helm history.

## 2. Pods are unhealthy

Check: cluster-status → the namespace. Look at the pod's STATUS and "containers that restarted".

| What you see | Meaning | Fix |
|---|---|---|
| `Pending`, event `Too many pods` | Node pod slots full | Check the Nodes step: `MAX_PODS` must be 110 (prefix delegation). If it shows 17, the nodes predate the change: `infra → destroy` then `apply` |
| `Pending`, `Insufficient cpu/memory` | Nodes really full (e.g. during a stress test) | Wait for the test to end, or raise `node_desired_size` |
| `CrashLoopBackOff` | The process exits at start | "logs before the last restart": usually a missing env var, secret or unreachable dependency |
| Restarts with reason `OOMKilled` | Memory limit too low | Raise the limit in `helm-chart/values.yaml` (Grafana: `monitoring/kube-prometheus-stack.values.yaml`, now 768Mi) |
| Restarts with `Liveness probe failed` under load | Pod too busy to answer the probe in time | Probes already allow 5 s × 6 failures; let the HPA add pods, or raise the CPU limit |
| `ImagePullBackOff` | Tag missing in ECR (ECR is emptied by `destroy`) | Run deploy without `image_tag` to rebuild |
| HPA shows `<unknown>` targets | metrics-server not reachable | cluster-status → `kube-system`: "metrics API" must be `Available=True`. metrics-server is the Helm chart from `deploy-env.yml` (2 replicas, port 10250, open to the cluster SG through the kubelet rule); check its pods in `kube-system` |

A single deleted pod is recreated by Kubernetes in about 5 s (chaos test). With one replica there
is a short gap; services that matter can run `minReplicas: 2`.

## 3. Database connectivity

Symptoms: `Database migrations` fails, orders stay `PENDING`, productcatalog logs `MySQL` errors
(the shop keeps working from Redis / the built-in catalog, see DEPLOY.md "Catalog").

1. **Is RDS up?** RDS console → the instance is `Available`. During `apply` a new database takes ~10 min (prod Multi-AZ longer).
2. **Network:** RDS is private (no public address); its security group only accepts 3306 from inside the VPC (pods and the order-status Lambda). If only some pods fail, check their NetworkPolicy egress too.
3. **Credentials:** the password lives in Secrets Manager (managed by RDS). The migration Job gets it through a temporary Secret `db-migrate-credentials` that is deleted right after.
4. **TLS:** connections verify the RDS certificate. A "certificate verify failed" means the CA bundle in the image is outdated.
5. **Order status Lambda:** CloudWatch Logs `/aws/lambda/week3-boutique-<env>-order-status`. Errors there also fire the `order-status-lambda-errors` alarm in `#boutique-alerts`.

Redis (cart, catalog cache) problems: the cart fails and catalog reads go straight to MySQL.
During `destroy`, an error "Redis cluster ... not present or not available" means ElastiCache is
still deleting: wait until it disappears from the console, then run `destroy` again.

## 4. Queues are stuck

Symptoms: Slack `#boutique-alerts` "...-backlog" (oldest message > 5 min for 3 periods) or
"...-dlq-not-empty"; Grafana → Event flow rising; order-flow shows orders stuck in `PENDING`.

| Queue | Consumer | Check |
|---|---|---|
| `inventory-q` | inventoryservice (pod) | cluster-status: is it running, with replicas > 0? Logs |
| `order-status-q` | order-status Lambda | Lambda logs; event source mapping enabled |
| `notification-q` | emailservice (pod) | Logs: SES errors (unverified recipient, sandbox), Slack errors |

- **Backlog, no DLQ messages:** the consumer is down or slow. Fix the consumer; messages wait in the queue (4 days; DLQs keep them 14 days) and are processed when it comes back. Shown by the chaos `consumer-failure` test: 19 queued orders processed within seconds of the restart, alarm back to OK.
- **DLQ not empty:** a message failed 3 times. Read the consumer's error for that order ID (order-flow shows it). Fix the cause, then send the messages back: SQS console → the DLQ → **Start DLQ redrive**, or in CloudShell
  `aws sqs start-message-move-task --source-arn <dlq-arn>`. Consumers are idempotent, so redriving is safe.
- **SES refused an email:** emailservice removes its DynamoDB claim and lets the message retry; after 3 tries it lands in the notification DLQ. Usually the recipient isn't verified while SES is in sandbox (order-flow, section "Amazon SES").

## 5. Monitoring

| Symptom | Fix |
|---|---|
| `#boutique-alerts`: "ALARM: AWS Budget (Bedrock daily)" | The shopping assistant's Bedrock cost passed 50% or 100% of `bedrock_daily_budget_usd` (terraform-bootstrap) today. AWS updates budget costs a few times a day, so it can be hours late; the assistant's own daily question cap stops it, not the budget | Check the assistant's request and token metrics (Grafana). Expected (a demo): ignore or raise `bedrock_daily_budget_usd` and run bootstrap. Unexpected: lower the daily cap or turn the assistant off (RUNBOOK section 15: `dailyQuestionCap: 0` or `shoppingAssistantService.create: false`) |
| Grafana URL times out | Your IP isn't in `MONITORING_ALLOWED_CIDR` (a comma-separated list: add it, re-run deploy), or the ALB is still starting |
| Grafana 503 / restarts | cluster-status → `monitoring`. It was `OOMKilled` at 384Mi; the limit is 768Mi |
| "Datasource prometheus was not found", empty Prometheus settings | Bundled plugins broke on the read-only disk; `preinstall_disabled: true` in `grafana.ini` must stay |
| CloudWatch panels "No data" | Traffic needed (run load-test), time range ≥ 30 min; cluster-status → `monitoring` runs the dashboard queries directly against AWS to separate a Grafana problem from a missing metric (series, a CloudWatch error, or NO series). **SEARCH quoting:** a double-quoted term is an exact match of a whole metric name, dimension name or value, so `"boutique-dev"` never matches `app/boutique-dev/<id>`. Use unquoted token terms (`boutique-dev`, `week3-boutique`); quote only `MetricName="..."`. CI checks it (`deploy/tests/cloudwatch-search-check.sh`) |
| Panel error "bad_data: ... parse error: unexpected identifier ... in label matching, expected string", or one tile per old ALB | **Quoting differs by query language.** PromQL label values need quotes (`namespace="boutique-prod"`). CloudWatch SEARCH name terms must not have them (`boutique-prod`, quote only `MetricName="..."`). Both are checked in CI ("Dashboard PromQL parses (promtool)", "CloudWatch SEARCH terms"). ALB SEARCH panels wrap the search in `MAX(...)` or `SUM(...)`, so old ALBs from earlier cluster rebuilds (CloudWatch keeps their metrics two weeks) do not add series |
| CloudWatch "AccessDenied" in Grafana | The Grafana Pod Identity role (`terraform-aws/monitoring.tf`) lacks that read action; add it there, never broader than read-only |
| A log group's retention reads "Never expire" again, or the infra plan wants to change it | Terraform manages the Container Insights groups (`terraform-aws/logs.tf`): application 1 day, permanently (ADR 0011, note 2026-10-17: cost and privacy, like Tempo's 24 h of traces), dataplane 14, host 14, performance 7. The add-on's Fluent Bit sets no retention by default; if an add-on upgrade starts setting one, the next infra plan shows the drift. After an `infra` destroy the groups stay (`skip_destroy`) and the next apply adopts them again (the `import` block) |
| `#boutique-alerts`: ":rotating_light: GuardDuty HIGH/CRITICAL: ..." | GuardDuty found something with severity >= 7 (for example credentials used from outside AWS, a node talking to a known bad address) | Open the finding (link in the message). Do not delete anything first: the CloudTrail files are kept 30 days under Object Lock. Real: rotate what leaked (the CI roles have no keys; check the Pod Identity role named in the finding), then `infra` destroy/apply if a node is suspect. False positive: the detector belongs to another project in this account (shared, SECURITY.md section 2a); ask its owner to archive or suppress it, do not change GuardDuty from here |

## 6. HTTPS and DNS

| Symptom | Fix |
|---|---|
| Browser certificate warning | You're on the raw `*.elb.amazonaws.com` name; use `dev.` / `shop.` / `grafana.<domain>` |
| Name doesn't resolve after a fresh apply | The deploy workflow creates the records (`deploy/dns-record.sh`); run deploy |
| ACM certificate stuck "Pending validation" | The validation CNAMEs must be in the hosted zone (`terraform-aws/dns.tf`); check `DOMAIN_NAME` matches the zone |

## 7. Argo CD: "failed to load open api schema"

Symptom: on a new cluster (seen on EKS 1.35, platform `eks.24`) Argo CD never syncs:
`failed to load open api schema while syncing cluster cache: error getting openapi resources: the
server is currently unable to handle the request`, while `kubectl get --raw /openapi/v2` (JSON)
works. The **protobuf** form of `/openapi/v2`, which Argo CD requests, answers 503
([argo-cd#19490](https://github.com/argoproj/argo-cd/issues/19490)). Helm's client-side
validation (section 1, LBC step) fails the same way.

**Root cause** (found with `diagnose`, 2026-10-15): the **EKS metrics-server add-on** (APIService
`v1beta1.metrics.k8s.io`), installed with `most_recent = true`, publishes OpenAPI definitions that
cannot be converted to protobuf. `openapi_v2.ParseDocument` fails on
`io.k8s.metrics.pkg.apis.metrics.v1beta1.*` (`NodeMetrics`, `PodMetrics`, `ContainerMetrics`, ...)
and on `*_v2` copies of apimachinery types (`ObjectMeta_v2`, `Quantity_v2`, ...), each with
`invalid properties: ArbitraryKeys, SchemaProps, SwaggerSchemaProps`: a schema serialized from Go
struct fields instead of as OpenAPI. Deleting `v1.metrics.eks.amazonaws.com` (the first suspect,
[aws-load-balancer-controller#4543](https://github.com/kubernetes-sigs/aws-load-balancer-controller/issues/4543))
did not help.

**Fix:** `terraform-aws/eks.tf` no longer installs the metrics-server add-on (and drops its 10251/tcp
node rule); `deploy-env.yml` installs the upstream chart (`kubernetes-sigs/metrics-server`, pinned
`METRICS_SERVER_CHART_VERSION`, 2 replicas, PodDisruptionBudget, requests and limits) right after the
Load Balancer Controller. Both serve the same APIService, so the add-on must be gone first: the
deploy step fails with "The EKS add-on metrics-server is still installed" otherwise.

**Rollout order** (merging touches `terraform-aws/**` and `deploy-env.yml`, so `infra` and `deploy`
both start on the push to `main`):
1. Merge the PR.
2. Actions → infra (push run, apply): removes the add-on. From here until step 3 there is no
   metrics API: HPAs keep their replica count, `kubectl top` fails.
3. Actions → deploy: if it reached the metrics-server step before step 2 finished, it failed there
   (before changing anything): **re-run failed jobs** once infra is green.
4. Verify: eks-openapi-fix `check` (protobuf OK 10/10), Argo CD `boutique-dev` syncs, `kubectl get
   hpa -A` shows CPU targets. Then remove `--disable-openapi-validation` from the LBC step.

**Rule: pin add-on versions; never `most_recent`.** `most_recent = true` means a new cluster (or any
apply) can pick up an add-on release nobody tested; that is how this broke. Every add-on in
`eks.tf` gets `addon_version = "<tested version>"` and `most_recent = false`; upgrades are a
reviewed change. (Pending: the remaining add-ons are pinned once their running versions are read
from the `diagnose` run's "EKS add-ons" table.)

Tool: **Actions → eks-openapi-fix** (results on the run's Summary page).

1. **Check** (`action` = `check`, read-only): 10 GETs of `/openapi/v2` as protobuf and 10 as JSON
   through `kubectl proxy`. Protobuf failing (503 or `000`) while JSON is OK confirms the symptom.
2. **Remove** (`action` = `remove`): checks, saves the APIService as artifact
   `apiservice-v1.metrics.eks.amazonaws.com` (kept 90 days), deletes that APIService only (its
   Service `kube-system/eks-extension-metrics-api` stays), waits 2 min, says whether EKS recreated
   it, checks again, then hard-refreshes the Argo CD Application `boutique-dev`.
   - Protobuf OK after and not recreated: the cause is confirmed; Argo CD should sync within minutes.
   - EKS recreated it and protobuf fails again: deleting does not help; restore is not needed.
   - Protobuf still fails without the APIService: it was not the cause; restore it.
3. **Restore** (`action` = `restore`, `restore_run_id` = the ID in the remove run's URL,
   `.../actions/runs/<id>`): `kubectl apply` of the saved APIService. It refuses any other object.
4. **Diagnose** (`action` = `diagnose`, read-only): checks, saves `/openapi/v2` as JSON (artifact
   `openapi-v2-json`, 30 days), then converts it the way the API server builds the protobuf form
   (kube-openapi: `openapi_v2.ParseDocument`, then `proto.Marshal`, with gnostic-models `v0.7.0`).
   The error names the definition that cannot be converted; the run then shows the CRD or APIService
   that owns its API group (created time, labels and annotations: which add-on or Helm release
   installed it), every CRD by creation time, and the EKS add-on versions.
   If the conversion succeeds here while the cluster still answers 503, the cause is elsewhere,
   or the API server uses another gnostic-models version: try the one Kubernetes 1.35 vendors.

What is lost while `v1.metrics.eks.amazonaws.com` is deleted (remove): the EKS metrics API (`metrics.eks.amazonaws.com`, control-plane
metrics from EKS). metrics-server, the HPAs and `kubectl top` use `metrics.k8s.io` and keep working.

## 8. prod on Argo CD (promotion branch)

prod is deployed by the Application `boutique-prod`, which syncs the **promotion branch** `env/prod` (the
`targetRevision` in `deploy/argocd/boutique-prod.yaml`), never `main` directly. Only an approved
prod deploy moves the branch (ADR 0007, [ARGOCD.md](ARGOCD.md)). The deploy log says "prod is
deployed by: Argo CD (boutique-prod)" or "Helm" (before the handover).

| Failed step / symptom | Cause | Fix |
|---|---|---|
| `Promotion check (prod)`: "dev runs X, not Y" | prod only gets an image tag that runs in dev, and dev now runs another one (a later dev deploy, or a dev rollback) | Deploy the tag dev runs, or redeploy the wanted tag with `target = dev-then-prod` so dev runs it first |
| `Promotion check (prod)`: "boutique-dev is OutOfSync/Degraded" | dev is not in a good state, so nothing is promoted from it | Fix dev first (sections 1 and 2), then deploy again |
| `Promotion check (prod)`: "boutique-dev does not exist" | dev is still on Helm | Hand dev over first (ARGOCD.md, steps 5 and 6) |
| `Commit the image tag`: "main changed since dev was checked ... (not only gitops/)" | Something outside `gitops/` was merged after dev was checked (often a chart change merged while prod waited for approval) | Run the deploy again: dev checks the new `main` first, then prod can be promoted |
| `Commit the image tag`: "No GitHub App token. Set the prod environment variable GITOPS_APP_ID..." | The App variable/secret is set on `dev` only | Settings > Environments > `prod`: add `GITOPS_APP_ID` and `GITOPS_APP_PRIVATE_KEY` |
| `Wait for Argo CD` times out, or the smoke test fails | The new version does not become healthy in prod | Automatic: `Roll back (Argo CD, prod)` puts the branch back on its previous commit and reverts the tag commit on `main`. Then read `Diagnostics` |
| `boutique-prod` OutOfSync, nothing to fix in the cluster | An object left the chart: prod does not prune it (on purpose) | Check it really should go, then in the UI: Sync with **Prune** ticked for that object (or `kubectl -n boutique-prod delete <kind>/<name>`) |

**Manual rollback:** Actions > deploy > Run workflow with `image_tag` = an older commit SHA and
`target = dev-then-prod` (dev runs it first, then prod after approval). Never move the promotion
branch by hand: the deploy job is the only writer.

**Back to Helm (emergency):** `kubectl -n argocd delete application boutique-prod` (no
finalizer: prod keeps running), then the next prod deploy uses the Helm steps. The same
field-ownership conflict as in dev can appear on the first `helm upgrade` (ARGOCD.md, Rollback):
add `--force-conflicts` to that one Helm run.

## 9. Argo CD UI (https://argocd.&lt;domain&gt;)

Exposed by `argocd-install` only when the variable `ARGOCD_ALLOWED_CIDR` and the secret
`ARGOCD_ADMIN_PASSWORD` are both set ([ARGOCD.md](ARGOCD.md), UI). User `admin`.

**Change the allowed IP** (new network, the presentation venue):
1. Find the venue's public IP: open https://checkip.amazonaws.com on the laptop you will present
   from, on the venue's Wi-Fi.
2. Settings > Secrets and variables > Actions > Variables > `ARGOCD_ALLOWED_CIDR` = `<that-ip>/32`.
   Several places: comma-separated (`198.51.100.4/32,203.0.113.7/32`). Never `0.0.0.0/0` (refused).
3. Actions > argocd-install > Run workflow. Only the ALB rule changes (a few seconds); the UI and
   the Applications are untouched. Remove the venue's IP the same way afterwards.

**Change the password:** update the secret `ARGOCD_ADMIN_PASSWORD`, then run argocd-install. The
hash in `argocd-secret` is replaced and every open session is logged out. Unchanged secret = no
change, sessions stay valid. Don't change it in the UI: the next run puts the secret's value back.

| Symptom | Cause | Fix |
|---|---|---|
| Browser times out | Your address is not in `ARGOCD_ALLOWED_CIDR` (new network, mobile hotspot), or the ALB is less than 3 minutes old | Update the variable (above), run argocd-install, wait 2-3 minutes |
| Run summary: "Argo CD UI not exposed" | The variable or the secret is missing, or there is no domain (`DOMAIN_NAME`) | Set them; HTTPS needs the domain |
| "Invalid username or password" | The secret changed but argocd-install did not run since | Run argocd-install |
| 404 from the ALB | Opened by its `*.elb.amazonaws.com` name or an IP: the rule only answers `argocd.<domain>` | Use https://argocd.&lt;domain&gt; |

**Better next step: GitHub SSO (Dex).** Personal GitHub logins instead of one shared password,
read-only access for viewers, and the local `admin` user turned off (ARGOCD.md, UI).

## 10. Frontend canary (Argo Rollouts) and its demo

The frontend is an Argo Rollout (ADR 0008): a new version gets **20%** of the ALB's traffic, then
**50%** after 2 minutes, then **100%** after 2 more. A background analysis checks the canary pods
only (Prometheus): **at least 10 requests in 2 min**, **success rate >= 99%** and **p95 <= 1 s**,
every 30 s; no data counts as a failure. A second failed
measurement aborts: traffic goes back to stable at once, the Rollout and the Application turn
**Degraded**, and the deploy rolls back (dev: tag commit reverted; prod: `env/prod` moved back).
While the canary runs, "Wait for Argo CD" follows the Rollout (`rollout: wait ...` lines in its
log), not the Application's health: a resource that is Degraded for a moment during a pause
does not fail the deploy. It fails when the Rollout is aborted or Degraded, or the AnalysisRun
fails or errors.

**Needs:** argocd-install has run (it installs the Rollouts controller, namespace `argo-rollouts`),
and Prometheus runs (deploy workflow, job "monitoring"). Without Prometheus every canary aborts,
and a Prometheus restart can abort a canary in flight: merge changes that restart it only with no
Rollout progressing (section 12, "Changes that restart Prometheus").
Traffic: a browse-only **loadgenerator** in each namespace (no orders, no cart writes) shops
through the ALB name (`dev.` / `shop.<domain>`) all the time: 15 users in each environment, about
2.1 requests/s, so the canary always gets its share. Without a domain it cannot reach the ALB, and every
frontend canary aborts for lack of traffic (the deploy log warns).

**Why did a canary stop?** A failed Argo CD deploy prints a **Canary report** on the run's Summary
page *before* the rollback resets the Rollout: its abort message, every AnalysisRun with the
values each metric measured, the canary and stable pods, Rollout events and the last 30 lines of
the loadgenerator. The same report, any time: Actions > cluster-status > `boutique-dev` (or
`boutique-prod`), section **Rollouts** (`deploy/rollouts-report.sh`, read-only).

**request-volume failed, but the canary was healthy** (success-rate 1, p95 well under 1 s,
request-volume just under 10, for example 9.74 then 8.85):
- **What it means:** the canary was not shown to be broken. It got too little traffic to be judged,
  and "not enough data" is a failure on purpose. The first check runs 90 s after the canary
  gets its 20%, so it sees at most 90 s of canary traffic:
  `users x 0.14 requests/s x 20% x 90 s`.
  - With 5 users (prod until this fix) that is about 12.6 for a gate of 10: a normal dip in
    Locust's random 1-10 s waits made two checks in a row miss it.
  - With 15 users it is about 38 (3.8x). The helm CI job recomputes this from the rendered chart
    ("Canary gets enough traffic") and fails below 3x.
- **What to do:**
  1. In the Canary report, check that the loadgenerator was running and reaching the ALB (its
     last lines show requests, not connection errors). Check that `loadGenerator.users` was not
     lowered.
  2. Deploy the same tag again: Actions > deploy > `image_tag` = that tag. That is a redeploy, nothing
     is rebuilt.
  3. If it happens again with the loadgenerator healthy, raise `loadGenerator.users` in
     `values-aws.yaml` (each user is about 0.14 requests/s; its CPU request does not change).
  4. Never lower `minRequests`, raise `failureLimit` or drop the request-volume metric to get a
     deploy through: a canary with no traffic would then pass unjudged.

### Demo: a good canary

1. Nothing to start: the loadgenerator already sends steady traffic through the ALB. (For a
   busier demo, Actions > **load-test** adds shoppers, but it calls the in-cluster Service, so
   its requests reach stable pods only.)
2. Actions > **deploy** > Run workflow: `image_tag` = another existing tag (the previous one, from
   the shop footer or Helm/Argo CD history), `target = dev-only`. Any frontend change does it.
3. Watch it in the Argo CD UI (https://argocd.&lt;domain&gt;, section 9) > `boutique-dev` > the
   **Rollout `frontend`**: its two ReplicaSets (stable, canary), the **AnalysisRun** (each
   measurement, green or red), and the step in progress (the Rollout shows Suspended during a pause).
   The weights are in the Ingress `frontend`, annotation `alb.ingress.kubernetes.io/actions.frontend`.
4. After ~6 minutes: Rollout Healthy, the deploy's "Wait for Argo CD" passes, then the smoke test.

### Demo: a failing canary, rolled back by itself

1. On a branch, set in `helm-chart/values-dev.yaml`:
   ```yaml
   frontend:
     faultInject500Percent: 30   # 30% of requests answered with a 500 (health checks never)
   ```
   Open the PR, merge it (prod never gets it: the prod promotion needs dev Synced and Healthy).
2. The loadgenerator keeps shopping through the ALB. Argo CD syncs `main`: the canary pods start, pass
   their readiness probes (health checks are not faulted) and get 20% of the traffic.
3. Within about a minute the AnalysisRun's `success-rate` is ~0.7, below 0.99: two failed
   measurements and the Rollout is **aborted**. Traffic is 100% stable again; the Rollout and
   `boutique-dev` are Degraded. The deploy run that the merge started fails at "Wait for Argo CD"
   ("canary failed ...: aborted" or the failed AnalysisRun) and reverts its tag commit.
4. **Clean up:** revert the PR. Argo CD syncs the stable template back and the Rollout is Healthy.

| Symptom | Cause | Fix |
|---|---|---|
| "The Argo Rollouts CRDs are missing" (deploy-env) | argocd-install has not run since Rollouts were added | Run argocd-install, re-run the deploy |
| "Prometheus for the canary analysis" fails (deploy-env), or AnalysisRun "Error" ("no such host", "connection refused") | The analysis queries `monitoring-kube-prometheus-prometheus.monitoring.svc:9090` (`prometheusAddress`, the Service kube-prometheus-stack creates for release `monitoring`); it does not exist, or the Argo Rollouts controller cannot reach it | The step checks the Service, then runs a one-off AnalysisRun (`prometheus-check-*`, query `vector(1)`) from the controller, pod to pod like a canary, and prints its messages. Service missing: monitoring is not installed (GRAFANA_ADMIN_PASSWORD). Reached but failing: a NetworkPolicy in `monitoring` or `argo-rollouts` (the canary report lists them; the repo creates none) |
| Canary aborted, AnalysisRun red on `request-volume` | The canary got fewer than 10 requests in 2 min: loadgenerator not running, or no domain (it then shops in-cluster, stable only) | `cluster-status`: is `loadgenerator` running? Check `gitops/<env>/values.yaml` has `loadGenerator.frontendUrl` |
| Canary aborted, AnalysisRun red on `p95-latency` | The new version is slower than 1 s at p95 under load | Look at the frontend's dependencies (Grafana); `frontend.canary.analysis.maxP95Seconds` is the threshold |
| "Wait for Argo CD" times out while the Rollout is Progressing | Canary pods not becoming ready (image pull, crash) | `cluster-status`; `progressDeadlineAbort` aborts it after 10 min |
| Argo CD shows the Ingress or Services OutOfSync during a canary | `ignoreDifferences` missing (the Applications were not re-applied) | Run argocd-install (it re-applies both Applications) |

## 11. Upgrade an EKS add-on (on purpose)

Every EKS add-on in `terraform-aws/eks.tf` is pinned: `addon_version = "<exact version>"` with
`most_recent = false` (DESIGN D-16). An add-on never changes by itself; a new release is a
reviewed change. Lesson from the metrics-server incident (section 7): a floating add-on broke
`/openapi/v2` on a new cluster.

1. **See what runs:** Actions > cluster-status (any namespace) > section **EKS add-ons**: name,
   version, status, and the `addon_version` lines to copy. "NO (not managed by Terraform)" marks
   an add-on someone installed outside `eks.tf`.
2. **Pick the new version:** AWS console > EKS > the cluster > Add-ons > the add-on > Edit (only
   to read the version list; do not save), or the add-on's release notes. Check it supports the
   cluster's Kubernetes version (`var.cluster_version`).
3. **One add-on per PR:** change its `addon_version` in `terraform-aws/eks.tf`. The PR's `infra`
   plan must show exactly one change: `module.eks.aws_eks_addon.this["<name>"]` (or
   `.before_compute["<name>"]` for vpc-cni and eks-pod-identity-agent) updated in place,
   `addon_version` old -> new. Anything else in the plan: stop and find out why.
4. **Merge:** `infra` applies it (push to `main`). EKS rolls the add-on's pods.
5. **Check:** cluster-status > **EKS add-ons** shows the new version and `ACTIVE`;
   `kube-system` > API services all `Available=True`; eks-openapi-fix `check` shows protobuf 10/10
   (section 7); one deploy passes (dev, then prod after approval).
6. **Roll back:** revert the PR; `infra` applies the previous version.

Never `most_recent = true`, also not "just for a test": the next `infra` apply, or a new cluster
after `destroy`, would pick up whatever AWS released last.

## 12. Tracing backend (Tempo + OTel Collector, ADR 0010)

**What runs.** In `monitoring`, installed by the deploy workflow's `monitoring` job
(`deploy/monitoring.sh`, exact chart versions in `deploy.yml`).

**Who sends.** Only dev (`tracing.enabled: true` in `helm-chart/values-dev.yaml`; prod is
`false`).
- 12 services send traces: frontend, checkoutservice, productcatalogservice, currencyservice,
  paymentservice, recommendationservice, emailservice (since step 2), and shippingservice, adservice,
  cartservice, inventoryservice and shoppingassistantservice (since step 4). Only the loadgenerator
  and Redis are not traced.- Each gets `ENABLE_TRACING=1`, `COLLECTOR_SERVICE_ADDR` (`tracing.collectorAddr`),
  `OTEL_SERVICE_NAME` (its own name) and `OTEL_RESOURCE_ATTRIBUTES`
  (`deployment.environment=dev,service.namespace=boutique`).
- shoppingassistantservice reaches the collector through its NetworkPolicy rule (4317); the others
  allow all egress.

**The services added in step 4:**
- **shippingservice (Go):** the same `tracing.go` as checkoutservice, with gRPC server spans.
- **adservice (Java):** the OpenTelemetry Java agent 2.32.0 (pinned, SHA-256 checked in the
  Dockerfile). It is always loaded, and active only with `ENABLE_TRACING=1` (`docker-entrypoint.sh`;
  otherwise `OTEL_JAVAAGENT_ENABLED=false`).
  - Only the gRPC instrumentation is on.
  - Measured on one CPU: about 5.7 s to listen and about 190 MiB with the agent active, against
    2.5 s and 110-115 MiB without it. The startup probe allows 180 s.
  - Its memory request is 256Mi in dev (`values-dev.yaml`) instead of 180Mi; the 512Mi limit is
    unchanged.
- **cartservice (C#):** OpenTelemetry .NET 1.19, with ASP.NET Core gRPC server spans (health checks
  left out) and StackExchange.Redis client spans. Redis statements are not verbose: the command,
  never the key (a cart's key is the shopper's session).
- **inventoryservice (Python):**
  - API spans named after the route (`GET /stock/{productId}`), never for `/healthz`, `/readyz` or
    `/metrics`;
  - one `process OrderCreated` consumer span per message, with its DynamoDB and EventBridge calls
    (botocore) as children;
  - no span for the 20 s SQS long poll.
- **shoppingassistantservice (Python):**
  - one `POST /ask` server span, continuing the frontend's trace, with `assistant.outcome`
    (`kill_switch` when paused for the day);
  - one `chat <model>` span per Bedrock call, with `gen_ai.request.model`, `gen_ai.usage.input_tokens`,
    `gen_ai.usage.output_tokens`, `assistant.step`, `assistant.tools` and `assistant.outcome` (`ok`,
    `rate_limited`, `timeout`, `error`);
  - catalog gRPC client spans;
  - never the question, the answer, the session ID or its hash. botocore is not instrumented, and
    errors are not recorded as span events.
- **frontend:** the call to the assistant carries the trace (otelhttp transport). One trace covers
  frontend, assistant, Bedrock and the catalog.

**What the services do** (ADR 0010, step 3; code in `tracing.go`, `tracing.js`, `tracing.py`):
- **Service name:** from `OTEL_SERVICE_NAME`, falling back to the service's own name. The Node
  services no longer appear as `unknown_service:node`.
- **Sampling and propagation:** ParentBased(AlwaysOn), which follows the caller's decision; the
  collector decides what is kept. W3C `traceparent` and baggage in every language.
- **No self-tracing:** the Go services export on a gRPC connection without the otelgrpc
  interceptor. Node and Python suppress instrumentation while they export.
- **Frontend span names:** method and route template, like `GET /product/{id}` or
  `POST /cart/checkout` (attribute `http.route`); just `GET` for an unknown path. Never IDs or
  query strings. `X-Forwarded-For` is dropped before tracing, so the shopper's IP is never a
  span attribute.
- **Never in the request path:** spans are batched and exported in the background, and dropped
  when the collector is down. Tests in each service cover this (`tracing_test.go`,
  `tracing.test.js`, `test_tracing.py`).
- **emailservice:** has gRPC server spans whenever `ENABLE_TRACING=1`.

- `otel-collector`: a Deployment with 1 replica. It receives OTLP on 4317 (gRPC) and 4318 (HTTP)
  from `boutique-dev` and `boutique-prod` only. `monitoring/otel-collector.values.yaml`.
  - **Pipelines (since ADR 0011 PR 5):**
    - `traces/in`: memory_limiter, filter, k8s_attributes, then ALL spans go to the connectors
      `spanmetrics` and `servicegraph`, and `forward`;
    - `traces/sampled`: forward, tail_sampling, batch, then Tempo;
    - `metrics/spans`: the connectors' metrics on :8889 for Prometheus (span metrics below).
  - **Resources:** 150m / 384Mi, limit 768Mi. `GOMEMLIMIT` is 614MiB, and `memory_limiter`
    refuses data from 450Mi (soft) and 600Mi (hard).
  - The filter drops, before anything counts them:
    - spans of an OTLP export itself (`rpc.service` =
      `opentelemetry.proto.collector.trace.v1.TraceService`), a defence against self-tracing;
    - gRPC health probes (since 2026-10-18): `rpc.service` = `grpc.health.v1.Health`, or a span
      named `[/]grpc.health.v1.Health/Check` or `/Watch`, server and client side;
    - HTTP health checks (since 2026-10-18): `/_healthz`, `/healthz` and `/readyz` by
      `http.route`, `url.path` or `http.target` (the frontend's kubelet probes and the ALB's
      health check).
  - Tail sampling also drops health checks (gRPC health and `/_healthz`, a second line), and
    keeps errors, traces over 1 s, all of dev and 10% of prod.
  - It decides 30 s after a trace's first span (`decision_wait`; 10 s until 2026-10-17). An
    order's trace crosses EventBridge and SQS, and its inventory and email spans arrive about
    4.5 s or more after PlaceOrder. A span later than 30 s (a retried message) may miss its
    trace.
  - One replica on purpose: tail sampling needs all spans of a trace on one instance. Never scale
    it by replicas.
  - Memory measured on 2026-10-17 (cluster-status): p95 85Mi, max 86Mi, against a 256Mi request
    and 512Mi limit, with `decision_wait` still at 10 s. With 30 s, expect up to about 3x the
    in-flight spans (a few MiB at today's rate). Check the next report.
- `tempo`: a StatefulSet with 1 replica, single binary, OTLP receivers only.
  - Traces are on a 2 GiB `emptyDir` with 24 h retention, lost when the pod restarts.
    `monitoring/tempo.values.yaml`.
  - **A Tempo restart loses all stored traces. That is expected** (local disk, ADR 0010). A
    resources or config change to Tempo restarts it on the next deploy, so traces from before
    that deploy are gone. Prometheus, Grafana and the shop are not affected.
  - Memory: request 1024Mi, limit 1536Mi, `GOMEMLIMIT` 1350MiB. That's sized from a 874Mi max
    on 2026-10-17, which was close to the old 1Gi limit.
  - Queried by Grafana only, through the data source **Tempo** (uid `tempo`).
- NetworkPolicies `otel-collector` and `tempo` (`monitoring/tracing-networkpolicies.yaml`). They
  select only these pods; there is no default deny in `monitoring`.
- **Chart versions are pinned** in `deploy.yml`: kube-prometheus-stack `KPS_VERSION` 89.2.4, Tempo
  and the collector. Upgrading kube-prometheus-stack restarts Prometheus, which loses its 24 h of
  metrics (and with them the right-sizing data and any running canary's analysis). So upgrade it
  in a PR of its own, outside a canary.

**Check.**

1. The deploy run, step **Tracing smoke test**:
   - telemetrygen sends 3 traces and 1 error trace from `boutique-dev`;
   - a Job finds the error trace in Tempo through Grafana's data source;
   - both Jobs are removed afterwards.
2. Actions > cluster-status (any namespace):
   - **Tracing backend**: pods, restarts, last termination reason, usage, chart versions,
     NetworkPolicies;
   - **Node capacity**: requests against allocatable, per node and in total. That's how to check
     ADR 0010's capacity estimate.
3. Grafana > Explore > Tempo > Search: service `trace-smoke-<run id>-<attempt>` (last 24 h).

| Symptom | Fix |
|---|---|
| Smoke test: "telemetrygen could not send traces" | Collector pod not Ready (cluster-status > Tracing backend), or the NetworkPolicy `otel-collector` is missing its rule for `boutique-dev` (namespace label `kubernetes.io/metadata.name`) |
| Smoke test: "the error trace ... is not in Tempo" | Collector logs (`kubectl -n monitoring logs deploy/otel-collector`): export errors to `tempo.monitoring.svc:4317` mean Tempo is down or its NetworkPolicy blocks the collector. "HTTP 4xx/5xx" in the query Job means Grafana or the Tempo data source (uid `tempo`) |
| Collector `OOMKilled` or "memory limiter: data refused" | Too many traces in the 30 s decision window. Lower the dev share or raise `limits.memory` and `memory_limiter.limit_mib` together (ADR 0010, Capacity). Never add replicas: that splits traces across instances |
| Collector logs "Could not initialize kube client" or 403 on pods | The ClusterRole `otel-collector` (pods, namespaces, ReplicaSets) or its API egress rule (Kubernetes Service IP and the VPC range on 443) |
| Tempo `OOMKilled`, or evicted for ephemeral storage | Memory limit 1536Mi (`GOMEMLIMIT` 1350MiB); the trace disk is capped at 2Gi. Lower retention, or plan the S3 backend (ADR 0010, Storage) |
| Traces gone after a Tempo restart | Expected: local storage (ADR 0010) |
| Dev traces missing for one service | cluster-status > `boutique-dev`: its pod env must have the four tracing variables, and its start log says "Tracing enabled." (all 12 services; adservice: "Tracing enabled (OpenTelemetry Java agent, ...)"), not "Tracing disabled." |

**Find a trace** (Grafana > Explore > data source Tempo > TraceQL; last 1 h to 24 h):

| Looking for | TraceQL |
|---|---|
| One service | `{ resource.service.name = "checkoutservice" }` |
| Orders (PlaceOrder) | `{ span.rpc.method = "PlaceOrder" }`, or from the shop: `{ resource.service.name = "frontend" && name = "POST /cart/checkout" }` |
| Errors | `{ status = error }`, or for one service: `{ resource.service.name = "frontend" && status = error }` |
| Slow spans (> 500 ms) | `{ duration > 500ms }` |
| Slow traces (> 500 ms end to end) | `{ traceDuration > 500ms }` |
| A slow page | `{ span.http.route = "/product/{id}" && duration > 500ms }` |
| Only dev | `{ resource.deployment.environment = "dev" }` |
| The deploy's smoke test | `{ resource.service.name = "trace-smoke-<run id>-<attempt>" && status = error }` |
| Self-tracing (must be empty) | `{ span.rpc.service = "opentelemetry.proto.collector.trace.v1.TraceService" }` |
| Assistant questions, from the shop | `{ resource.service.name = "frontend" && name = "POST /assistant" }` (one trace: frontend, assistant, Bedrock, catalog) |
| Slow Bedrock calls (> 3 s) | `{ span.gen_ai.system = "aws.bedrock" && duration > 3s }` |
| Assistant errors | `{ resource.service.name = "shoppingassistantservice" && status = error }` |
| Bedrock throttling | `{ span.assistant.outcome = "rate_limited" }` |
| Questions refused by the daily cap | `{ span.assistant.outcome = "kill_switch" }` |
| Heavy token use | `{ span.gen_ai.usage.input_tokens > 3000 }`, `{ span.gen_ai.usage.output_tokens > 500 }` |
| Questions that needed 3 or more model calls | `{ name = "POST /ask" } >> { span.gen_ai.system = "aws.bedrock" && span.assistant.step >= 2 }` |
| Ads | `{ resource.service.name = "adservice" }` |
| Orders reserved by inventory | `{ resource.service.name = "inventoryservice" && name = "process OrderCreated" }` |
| Cart calls to Redis | `{ resource.service.name = "cartservice" && kind = client }` |

Only kept traces are there: health checks are dropped, and in prod only 10% of normal traces
(plus all errors and slow ones). A query that finds nothing for an old time range may just be
past Tempo's 24 h, or a Tempo restart.

**Trace IDs in the logs (ADR 0011, step 6).** All 12 services add `trace_id`, `span_id`
(lower-case hex, as in `traceparent`) and `trace_flags` (`"01"` sampled, `"00"` not) to every
log line written during a traced request. The names are the same in every language (ADR 0011).

| Language | Services | Where |
|---|---|---|
| Go | frontend, checkout, catalog, shipping | `logtrace.go`, a logrus hook |
| Node | currency, payment | `tracing.js` `logTraceFields`, pino `mixin` |
| Python | email, recommendation, assistant, inventory | `tracing.py` `log_trace_fields`, in each JSON formatter |
| Java | adservice | the OTel agent's context data, mapped by `boutique-log.json` (JsonTemplateLayout); `TraceFlagsResolverFactory` keeps only the sampled bit (the agent writes `"03"`) |
| .NET | cart | `CartLog.cs`, JSON lines for the cart's request logs |

- **When the fields are absent:**
  - while tracing is off (`tracing.enabled: false`), whatever `traceparent` a request carries;
  - on lines written outside a request.
- **Finding a trace's lines:** Logs Insights on the application log group:
  `filter @message like "<trace id>"`.

**From a trace to its logs, and back (ADR 0011, PR 4).**

- **What Grafana can't do:** Grafana's own "Logs for this span" button in the trace view has no
  CloudWatch support (Grafana 13.2 builds it for Loki, Splunk, Elasticsearch, OpenSearch, Falcon
  LogScale, Google Cloud Logging and VictoriaMetrics Logs only).
- **What does the job:** provisioned correlations (Explore) and the dashboard **Boutique: logs and
  traces** (`monitoring/dashboards/logs-traces.json`).
- **Data:** the logs are the application log group (1 day), the traces are Tempo (24 h).
- **Dev and prod** (prod since 2026-10-18, ADR 0010 step 7). In prod, Tempo keeps errors, traces
  over 1 s and 10% of the rest, so a prod log line's `trace_id` often has no trace in Tempo.

*Dashboard* (Dashboards > Boutique: logs and traces):

1. **Trace to logs:** in **Recent traces (Tempo)**, click a `traceID` > **Logs for this trace**.
   The panel **Log lines of trace …** lists every service's lines for that trace in time order.
   You can also paste a trace ID into the `trace_id` box at the top.
2. **Logs to trace:** in **Recent log lines with a trace_id** (or in the trace's lines), click a
   `trace_id` > **Open trace**. It opens in Tempo.
3. **The time range:** the dashboard's (last 1 h by default). The links keep it. Widen it if a
   trace is older.

*Explore*:

1. **Trace to logs:**
   - Explore > **Tempo** > **Search** (or TraceQL `{ }`): run the query.
   - In the results table, click a `traceID` > **Logs for this trace (CloudWatch)**. It opens the
     Logs Insights query for that trace in a split pane.
   - From a single trace's view (the waterfall), copy the trace ID from the header instead. Then
     use the dashboard box above, or the query below.
2. **Logs to trace:**
   - Explore > **CloudWatch** > **Logs**, log group `/aws/containerinsights/week3-boutique-eks/application`.
   - Run a query that returns a `trace_id` field (this one, or any query with its `trace_id`
     `parse`):

     ```
     parse kubernetes.pod_name /^(?<pod_service>.+)-[a-z0-9]{6,10}-[a-z0-9]{5}$/
     | parse @message /trace_id\W+(?<trace_id>[0-9a-f]{32})/
     | parse @message /span_id\W+(?<span_id>[0-9a-f]{16})/
     | filter ispresent(trace_id)
     | fields @timestamp, coalesce(pod_service, kubernetes.pod_name) as service, trace_id, span_id, @message
     | sort @timestamp desc
     | limit 100
     ```

   - `service` comes from the pod name: every container is named `server`, so
     `kubernetes.container_name` doesn't tell the services apart. A Deployment's or Rollout's pod
     is `<service>-<replica set hash>-<5 characters>` (`frontend-7b9fdd8467-95m7d` becomes
     `frontend`). Any other pod name is shown in full.

   - Click a `trace_id` value > **Open this trace (Tempo)**.
   - The link appears only on a field named exactly `trace_id`, so keep the `parse`.
   - The `parse` reads the ID from the line's text, so it works whether Container Insights nests the
     JSON line or not.

*If a link is missing:*

- **The correlations:** Administration > Plugins and data > Correlations lists both. They're
  provisioned, so they're read-only there; change them in
  `monitoring/kube-prometheus-stack.values.yaml`. CI step "Grafana trace <-> logs links" checks
  them.
- **Their variables are written `$${traceID}` / `$${trace_id}` there.** Grafana expands `${...}`
  in provisioning files as environment variables, so a single `$` leaves the query empty.
- **Grafana's AWS identity:** cluster-status (`monitoring`), section **Grafana's AWS identity**,
  shows the Pod Identity role `week3-boutique-grafana-cloudwatch`, that the pod has the Pod
  Identity variables, and that it started after the association.

**The frontend starts every trace (since 2026-10-17, ADR 0010 note).** A `traceparent` sent by
a client through the ALB no longer continues: each request gets a new root span, sampled by us.

- **The client's context:** kept only as a **span link** on the frontend's server span. In
  Tempo's span view, under Links.
- **Dropped at the edge:** inbound `baggage` always. While tracing is off
  (`tracing.enabled: false`), `traceparent` and `tracestate` too.
- **For you:** search by our trace ID (the logs' `trace_id`), never by a client's.

**Span metrics and the service graph (ADR 0011, PR 5).**

- **Where they come from:** the collector builds them from ALL spans, before tail sampling, so
  they count every request (Tempo keeps only the sampled traces).
- **How they reach Prometheus:** PodMonitor `otel-collector-agent` (label `release=monitoring`)
  scrapes the collector's :8889 every 30 s.
- **Labels:**
  - `service_name` (= `job`), `span_name`, `span_kind`, `status_code`, `k8s_namespace_name`;
  - the service graph's `client`, `server`, `connection_type`;
  - no pod, instance, user, session, IP or URL.
- **Buckets:** 5 ms to 5 s.
- **Exemplars:** trace IDs on the histograms (OpenMetrics), linked to Tempo in Grafana (below).
- **Dev and prod** (prod since 2026-10-18): `k8s_namespace_name` tells them apart. They count
  every span, also the 90% of normal prod traces that Tempo does not keep.

| Metric | What | PromQL example |
|---|---|---|
| `traces_spanmetrics_calls_total` | Spans per service, span name, kind, status | Error ratio of the frontend's routes: `sum by (span_name) (rate(traces_spanmetrics_calls_total{service_name="frontend", span_kind="SPAN_KIND_SERVER", status_code="STATUS_CODE_ERROR"}[5m])) / sum by (span_name) (rate(traces_spanmetrics_calls_total{service_name="frontend", span_kind="SPAN_KIND_SERVER"}[5m]))` |
| `traces_spanmetrics_latency_bucket` (`_sum`, `_count`) | Span duration histogram, in seconds | p95 per service (server spans): `histogram_quantile(0.95, sum by (le, service_name) (rate(traces_spanmetrics_latency_bucket{span_kind="SPAN_KIND_SERVER", k8s_namespace_name="boutique-dev"}[5m])))` |
| `traces_service_graph_request_total` | Requests from `client` to `server`, per namespace (`client_k8s_namespace_name`, `server_k8s_namespace_name`) | Calls per edge: `sum by (client, server) (rate(traces_service_graph_request_total[5m]))` |
| `traces_service_graph_request_failed_total` | The failed ones | Failure ratio per edge: `sum by (client, server) (rate(traces_service_graph_request_failed_total[5m])) / sum by (client, server) (rate(traces_service_graph_request_total[5m]))` |
| `traces_service_graph_request_server_seconds_bucket`, `..._client_seconds_bucket` | Edge latency, seen by the server and the client | p95 per edge: `histogram_quantile(0.95, sum by (le, client, server) (rate(traces_service_graph_request_server_seconds_bucket[5m])))` |

**The names are the ones Grafana's Tempo Service Graph and its RED table query.** Grafana 13.2.1
ships Tempo plugin 13.1.5, whose `graphTransform.ts` queries `traces_spanmetrics_calls_total`,
`traces_spanmetrics_latency_bucket`, `traces_service_graph_request_total`,
`traces_service_graph_request_failed_total` and `traces_service_graph_request_server_seconds_*`.
For that, the collector does two things:

- sets the connector's namespace to `traces.spanmetrics`;
- renames its duration histogram to `latency` with no unit (the values stay in seconds).

CI checks both.

**Exemplars: from a latency point to an example trace (ADR 0011, PR 6).** On every
`traces_spanmetrics_latency_bucket` series the collector attaches a few example spans, as
`trace_id` and `span_id` labels. Prometheus keeps them, and Grafana opens a `trace_id` in Tempo.

- **See them:**
  1. Explore > **Prometheus**.
  2. Run a latency histogram query, for example the p95 of the frontend's routes in dev:
     `histogram_quantile(0.95, sum by (le, span_name) (rate(traces_spanmetrics_latency_bucket{service_name="frontend", span_kind="SPAN_KIND_SERVER", k8s_namespace_name="boutique-dev"}[5m])))`
  3. Turn on **Exemplars** under the query (Options), then run it again. Diamonds appear on the
     graph.
  4. Hover over a diamond, then click **Query with Tempo**. The trace opens in a split pane.
- **Not every diamond's trace is in Tempo.** The exemplars come from ALL spans, before tail
  sampling; Tempo keeps errors, traces slower than 1 s and 100% of dev. In dev every trace is
  kept (until its 24 h retention); in prod, 10% of the fast ones (once prod traces).
- **Where they are kept:** Prometheus `exemplar-storage`, a ring buffer of 100,000 exemplars in
  memory (`exemplars.maxSize`). The oldest are overwritten first, and a Prometheus restart
  empties it. `prometheus_tsdb_exemplar_exemplars_in_storage` reaches 100,000 when it is full;
  how far back it goes then is the age of the oldest diamond in Explore.
- **Memory:** about 18 MiB of heap when the buffer is full (measured with Prometheus 3.14.0:
  100,000 exemplars on 5,000 series, 47 MB in use against 29 MB without the flag).
- **The link:** the Prometheus data source's `exemplarTraceIdDestinations`
  (`name: trace_id`, `datasourceUid: tempo`), in `monitoring/kube-prometheus-stack.values.yaml`.
- **Scrape format:** exemplars exist only in OpenMetrics (and protobuf), never in the classic
  text format. Prometheus 3.14 asks for OpenMetrics first by default, so no `scrapeProtocols`
  is set. A feature flag that prefers protobuf (`created-timestamp-zero-ingestion`,
  `st-storage`) needs `scrapeProtocols` with `OpenMetricsText1.0.0` first.
- CI step "Exemplars (Prometheus and Grafana)" checks all of it.

**Changes that restart Prometheus** (exemplar-storage, other `enableFeatures`, its resources or
version):

- **What restarts:** the Prometheus pod (`prometheus-monitoring-kube-prometheus-prometheus-0`).
  The operator passes `enableFeatures` as a container argument, so the StatefulSet changes and
  the pod is replaced. Its 24 h of metrics are in an `emptyDir`, so they're lost. Grafana
  restarts too, as on every monitoring run (`deploy/monitoring.sh`). Nothing else: the
  operator, kube-state-metrics, node-exporter, Tempo and the collector keep running.
- **Why not during a canary:** the frontend canary analysis reads Prometheus (section 10).
  A restart under a running AnalysisRun can abort it:
  - while Prometheus is down, its queries error;
  - after the restart, the old data is gone, so the 2-minute request-volume check finds too
    few requests;
  - `failureLimit: 1` means the second failed measurement aborts the canary.
- **The first deploys after it still work.** The analysis reads only the canary's own pods,
  which start after Prometheus is back, and over short windows:
  - success rate and p95 over `rate(...[1m])`;
  - request volume over `increase(...[2m])`;
  - the first check 90 s after the canary starts (`initialDelay`).

  Data from before the restart is never needed. The `monitoring` job runs before `deploy-dev`
  and waits for the release, so the same run's dev canary starts on the restarted Prometheus.
- **Before merging** (also in the PR template): cluster-status shows no Rollout progressing in
  `boutique-dev` or `boutique-prod`, and no prod approval is pending.
- **Also lost:** the resource usage report (section 13) reads 24 h of data. After the restart
  it shows `SHORT-DATA` for a day.

**The Service Graph (ADR 0011, PR 7).** Who calls whom in dev, how often, how fast and how
often it fails. It's built from ALL spans (the collector's `traces_service_graph_*` metrics in
Prometheus), not from the sampled traces in Tempo.

- **Where:**
  - Dashboards > **Boutique: platform overview**, row **Traces (dev)**: the **Service graph** panel,
    with requests per second, error % and p95 by service under it.
  - Explore > **Tempo** > query type **Service Graph** > Run query. Under the graph there's a
    table of span names: rate, error rate and p90 duration. To keep to dev, add the filter
    `client_k8s_namespace_name="boutique-dev"`.
- **What the drawing means:**
  - **A circle** is a service, or a node it calls with no traces of its own (`redis`, `DynamoDB`,
    `SQS`...). Inside: the average response time (ms) and requests per second it receives.
  - **Its ring:** green for the successful share, red for the failed share. The more red, the
    more of its requests failed.
  - **An arrow** goes from caller to callee. Hover it for that pair's average time and rate.
- **Click** a circle or an arrow for:
  - **Request rate**, **Request classic histogram** (p90) and **Failed request rate**: Prometheus
    queries in Explore;
  - **View traces**: a Tempo search for that service's traces.
- **What you'll see in dev today:**
  - **No orders:** the loadgenerator is browse-only, so there are no checkout, inventory, SQS or
    email edges. `inventoryservice` has spans only when it processes an `OrderCreated` message
    (its HTTP probes are not traced; nothing calls its `/stock` API), so it is missing from the
    graph and from `traces_spanmetrics_calls_total` until someone orders
    (`deploy/order-flow.sh`, or an order in the shop).
  - **No health checks:** the kubelet's gRPC probes of checkoutservice and emailservice (0.2/s
    and 0.4/s) used to show as `user -> checkoutservice` / `user -> emailservice` edges, and the
    frontend's `/_healthz` (kubelet probes and the ALB health check) inflated `user -> frontend`.
    The collector now drops them before the span metrics and the service graph:
    - gRPC `grpc.health.v1.Health/Check` and `/Watch`, server and client side;
    - HTTP `/_healthz`, `/healthz` and `/readyz`;
    - all in `filter/otlp-export`; CI step "Collector pipelines" checks it.

    `user -> frontend` now counts only real requests. Old series fade out within 10 minutes
    (`metrics_expiration`). The panels under the graph keep their
    `span_name!~".*grpc.health.v1.Health/.*|.*/_healthz"` as a second line.
  - **Prod:** the dashboard row is dev only. In Explore, filter on
    `client_k8s_namespace_name="boutique-prod"` for prod's graph.
- **From a slow edge to the logs:**
  1. In the graph, find the arrow with the highest average time, for example `frontend ->
     checkoutservice`. Click it > **Request classic histogram** to see its p90 over time.
  2. The service graph's own histogram has no exemplars; the span metrics do. Go to the **p95
     latency by service (dev, spans)** panel (or Explore > Prometheus with the query in
     "Exemplars" above) and look at the callee (`checkoutservice`). Hover a diamond near the
     slow points > **Query with Tempo**.
  3. The trace opens. In its waterfall, the long bar is where the time went.
  4. Copy the trace ID from the trace's header. Paste it into the `trace_id` box of **Boutique:
     logs and traces**, or click it in Explore's Tempo search results > **Logs for this trace
     (CloudWatch)** ("From a trace to its logs, and back" above).
  5. No diamond, or Tempo says the trace isn't found: the edge's own **View traces** link searches
     Tempo for that service's traces. Sort by duration.
- CI checks it: "Grafana trace <-> logs links" (Tempo's `serviceMap` and `nodeGraph`, the panel,
  exemplars on the latency panel) and "Dashboard PromQL parses (promtool)" (the panels' PromQL
  and the graph's selectors).

**Service graph details:**

- **Virtual nodes:**
  - a client span with no server span becomes an edge to a node named after its `peer.service`,
    `db.system`, `rpc.service`, `messaging.system` or `server.address` (`connection_type="virtual_node"`);
  - examples: `cartservice -> redis`, botocore calls to `DynamoDB`, `SQS`, `EventBridge`, `BedrockRuntime`;
  - a root server span shows as `user -> frontend`.
- **A new series starts at 0, then counts:** use `rate()` / `increase()`, never the raw value.

**One order, one trace (EventBridge and SQS, ADR 0010 step 5).** The async flow
(`terraform-aws/modules/environment/events.tf`, one bus `<prefix>-events`; every queue has a DLQ
after 3 tries):

1. checkoutservice publishes `OrderCreated` (`boutique.checkout`) → `inventory-q` →
   inventoryservice.
2. inventoryservice publishes `InventoryReserved` / `InventoryFailed` (`boutique.inventory`) →
   `order-status-q` → the order-status Lambda.
3. The Lambda publishes `OrderStatusUpdated` (`boutique.orderstatus`) → `notification-q` →
   emailservice.

EventBridge has no message attributes, so the W3C context travels in the event detail:
`"_trace": {"traceparent": "00-…", "tracestate": "…"}`.

- **Who adds it.** Each publisher adds the field only while tracing is on (so never in prod).
- **Spans.** Each publish is a PRODUCER span (`publish <event>`), and each message a CONSUMER
  span (`process <event>`) that is a child of that publish span.
- **The Lambda.** It has no OpenTelemetry. It only copies the field to `OrderStatusUpdated`, so
  the email span is a child of inventory's publish span, with no Lambda span in between.
- **Consumers.** They remove the field before parsing the event. Events without it, or with a
  broken one, are processed as before, in a new trace.
- **Polling.** The 20 s SQS long polls are not spans.
- **Span attributes.** The order ID (`boutique.order_id`) and messaging fields only, never the
  email address.

| Looking for | TraceQL |
|---|---|
| Orders that went all the way to the email | `{ span.rpc.method = "PlaceOrder" } >> { resource.service.name = "inventoryservice" && name = "process OrderCreated" } >> { resource.service.name = "emailservice" && name = "process OrderStatusUpdated" }` |
| One order, by ID (the producer and consumer spans) | `{ span.boutique.order_id = "<order id>" }` |
| Failed message processing (retried, then DLQ) | `{ kind = consumer && status = error }` |

If an order's trace stops at checkout or at inventory, the next consumer has not processed the
message yet, or the message is being retried or is in the DLQ: check the queue and DLQ alarms.
The trace is not the place to read the queue state.

Late spans: the collector decides on a trace 30 s after its first span (`decision_wait`). A
consumer span that comes later (a retried message, a slow Lambda) may be missing from the trace
or kept on its own.

**Turn tracing off for dev** (for example if a dev deploy misbehaves after this switch):

1. Set `tracing.enabled: false` in `helm-chart/values-dev.yaml` and merge. Argo CD rolls the 12
   Deployments without the tracing variables.
   - The frontend change goes through its canary, like any frontend change.
   - The collector and Tempo keep running, so turning tracing back on is the same one-line change.
2. What to expect:
   - **Services:** they start and serve whether tracing is on or off, and whether the collector
     answers or not (checked for each service in ADR 0010, steps 2 to 4). The gRPC dial to the
     collector does not block, and spans are exported in the background.
   - **Collector down while tracing is on:** spans are dropped, never sent again. Spans not yet
     exported when a pod stops are lost too.
   - **Old traces:** they stay in Tempo until its 24 h retention or a Tempo restart.
3. Faster but temporary: `kubectl -n boutique-dev set env deploy/<service> ENABLE_TRACING-`
   (not on the frontend: that starts a canary). Argo CD self-heal puts it back within minutes,
   so use it only to test.

**Tracing in prod (ADR 0010 step 7, since 2026-10-18).** The same 12 services as dev, the same
collector and Tempo.

- **Sampling:** the collector keeps errors, traces over 1 s and 10% of the rest for
  `k8s.namespace.name = boutique-prod` (dev: 100%). The decision comes 30 s after a trace's first
  span.
  - **Checked locally** (collector 0.161.0 and Tempo 2.10.8, 1,000 prod traces): all 37 errors,
    all 24 slow traces and 98 of the other 939 (10.4%) were kept.
- **What Tempo holds:** about 10 to 15% of prod requests. Span metrics and the service graph
  still count every prod span.

**After turning it on, check** (within an hour of the prod deploy):

1. **The prod frontend canary passed:** the deploy run, or cluster-status > `boutique-prod` >
   Rollouts.
   - Its p95 should stay well under the 1 s gate. Each span costs microseconds, and export runs
     in the background, so expect the p95 within a few milliseconds of before.
   - The services' status codes and request path don't change. The frontend's tracing handler
     runs with tracing off too; with it on, it only records spans and keeps a client's
     `traceparent` as a link.
2. **Prod traces in Tempo, about 10%:**
   - Explore > Tempo > TraceQL `{ resource.k8s.namespace.name = "boutique-prod" }`, last 1 h.
   - Compare with the prod frontend's requests in the same hour:
     `sum(increase(traces_spanmetrics_calls_total{k8s_namespace_name="boutique-prod", service_name="frontend", span_kind="SPAN_KIND_SERVER"}[1h]))`.
   - Expect 10 to 15% (errors and slow traces come on top of the 10%). 0 means the prod pods
     don't reach the collector: check their `ENABLE_TRACING`, and NetworkPolicy `otel-collector`
     in `monitoring`.
3. **Collector memory:** cluster-status > `monitoring` (`kubectl top`). It should stay under its
   450Mi soft limit (`memory_limiter` refuses data above it); the limit is 768Mi. It now gets
   about twice dev's spans (prod's traffic is the same 15 users).
4. **Tempo:**
   - **Restarts or `Evicted`:** in cluster-status. Its `emptyDir` has `sizeLimit: 2Gi`; above
     it, the kubelet evicts the pod and the traces are lost.
   - **Disk use** (the image has no shell): `kubectl get --raw
     "/api/v1/nodes/$(kubectl -n monitoring get pod tempo-0 -o jsonpath='{.spec.nodeName}')/proxy/stats/summary"
     | jq '.pods[] | select(.podRef.name == "tempo-0") | .volume[] | select(.name == "tempo-data") | .usedBytes'`.
   - **Expected:** about 0.2 to 0.6 GB after a day (96 bytes per span measured with Tempo 2.10.8;
     ADR 0010 note 2026-10-18).
5. **Prod logs:**
   - Run the Logs Insights query in "From a trace to its logs, and back" with
     `| filter kubernetes.namespace_name = "boutique-prod"` added.
   - Request lines now carry `trace_id`, `span_id` and `trace_flags`.
   - `trace_flags` is `01` on every request: the SDKs record everything, and the 10% is decided
     later, in the collector. So a prod `trace_id` is often not in Tempo.
   - Still no personal data (section 14).

**Turn prod tracing off fast** (a prod canary fails because of tracing, or the collector or Tempo
can't keep up):

1. PR: `tracing.enabled: false` in `helm-chart/values-prod.yaml` (keep the adservice memory
   request), then merge to `main`.
2. The deploy workflow deploys dev (no change there), then waits for the prod approval. Approve
   it; it moves `env/prod`, and Argo CD rolls the 12 prod Deployments without the tracing
   variables. The frontend goes through its canary, a few minutes.
3. What to expect:
   - prod spans stop;
   - Tempo's prod traces age out within 24 h;
   - the prod span-metric series stop within 10 minutes (`metrics_expiration`);
   - prod log lines lose their `trace_id`.
4. **No rush if only the collector or Tempo is down:** the services don't wait for them. Spans are
   dropped (checked for each service in ADR 0010), so prod keeps serving while you prepare the
   PR.
5. **Never `kubectl set env` in prod:** Argo CD's self-heal undoes it, and on the frontend it
   starts a canary.

**Remove** (for example to free capacity). Then delete the Tempo entry from
`additionalDataSources` in `monitoring/kube-prometheus-stack.values.yaml`, and remove the
install lines and the smoke step, or the next deploy installs it all again.

```bash
helm -n monitoring uninstall otel-collector tempo
kubectl -n monitoring delete networkpolicy otel-collector tempo
kubectl delete clusterrole otel-collector --ignore-not-found       # normally removed by the uninstall
kubectl delete clusterrolebinding otel-collector --ignore-not-found
```

## 13. Resource usage report (right-sizing requests)

**Why.** Cluster CPU requests are high while most services use a small share of what they
request. Requests, not usage, decide whether a pod fits on a node. This report gives the real
usage, so requests can be changed from data. It changes nothing itself.

**Run it.** Actions > cluster-status > Run workflow (any namespace). The section **Resource
usage** is in the log and on the run's Summary page.
- A one-off Job in `monitoring` (`deploy/k8s/resource-usage-query.yaml`) runs the queries in
  `deploy/resource-usage/queries.txt` against Prometheus. Prometheus needs no login, so no
  secret is used or printed.
- The Job and its ConfigMap are deleted at the end, pass or fail.
- If Prometheus is down, only this section fails; the others still run.
- One namespace that cannot be reported prints an `ERROR` line in its place; the other
  namespaces and the cluster totals are still printed.

**Read it.** One table per namespace (boutique-dev, boutique-prod, monitoring, argo-rollouts),
one row per workload and container. CPU is in millicores (m), memory in MiB.

| Column | Meaning |
|---|---|
| REPL | Pods running now |
| HPA | For a workload with an autoscaler: `min-max@target%` (CPU target), otherwise `-` |
| CPU avg / p95 / max | `rate(container_cpu_usage_seconds_total[5m])` over the last 24 h, sampled every 2 min; the highest pod of the workload (avg: the mean of its pods). Deleted pods count, so a rollout's old pods are included |
| MEM p95 / max | `container_memory_working_set_bytes` over 24 h: the memory the kubelet uses for evictions, close to what counts against the limit |
| req / lim | Current requests and limits (the current pods). `-` = not set (or not readable): such a container counts as 0 in the totals, with a note on the TOTAL row |
| SUGGEST | CPU: p95 x 1.5, at least 10m, never below the max seen, rounded up to 5m. With a CPU HPA, also at least p95 x 1.75 / target (at 70%: p95 / 0.4), so the HPA reaches its target only at about 1.75x today's p95: a smaller request would make it scale out at today's load. Memory: max x 1.3, at least 32 MiB, rounded up to 8 MiB |
| TOTAL | Requests now and with the suggestions, for all replicas. Rows without data keep their current request |
| Cluster | Allocatable, requests now and with the suggestions (all namespaces: kube-system and other namespaces are counted at their current requests), and the headroom |

Flags, worth a look before changing a row:

| Flag | Meaning | Before changing it |
|---|---|---|
| `CPU-THROTTLE` | max CPU >= 90% of the CPU limit: the container was likely throttled | Raise the limit before lowering anything; check its latency |
| `MEM-OOM` | max memory >= 90% of the memory limit: close to an OOM kill | Raise the memory limit (and keep request <= limit) |
| `CPU-REQ>LIM` / `MEM-REQ>LIM` | The suggested request is above the current limit | The limit must be raised with it, or the suggestion is invalid |
| `SHORT-DATA(<h>)` | Less than 12 h of data (a new cluster, or a new workload) | Wait for a full day. Less data means a new workload, a cluster rebuilt by a manual `infra` destroy and apply (nothing destroys it on a schedule), or a Prometheus restart: it keeps 24 h in the pod, lost when the pod is replaced |
| `NO-DATA` | No usage series (just started, or not scraped) | Keep the current request |
| `HPA` | The workload is autoscaled: its suggestion uses the HPA rule above | Change the request and the HPA target together; a lower request means more replicas at the same load |
| `NO-REQUEST` | A CPU or memory request is not set: the scheduler reserves nothing for it (the boutique namespaces have a LimitRange, `monitoring` does not) | Set a request; the suggestion is a starting point |

**Use it.** Change requests in a separate PR, a few services at a time, in
`helm-chart/values*.yaml`.
- Prefer a day that includes a load test (`load-test` workflow). Otherwise the max only shows
  the loadgenerator's light traffic, and a suggestion based on it is too low for real load.
- Keep HPA targets in mind: autoscaling uses CPU as a % of the request. A lower request scales out
  at a lower load (`autoscaling.targetCPUUtilization`).
- After the change, run the report again a day later. Check the flags, restarts
  (cluster-status > Namespace snapshot) and the canary's p95.

**The requests in use (2026-10-17).** These come from this report: about 6 h of data at 15
users (the loadgenerator's steady browse-only traffic, no load test). They are the same in dev
and prod, in `helm-chart/values-aws.yaml`, requests only; the limits are in `values.yaml`.

- **HPA services** (frontend, currency, catalog, cart, recommendation; CPU target 70%): CPU
  request about **2.5 x CPU p95**, the report's HPA rule (p95 / 0.4). At today's load the HPA
  sees about 40% and scales out only at about 1.75x that load.
- **Other services** (checkout, shipping, email, payment, inventory): **25m floor**. They use
  only a few millicores at this traffic.
- **Memory:** above the measured maximum, and below the limit (currency and email are at
  112Mi of a 128Mi limit, the tightest).
- **Not changed:** adservice (the JVM's start-up needs), loadgenerator (it drives the
  canary's traffic), shoppingassistantservice.

Measured on 2026-10-17 (about 6 h at 15 users; the higher of dev and prod), against the new
requests:

| HPA service | CPU p95 | CPU max | New request | p95 % of request | max % of request |
|---|---|---|---|---|---|
| frontend | 20m | 20m | 55m | 36% | 36% |
| currencyservice | 17m | 22m | 45m | 38% | 49% |
| productcatalogservice | 22m | 22m | 60m | 37% | 37% |
| cartservice | 23m | 27m | 60m | 38% | 45% |
| recommendationservice | 7m | 9m | 25m | 28% | 36% |

All are under the 70% HPA target, even at their max.

To check them, run the report again (Actions > cluster-status), ideally after a day that
includes a `load-test` run:

- **HPA rows:** at the new requests, the CPU p95 should stay well under the 70% target.
- **`MEM-OOM`:** watch for it on currency and email.
- **Restarts:** check them in cluster-status > Namespace snapshot.

## 14. What we never log (ADR 0011)

The container logs of every namespace end up in one CloudWatch log group, which Grafana can
search. So no application log line, at any level, holds:

- the shopper's **email address**, not even masked (the DynamoDB notification row keeps a
  masked one), nor their name or postal **address**;
- **card data**: number, last digits, CVV, expiry. The brand ("visa") and the amount are fine.
  Error messages count too: payment's errors travel to checkout and the frontend, which log
  them;
- the **session ID**, or the cart/checkout **user ID** (it is the session ID), or its hash (the
  assistant's `X-Session-Id`);
- the client **IP**, the **user agent**, **headers**, **cookies** or the **query string**: the
  frontend logs the path, the method and a random request ID;
- the whole **request** object of a call (it can hold all of the above);
- the assistant's **question** or **answer**, or a model error's message text (it can quote
  the question): the outcome and the error kind only.

**What to log instead:** the **order ID**, product IDs, the transaction ID, outcomes, counts
and durations.

**Enforced by:**

- one test per service that writes such data, run by CI. Each test feeds personal data in
  and checks the log output.
- the CI step **no personal data in logs (grep guard)** (`deploy/tests/no-pii-in-logs.sh`).
  It catches obvious single-line cases, such as a log call that names `email`, `userId`,
  `session`, card fields or the request.
  - A line that is fine despite a match ends with a `pii-ok` comment saying why.
  - It doesn't see fields added on another line, which is why the tests exist too.

**Old lines:** lines written before the fix stay in CloudWatch until the log group's
retention removes them.

- The application group is at **1 day**, permanently (`terraform-aws/logs.tf`, ADR 0011 PR 2
  and its 2026-10-17 note). That's for cost and privacy, and it matches Tempo's 24 h of
  traces.
  - CloudWatch deletes expired lines, usually within 72 hours, so the pre-fix lines are gone.
  - There is no 14-day follow-up. Plan investigations around this: lines older than about a
    day are gone.
- **Before PR 2:** no expiry at all.

## 15. The AI shopping assistant in prod (ADR 0009)

**What runs.** In dev and prod:

- **The pod:** `shoppingassistantservice`, one pod, with the same model (Nova Lite,
  on-demand) and limits in both: 600 output tokens per call, 3 tool steps, 15 s per call,
  500 characters per question, 10 questions per minute per shopper.
- **Daily caps** per pod and UTC day: dev 300, prod 100 (`values-prod.yaml`, with the cost math).
- **The shop's page:** the frontend shows `/assistant` because `ASSISTANT_URL` is set.
- **AWS access:** the pod role (`modules/environment/pod-identity.tf`) may only call
  `bedrock:InvokeModel` on that one model, and only from its own namespace.
- **The loadgenerator never asks it.** CI step "Loadgenerator never calls the assistant".

**After turning it on (or any prod deploy that restarts it):**

1. cluster-status (boutique-prod): `shoppingassistantservice` is Ready. Ready means its
   start-up one-token Bedrock call worked, so the role, model ID and network are fine.
2. Actions > **assistant-smoke** > Run workflow (prod). It asks one question through
   `https://shop.<domain>/assistant`, which costs about USD 0.0004 and uses one of the day's
   100 questions.
   - The answer must link catalog products.
   - The question text must not be in the frontend or assistant logs.
   - It prints only the outcome and product IDs.
3. Grafana: `assistant_requests_total{outcome}`, `assistant_tokens_total{direction}`,
   `assistant_daily_questions_used` against `assistant_daily_question_cap`, and
   `assistant_bedrock_errors_total`. Use `namespace="boutique-prod"`.

**Cost alert path.** The AWS Budget `week3-boutique-bedrock-daily` (`terraform-bootstrap/budgets.tf`)
is account-wide: Service = Amazon Bedrock, so it covers dev and prod together, USD 1/day.

- **The path:** it alerts at 50% and 100% to SNS `week3-boutique-budget-alerts`, then the
  slack-alerts Lambda, then `#boutique-alerts` (row in section 5).
- **Delay:** AWS updates budget costs a few times a day, so an alert can come hours late.
- **The caps are the real limit.** Dev and prod together allow 400 questions, about USD
  0.49 in the worst case, which is under the 50% alert.
- **What an alert means:** more pods than expected (each pod start resets its counter), a
  price change, or Bedrock use outside the assistant.

**Turn it off fast.** Prefer the kill switch: it changes only the assistant's Deployment, so
there is no frontend rollout and no canary.

| How | Effect | Speed |
|---|---|---|
| `dailyQuestionCap: 0` in `values-prod.yaml` (the kill switch), merged to `main` | Every question gets "paused for today"; no Bedrock call. The page stays | One deploy: dev, the prod approval, the promotion to `env/prod` (ADR 0007) |
| `shoppingAssistantService.create: false` in `values-prod.yaml` | No pod, no `/assistant` page: the frontend loses `ASSISTANT_URL` and rolls out through its canary | One deploy, plus the canary |
| `kubectl -n boutique-prod set env deploy/shoppingassistantservice DAILY_QUESTION_CAP=0` (admin access) | The same as the kill switch, at once | Immediate, but temporary: Argo CD self-heal puts it back within minutes, so only as a bridge until the values change is promoted |

Dev works the same way, with `values-dev.yaml`. Revert the values change to turn it back on.

**Known limits.**

- **The cap lives in memory.** A pod restart or a rollout's new pod starts from 0, so the
  bound is cap x pods started that day.
- **Bedrock at pod start.** The pod is Ready only after its first Bedrock call. If Bedrock is
  down when a deploy restarts it, the Application isn't Healthy and the deploy fails after
  `argocd-wait`'s timeout (10 min), even though the shop works. The frontend handles an
  unreachable assistant with a friendly message, and the frontend canary never calls Bedrock.

## Incident log (things that actually happened)

| Incident | Root cause | Fix |
|---|---|---|
| First prod canary (promotion `e430da7`) succeeded ("rollout: done"), then `boutique-prod` Degraded and the deploy rolled `env/prod` back; the "Not Healthy" list was empty | Argo CD rated the frontend HPA Degraded (ScalingActive=False: no metrics yet for the just-replaced pods). The list was empty because Argo CD 3 does not keep per-resource health in the Application | HPA health customization in `deploy/argocd/values.yaml` (no metrics yet = Progressing; only real misconfigurations Degraded), `controller.resource.health.persist`, and `deploy/argocd-unhealthy.sh` (also checks HPAs, Deployments, Rollouts directly) |
| "Prometheus for the canary analysis" timed out although Prometheus ran (dial tcp <pod-ip>:9090) | The check used the API server service proxy: EKS control plane to a pod on 9090, which the node security group does not allow (443/10250/webhooks only). Not the path the analysis uses | The check runs a one-off AnalysisRun, so the Rollouts controller queries Prometheus pod to pod, like a canary |
| Second dev canary aborted: every analysis metric "Error ... lookup prometheus-operated.monitoring.svc: no such host" | The analysis address was not a Service in the cluster | Address = the chart's Service `monitoring-kube-prometheus-prometheus.monitoring.svc:9090`, checked in CI against the rendered monitoring chart; deploy-env queries it before any canary; monitoring installs before dev |
| First dev canary (PR #30) rolled back while healthy: Rollout Paused at step 1/4, AnalysisRun Running, canary pod Ready | `argocd-wait.sh` failed on the Application being Degraded for two polls during a normal pause (the Degraded resource was not the Rollout) | The wait judges the Rollout and its AnalysisRuns while a canary runs; the canary report lists the Application's non-Healthy resources |
| argocd-install: "boutique-dev is not Synced and Healthy at <sha> after 600s" while the log shows `sync=Synced health=Healthy` | `argocd-wait.sh` compared the last sync **operation** revision; the newest commit (the prod tag commit) did not change dev's manifests, so Argo CD ran no sync and that revision never moved | Wait on `status.sync.revision` (the commit Argo CD compared) with Synced, Healthy and no operation running; hard refresh first (also fixes a prod promotion with the same tag) |
| Grafana crash at start ("unlinkat ... read-only file system") | Adding `plugins: [prometheus]` made Grafana try to reinstall a bundled plugin | Removed; `preinstall_disabled: true` |
| Grafana and db-migrate `Pending` | 17 pods per t3.medium, cluster full | 4 nodes, then VPC CNI prefix delegation (110 pods/node) |
| HPA targets `<unknown>` | EKS API couldn't reach metrics-server on 10251 | Node SG rule from the cluster SG (since replaced: metrics-server is now the Helm chart on 10250, section 7) |
| Argo CD "failed to load open api schema", Helm "error validating data" (new cluster, EKS 1.35) | EKS metrics-server add-on (`most_recent`) publishes OpenAPI that cannot be converted to protobuf: `/openapi/v2` protobuf 503, JSON 200 | Add-on removed, upstream Helm chart in `deploy-env.yml`; rule: pin add-on versions (section 7) |
| Grafana 503 during stress test | Grafana OOMKilled at 384Mi | Limit 768Mi |
| `destroy` failed on Redis | ElastiCache still deleting | Wait, re-run `destroy` |
| cluster-status failed from a branch | OIDC deploy role only trusts `main` | Diagnostics changes go through `main` |
| `.git/index.lock` left behind | Interrupted git command | `Remove-Item .git\index.lock`, then retry |
| Stress p95 ~8 s | One pod per service at its CPU limit | HPA, higher CPU limits, tolerant probes |
