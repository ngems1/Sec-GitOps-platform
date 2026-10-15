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
| Grafana URL times out | Your IP isn't in `MONITORING_ALLOWED_CIDR` (update it, re-run deploy), or the ALB is still starting |
| Grafana 503 / restarts | cluster-status → `monitoring`. It was `OOMKilled` at 384Mi; the limit is 768Mi |
| "Datasource prometheus was not found", empty Prometheus settings | Bundled plugins broke on the read-only disk; `preinstall_disabled: true` in `grafana.ini` must stay |
| CloudWatch panels "No data" | Traffic needed (run load-test), time range ≥ 30 min; cluster-status → `monitoring` runs the dashboard queries directly against AWS to separate a Grafana problem from a missing metric |
| CloudWatch "AccessDenied" in Grafana | The Grafana Pod Identity role (`terraform-aws/monitoring.tf`) lacks that read action; add it there, never broader than read-only |
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

## Incident log (things that actually happened)

| Incident | Root cause | Fix |
|---|---|---|
| Grafana crash at start ("unlinkat ... read-only file system") | Adding `plugins: [prometheus]` made Grafana try to reinstall a bundled plugin | Removed; `preinstall_disabled: true` |
| Grafana and db-migrate `Pending` | 17 pods per t3.medium, cluster full | 4 nodes, then VPC CNI prefix delegation (110 pods/node) |
| HPA targets `<unknown>` | EKS API couldn't reach metrics-server on 10251 | Node SG rule from the cluster SG (since replaced: metrics-server is now the Helm chart on 10250, section 7) |
| Argo CD "failed to load open api schema", Helm "error validating data" (new cluster, EKS 1.35) | EKS metrics-server add-on (`most_recent`) publishes OpenAPI that cannot be converted to protobuf: `/openapi/v2` protobuf 503, JSON 200 | Add-on removed, upstream Helm chart in `deploy-env.yml`; rule: pin add-on versions (section 7) |
| Grafana 503 during stress test | Grafana OOMKilled at 384Mi | Limit 768Mi |
| `destroy` failed on Redis | ElastiCache still deleting | Wait, re-run `destroy` |
| cluster-status failed from a branch | OIDC deploy role only trusts `main` | Diagnostics changes go through `main` |
| `.git/index.lock` left behind | Interrupted git command | `Remove-Item .git\index.lock`, then retry |
| Stress p95 ~8 s | One pod per service at its CPU limit | HPA, higher CPU limits, tolerant probes |
