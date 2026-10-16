# Monitoring: Prometheus + Grafana

| Piece | Where | What it does |
|---|---|---|
| **Prometheus** | namespace `monitoring` (kube-prometheus-stack) | Scrapes pods (CPU, memory, restarts, readiness), nodes, and the services that expose `/metrics`: inventoryservice (orders reserved / failed / duplicate, processing time) productcatalogservice (cache hits / misses, MySQL and Redis errors) and the frontend (HTTP requests by status code, latency histogram: the Argo Rollouts canary analysis, ADR 0008). 24 h of history. |
| **Grafana** | same namespace, its own ALB | Dashboards. Data sources: Prometheus, and **CloudWatch** (ALB, SQS, RDS) through a read-only Pod Identity role (`terraform-aws/monitoring.tf`). |
| **Alerts** | CloudWatch alarms → SNS → Slack `#boutique-alerts` | Unchanged (docs/week3/SLACK.md). Alertmanager is not used. |

Installed and updated by the **deploy** workflow (job `monitoring`, after dev), from:
`monitoring/kube-prometheus-stack.values.yaml`, `monitoring/dashboards/*.json`, `monitoring/grafana-ingress.yaml`, `deploy/monitoring.sh`.

## One-time setup (2 GitHub settings)

**Settings → Secrets and variables → Actions**:

| Kind | Name | Value |
|---|---|---|
| Secret | `GRAFANA_ADMIN_PASSWORD` | A strong password for the Grafana `admin` user |
| Variable | `MONITORING_ALLOWED_CIDR` | Your public IP + `/32`, e.g. `203.0.113.7/32` (search "what is my ip"). Several: comma separated. `0.0.0.0/0` is refused. |

Without the secret, the `monitoring` job is skipped. Without the variable, Grafana runs but has no address.
If your IP changes (home / office), update the variable and re-run **deploy** (or the next deploy picks it up).

## Open Grafana

1. The **deploy** run's Summary (job `monitoring`) and the Slack deploy message show `Grafana: http://boutique-monitoring-....elb.amazonaws.com`. A new ALB needs 2-3 minutes before it answers.
2. Log in: `admin` / your `GRAFANA_ADMIN_PASSWORD`.
3. **Dashboards → Browse → Boutique: platform overview**. The chart's own *Kubernetes / Compute Resources* dashboards are there too.

## The Boutique dashboard

| Row | Panels | Source |
|---|---|---|
| **SLIs** | Availability (non-5xx %, SLO 99.5%), p95 latency (SLO 1 s), order success rate, pods not ready, for dev and prod | CloudWatch (ALB), Prometheus |
| **Shop traffic** | Requests/min, 5xx (shop vs ALB), latency p95/p50 | CloudWatch (ALB) |
| **Application** | Catalog cache hit rate, MySQL loads and errors, orders reserved / failed / duplicate, inventory processing p95 and errors | Prometheus |
| **Event flow** | Messages waiting per queue, dead-letter queues | CloudWatch (SQS) |
| **Kubernetes** | CPU and memory per pod, restarts, node CPU and memory | Prometheus |
| **Databases** | RDS CPU, connections, free storage, read/write latency | CloudWatch (RDS) |

## Load test and stress test

**Actions → load-test → Run workflow** (dev only, stops by itself, the Locust summary is on the run's Summary page):

| Mode | What it does | Use it for |
|---|---|---|
| `load` | Steady 5-50 shoppers with normal pauses (the loadgenerator image's Locust file) | Making the dashboard move, the demo |
| `stress` | **Stepped ramp-up** to 100-800 busy shoppers (~1 request/s each), +N every minute until 2/3 of the run, then hold. Spread over several Locust pods (one per ~150 shoppers). `deploy/load/stress_locustfile.py`, mounted from a ConfigMap. | Finding the **breaking point**: the load at which p95 latency and errors start to climb |

Restock: `normal` = 50 per product, the Mug at 2 (some orders fail: realistic); `unlimited` = 100000 per product (use it for stress, so orders fail because of capacity, never because of stock); `none`.

**Reading a stress test** on the dashboard (time range: last 30 min):
- *Shop traffic*: requests/min rise step by step, then flatten when the shop can't serve more.
- *SLIs*: p95 latency is the first to degrade (orange > 0.5 s, red > 1 s); 5xx follow when pods time out.
- *Kubernetes*: the saturated service is the one whose CPU stays at its limit (frontend: 200m). Without autoscaling, its latency grows with every step.
- *Event flow*: queues should stay near 0; if they grow, a consumer can't keep up.
- *prod*: its panels should stay flat and green; dev is isolated by CPU/memory limits, NetworkPolicies and its own databases.

The orders are real (MySQL rows, DynamoDB writes, events, Lambda runs): a 15-minute stress test at 400 shoppers creates a few thousand orders and costs cents.

## Cost and capacity

A t3.medium runs at most 17 pods (VPC CNI). Monitoring adds about 8 pods, so the cluster has **4 nodes** (`node_desired_size`). On a running cluster, Terraform does not change the node count of the existing node group: the 4th node arrives with the next `infra → destroy` + `apply`.
Extra cost while running: the 4th node (~$1/day) and Grafana's ALB (~$0.55/day).

## Troubleshooting

| Symptom | Check |
|---|---|
| `monitoring` job skipped | The `GRAFANA_ADMIN_PASSWORD` secret is missing |
| Grafana URL times out | Your IP is not in `MONITORING_ALLOWED_CIDR`, or the ALB is still starting (2-3 min) |
| CloudWatch panels empty | ALB metrics only appear once the shop gets traffic; use a time range of 30 min or more. Re-running deploy restarts Grafana (fresh AWS credentials). |
| "Datasource prometheus was not found" | The data sources are created by `monitoring/kube-prometheus-stack.values.yaml` (`additionalDataSources`); re-run deploy, it restarts Grafana to load them |
| Prometheus data source has an empty settings page, "Alerting: Not supported", "Datasource was not found" | Grafana tried to update its bundled plugins at startup and failed on the read-only disk, leaving them stopped. `grafana.ini` > `plugins` > `preinstall_disabled: true` prevents this; check with Actions → cluster-status → `monitoring` (section "plugin / error messages": no "Failed to install plugin") |
| Application panels empty | Prometheus → Status → Targets: job `kubernetes-pods` should list inventoryservice, productcatalogservice and frontend as UP |
| Pods `Pending` | Not enough pod slots: the cluster needs its 4th node (see above) |
