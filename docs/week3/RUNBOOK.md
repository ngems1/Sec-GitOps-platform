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
| Build | Code doesn't compile; Docker Hub / package registry hiccup | Read the build log; re-run failed jobs for a transient error |
| Scan gate | ECR found a CRITICAL vulnerability | Update the base image or dependency. Emergency only: `SCAN_BLOCKING=false` |
| `Read Terraform outputs` | Infrastructure not created (or destroyed) | Actions → infra → `apply`, then re-run deploy |
| `AWS Load Balancer Controller`: `UPGRADE FAILED: error validating "": error validating data: the server is currently unable to handle the request` | Helm's client-side OpenAPI validation breaks on the EKS-managed API `v1.metrics.eks.amazonaws.com` (`kube-system/eks-extension-metrics-api`), even with every APIService `Available=True` ([aws-load-balancer-controller#4543](https://github.com/kubernetes-sigs/aws-load-balancer-controller/issues/4543)) | The step passes `--disable-openapi-validation` (the API server still validates on apply). If it comes back: cluster-status → `kube-system` → "API services" for the APIService conditions. Do not delete the EKS-managed APIService |
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
| HPA shows `<unknown>` targets | metrics-server not reachable | cluster-status → `kube-system`: "metrics API" must be `Available=True`. The node security group must allow 10251/tcp from the cluster SG (`eks.tf`) |

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

## 6. HTTPS and DNS

| Symptom | Fix |
|---|---|
| Browser certificate warning | You're on the raw `*.elb.amazonaws.com` name; use `dev.` / `shop.` / `grafana.<domain>` |
| Name doesn't resolve after a fresh apply | The deploy workflow creates the records (`deploy/dns-record.sh`); run deploy |
| ACM certificate stuck "Pending validation" | The validation CNAMEs must be in the hosted zone (`terraform-aws/dns.tf`); check `DOMAIN_NAME` matches the zone |

## Incident log (things that actually happened)

| Incident | Root cause | Fix |
|---|---|---|
| Grafana crash at start ("unlinkat ... read-only file system") | Adding `plugins: [prometheus]` made Grafana try to reinstall a bundled plugin | Removed; `preinstall_disabled: true` |
| Grafana and db-migrate `Pending` | 17 pods per t3.medium, cluster full | 4 nodes, then VPC CNI prefix delegation (110 pods/node) |
| HPA targets `<unknown>` | EKS API couldn't reach metrics-server on 10251 | Node SG rule from the cluster SG |
| Grafana 503 during stress test | Grafana OOMKilled at 384Mi | Limit 768Mi |
| `destroy` failed on Redis | ElastiCache still deleting | Wait, re-run `destroy` |
| cluster-status failed from a branch | OIDC deploy role only trusts `main` | Diagnostics changes go through `main` |
| `.git/index.lock` left behind | Interrupted git command | `Remove-Item .git\index.lock`, then retry |
| Stress p95 ~8 s | One pod per service at its CPU limit | HPA, higher CPU limits, tolerant probes |
