# GKE monitoring (boutique-gke)

How the GKE shop is monitored (ADR 0014): **Google Cloud Managed Service for Prometheus** (GMP)
and **Cloud Monitoring**, not the Prometheus and Grafana that run on EKS. Nothing to install or
run: the collectors are part of GKE Autopilot.

| Source | What | Cost |
|---|---|---|
| GKE system metrics | CPU, memory, restarts, network of every container and pod | Free |
| The external Application Load Balancer (the Ingress) | Requests by response code, latency, at the edge | Free |
| GMP managed collection: the frontend's `/metrics` (`PodMonitoring`, every 30s) | `frontend_http_requests_total{code}`, `frontend_http_request_duration_seconds` | About $0.11/month |
| GKE's kubelet and cAdvisor packages (`terraform-gcp`, `gke_metric_packages`) | Kubelet and container metrics as Prometheus series | Billed per sample: see [Cost](#cost) |

**Why only the frontend exposes Prometheus metrics:** the backend services export none (on EKS
their rates and latencies come from traces, which GKE doesn't have). The load balancer and system
metrics cover the rest.

**Where it's set up:**
- `terraform-gcp/gke.tf`: `monitoring_config`, which turns on managed collection and the metric
  packages;
- `helm-chart/templates/podmonitoring.yaml`: the frontend's `PodMonitoring`;
- `helm-chart/values-gcp.yaml`: the NetworkPolicy lets the collectors (namespace
  `gke-gmp-system`) reach the metrics port, 9090.

GMP ignores the `prometheus.io/*` annotations the frontend pods carry for EKS.

## Dashboards

In the [Google Cloud console](https://console.cloud.google.com/), project of the GKE environment:

- **The cluster:** Kubernetes Engine > Clusters > `boutique-gke` > **Observability**. CPU, memory,
  restarts, and the nodes Autopilot started.
- **The shop's workloads:** Kubernetes Engine > Workloads, filter namespace `boutique-gke`. Each
  Deployment's page has an **Observability** tab: CPU, memory, restarts per container.
- **The public entry point:** Network services > Load balancing > the load balancer the Ingress
  created (GKE names it; its name contains `boutique-gke-frontend`) > **Monitoring**: requests
  per second, by response code, and latency.
- **Built-in dashboards:** Monitoring > Dashboards > *GKE*. Filter on cluster `boutique-gke` and
  namespace `boutique-gke`.
- **Anything else, with PromQL:** Monitoring > **Metrics Explorer** > the *PromQL* tab. The queries
  below work there.

**First check after a deploy:** in Metrics Explorer, `up{namespace="boutique-gke"}` must be `1`
for the frontend. `0`, or no result after a few minutes, means the collectors can't scrape it:
check the `PodMonitoring` and the frontend NetworkPolicy.

## Key metrics

PromQL for the frontend's own metrics, and for GKE system metrics through their PromQL names.
For example, `kubernetes.io/container/restart_count` is `kubernetes_io:container_restart_count`.

| What | PromQL |
|---|---|
| Requests per second | `sum(rate(frontend_http_requests_total[5m]))` |
| Error rate (share of 5xx) | `sum(rate(frontend_http_requests_total{code=~"5.."}[5m])) / sum(rate(frontend_http_requests_total[5m]))` |
| Latency, p95 (seconds) | `histogram_quantile(0.95, sum by (le) (rate(frontend_http_request_duration_seconds_bucket[5m])))` |
| Pod restarts, last hour | `sum by (container_name) (increase(kubernetes_io:container_restart_count{namespace_name="boutique-gke"}[1h]))` |
| CPU per container (cores) | `sum by (container_name) (rate(kubernetes_io:container_cpu_core_usage_time{namespace_name="boutique-gke"}[5m]))` |
| Memory per container (bytes) | `sum by (container_name) (kubernetes_io:container_memory_used_bytes{namespace_name="boutique-gke", memory_type="non-evictable"})` |

**The load balancer's view** (Metrics Explorer, resource *Global External Application Load
Balancer Rule*):
- `loadbalancing.googleapis.com/https/request_count`, grouped by `response_code_class`;
- `loadbalancing.googleapis.com/https/total_latencies`.

That's what shoppers see, the load balancer's own errors included.

**What "normal" looks like:** the loadgenerator sends steady traffic (10 users), so a flat zero
request rate means the frontend, or its scraping, is down. The frontend's targets are the same as
on EKS: an error rate under 1% and a p95 under 1s.

## Alerts

Monitoring > **Alerting** > **Create policy** > *PromQL*:

1. **Error rate above 5%:**

   ```promql
   sum(rate(frontend_http_requests_total{code=~"5.."}[5m])) / sum(rate(frontend_http_requests_total[5m])) > 0.05
   ```

   For 5 minutes.
2. **Restart loop** (a container restarting again and again):

   ```promql
   increase(kubernetes_io:container_restart_count{namespace_name="boutique-gke"}[15m]) > 3
   ```

3. **Slow:**

   ```promql
   histogram_quantile(0.95, sum by (le) (rate(frontend_http_request_duration_seconds_bucket[5m]))) > 1
   ```

   For 10 minutes.
4. **Nothing scraped** (the frontend or its metrics gone):

   ```promql
   absent(up{namespace="boutique-gke"} == 1)
   ```

   For 10 minutes.

Then choose a **notification channel**: Monitoring > Alerting > *Edit notification channels* >
Email. Alert policies and channels created in the console aren't in Terraform. They belong to the
project, not to `terraform-gcp`, so they survive its destroy. Putting them in Terraform is a later
step: `gha-deploy` would need the alert policy and notification channel editor roles.

## Cost

Managed Service for Prometheus bills **$0.060 per million samples ingested** (first 50 billion a
month, no free allowance). System metrics and the load balancer's metrics are free.

| Source | Estimate |
|---|---|
| The frontend's `/metrics` | About 20 series every 30s: about 1.9 million samples a month, **about $0.11** |
| Kubelet and cAdvisor packages | It depends on how many series GKE's packages produce here, which isn't documented per cluster. Roughly **$2-10 a month** for this cluster size |

**To measure the packages after a day:** Monitoring > **Metrics Management** shows the samples
ingested per metric over the last 30 days.

**To stop paying for them:** set `gke_metric_packages = ["SYSTEM_COMPONENTS"]` in `terraform-gcp`
(variable), then run infra-gcp plan and apply. The free system metrics already cover CPU, memory
and restarts.

The whole GKE environment is about $53 a month if left running (`terraform-gcp/README.md`).
Destroying it between sessions also stops all these costs.

## Documentation

- [Managed Service for Prometheus, managed collection](https://cloud.google.com/stackdriver/docs/managed-prometheus/setup-managed)
- [PodMonitoring](https://cloud.google.com/stackdriver/docs/managed-prometheus/setup-managed#gmp-pod-monitoring)
- [Configure metrics collection on GKE (packages)](https://cloud.google.com/kubernetes-engine/docs/how-to/configure-metrics)
- [PromQL in Cloud Monitoring, and the names of Cloud Monitoring metrics in PromQL](https://cloud.google.com/monitoring/promql)
- [Load balancing metrics](https://cloud.google.com/load-balancing/docs/https/https-logging-monitoring)
- [Alerting with PromQL](https://cloud.google.com/monitoring/promql/create-promql-alerts-console)
- [Managed Service for Prometheus pricing](https://cloud.google.com/managed-prometheus#pricing)
