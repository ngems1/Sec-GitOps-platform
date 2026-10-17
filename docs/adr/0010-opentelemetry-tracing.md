# 0010: OpenTelemetry tracing (OTel Collector + Grafana Tempo in the cluster)

Status: proposed (Phase 3, OpenTelemetry tracing). Date: 2026-10-16. Investigation only: nothing
is implemented by this ADR.

> **Update 2026-10-17:** this ADR first said `terraform-aws` is destroyed and re-created every day.
> It is not: nothing destroys it on a schedule. Only a manual `infra` workflow run with
> `action = destroy` does (SETUP.md suggests it at the end of a working day), and the cluster
> can run for days. Prometheus and Tempo lose their in-pod history when their pod is replaced,
> not on a timetable. The decisions below are unchanged. The reasons and estimates that
> relied on a daily rebuild are corrected in place.

## Context

Phase 3 adds distributed tracing: one shopper request (ALB, frontend, then the gRPC services and
the AWS calls) seen as one trace in Grafana, next to the metrics we already have. Today the stack
has Prometheus and Grafana (kube-prometheus-stack, `monitoring` namespace, 24 h retention in the
pod), CloudWatch Container Insights for container logs, and no trace backend. The cluster is
small (t3.medium nodes). `terraform-aws` is destroyed only by a manual `infra` run with
`action = destroy`, often at the end of a working day but not on a schedule. Prometheus keeps its
history in the pod, so it loses it when the pod is replaced (a node change, an upgrade, a destroy).

### What the code already has (inventory, 2026-10-16)

| Service | Language | Tracing code today | Turned on by | SDK versions |
|---|---|---|---|---|
| frontend | Go | yes: `otelhttp` server, `otelgrpc` clients, W3C propagator; OTLP gRPC exporter, `AlwaysSample` | `ENABLE_TRACING=1` + `COLLECTOR_SERVICE_ADDR` | otel 1.16.0, contrib 0.42.0 |
| checkoutservice | Go | yes: `otelgrpc` server and clients, W3C propagator, OTLP gRPC, `AlwaysSample`. MySQL and EventBridge calls not traced | same | otel 1.16.0, contrib 0.42.0 |
| productcatalogservice | Go | yes: `otelgrpc` server and clients, W3C propagator, OTLP gRPC, `AlwaysSample`. MySQL and Redis calls not traced | same | otel 1.16.0, contrib 0.42.0 |
| currencyservice | Node.js | yes: gRPC instrumentation, OTLP gRPC exporter with a `SimpleSpanProcessor` (one export per span) | same | api 1.4.1, sdk-node 0.41.2, sdk-trace 1.15.2, **exporter-otlp-grpc 0.26.0** (old, deprecated package) |
| paymentservice | Node.js | same as currencyservice | same | same |
| recommendationservice | Python | yes: gRPC client and server instrumentation, OTLP gRPC, batch processor | same (`COLLECTOR_SERVICE_ADDR` defaults to `localhost:4317`) | opentelemetry 1.19.0 / 0.40b0 |
| emailservice | Python | partly: gRPC server spans only, and only when `ENABLE_TRACING` is set (the instrumentor sits after that check). The SQS notification consumer has no spans | same | opentelemetry 1.19.0 / 0.40b0 |
| shippingservice | Go | **no**: `initTracing()` is an empty TODO; logs "Tracing enabled, but temporarily unavailable" | `DISABLE_TRACING` (inverse flag, does nothing) | none (OpenCensus only as an indirect dependency) |
| adservice | Java 21 | **no**: `initTracing()` is a TODO; `grpc-census` dependency left over | `DISABLE_TRACING` (does nothing) | none |
| cartservice | C# (.NET 10) | **no** | none | none |
| inventoryservice | Python (http.server, boto3) | **no** | none | none |
| shoppingassistantservice | Python (http.server, boto3, gRPC client) | **no** | none | none |
| loadgenerator | Python (Locust) | no (not needed: traces start at the frontend) | none | none |

Also found:

- No service sets `service.name`. The SDKs read `OTEL_SERVICE_NAME` / `OTEL_RESOURCE_ATTRIBUTES`
  from the environment, so the chart can set them without code changes.
- No log line carries a trace ID.
- Trace context does not cross EventBridge and SQS (checkout to inventory and email), and the
  order-status Lambda has no tracing.
- The EKS add-on `amazon-cloudwatch-observability` can inject an OpenTelemetry agent into every
  pod (Application Signals auto-monitor). We turned that off because it made the adservice JVM
  start too slowly for its liveness probe and is billed per request (`terraform-aws/eks.tf`).

### Helm chart today

- `ENABLE_TRACING=1` is templated for the 7 instrumented services, but only behind
  `googleCloudOperations.tracing` (an upstream GCP flag).
- `COLLECTOR_SERVICE_ADDR` is templated behind `opentelemetryCollector.create`, and points at an
  in-namespace collector (`templates/opentelemetry-collector.yaml`). That collector is
  GCP-only: a `googlecloud` exporter, an init container that curls `metadata.google.internal`,
  `busybox:latest` and collector 0.83.0. It cannot be used on AWS as it is.
- Missing:
  - any tracing env for shippingservice, adservice, cartservice, inventoryservice and
    shoppingassistantservice;
  - `OTEL_SERVICE_NAME` and `OTEL_RESOURCE_ATTRIBUTES` (environment, namespace);
  - an AWS-neutral `tracing.*` values block;
  - a per-environment switch (dev on, prod off);
  - a CI check on prod.

### NetworkPolicies today

The namespace has a deny-all policy plus one policy per service (`templates/common.yaml`).
Egress to a collector at `<collector>.monitoring.svc:4317` (OTLP gRPC):

| Service | Egress today | Needs for a collector in `monitoring` |
|---|---|---|
| frontend, checkout, productcatalog, currency, payment, recommendation, email, shipping, ad, cart, inventory, loadgenerator, redis | `- {}` (all egress) | nothing |
| shoppingassistantservice | DNS, productcatalogservice:3550, TCP 443, Pod Identity Agent | a rule to namespace `monitoring`, pods of the collector, TCP 4317 |

On the receiving side:

- The in-namespace collector's policy lists the callers it accepts, and misses inventoryservice
  and shoppingassistantservice.
- The `monitoring` namespace has no NetworkPolicy, so a collector there accepts any pod in the
  cluster. Phase 3 should add policies there:
  - collector: 4317 only from `boutique-dev` and `boutique-prod`;
  - Tempo: from the collector and Grafana only.

## Options considered

### Backend

1. **Grafana Tempo in the cluster** (`grafana/tempo` chart, monolithic mode).
   - Storage: local (the pod's disk, lost with the pod, like Prometheus today) or S3 (survives
     restarts; needs a bucket and a Pod Identity role).
   - Tempo is a core Grafana data source, so no plugin is needed. That matters here: Grafana's
     plugin downloads are disabled because of its read-only disk (`kube-prometheus-stack.values.yaml`).
   - TraceQL search. The metrics-generator turns spans into RED metrics and a service graph,
     with exemplars written to Prometheus.
   - Cost: compute on the existing nodes (about 100m CPU and 512Mi), no AWS bill, no IAM, no
     change to the CI roles' permission boundaries.
   - Cloud-neutral, so the same chart runs on AKS or GKE.
2. **AWS X-Ray** (collector `awsxray` exporter, or OTLP to X-Ray's endpoint with SigV4).
   - Fully managed and kept 30 days, so it survives pod restarts and an `infra` destroy. It also
     has the CloudWatch service map.
   - It needs:
     - a Pod Identity role for the collector (`xray:PutTraceSegments`, `xray:PutTelemetryRecords`);
     - `xray` added to the CI permission boundaries (`terraform-bootstrap/boundaries.tf`) and a
       bootstrap run;
     - the X-Ray Grafana plugin, which is not bundled in Grafana and so is blocked by the
       read-only plugin setup above. Otherwise traces are only viewable in the AWS console.
   - AWS-only: Phase 6 clusters would need another backend or cross-cloud credentials.
   - Cost: USD 5 per million traces recorded after 100,000 free per month, plus USD 0.50 per
     million traces scanned or retrieved after 1 million free (to confirm on the AWS pricing page).
     AWS also has "Transaction Search", with spans in CloudWatch Logs priced per GB; its terms
     need checking before using it.
3. **Jaeger** (v2, built on the OpenTelemetry Collector).
   - In the cluster, with memory or Badger storage, or Elasticsearch/Cassandra for persistence.
   - Jaeger is a core Grafana data source too, and has its own UI.
   - Grafana's trace features (TraceQL, metrics-generator, exemplar links) are built around
     Tempo. Persistent Jaeger storage means running Elasticsearch or Cassandra, too heavy for
     these nodes.

### Collector

1. **OpenTelemetry Collector through its Helm chart** (`open-telemetry/opentelemetry-collector`,
   `contrib` image, deployment mode).
   - One Deployment in `monitoring`. Pipeline: OTLP receiver, then the processors
     `memory_limiter`, `k8sattributes`, `filter` (health checks) and `tail_sampling`, then
     `batch` and the Tempo exporter.
   - Installed and pinned like kube-prometheus-stack, by `deploy/monitoring.sh`.
2. **OpenTelemetry Operator.**
   - Adds CRDs (`OpenTelemetryCollector`, `Instrumentation`) and an admission webhook, which
     needs cert-manager or self-generated certificates. We turned the Prometheus Operator's
     webhooks off for the same reason.
   - Its selling point is auto-instrumentation by injecting agents into pods. We already tried
     that through Application Signals, and it broke the adservice startup.
   - More moving parts than one Deployment.

### Sampling

- All instrumented services sample everything today (`AlwaysSample` in Go; the Node and Python
  defaults).
- Head sampling at the frontend (a fixed ratio) is cheap, but it can't keep "all errors and all
  slow requests".
- Tail sampling in the collector decides after the whole trace has arrived. **The error and
  latency rules only work if every span of a trace reaches the same collector instance.** With
  two replicas behind a Service, spans of one trace are spread over both. Each replica then sees
  part of the trace: it can drop the slow or failing part, or keep a trace with holes.

### Volume and cost estimate

- **Traffic:** the loadgenerator sends about 1.5 requests/s in dev and about 0.8 in prod
  (values comments). One shop page is about 10 spans; the home page converts nine prices.
- **Dev:** about 15 spans/s, so about 54,000 spans an hour, or about 0.5 million on a 10-hour
  day. That is a few hundred MB in Tempo before compression, fine on local disk with 24 h
  retention. The cluster can also run all day (no scheduled destroy): then about 1.3 million
  spans a day, 2.4 times more; Tempo still keeps only 24 h. Watch the 2 GiB disk if dev runs at that
  rate for days.
- **With X-Ray:** about 2.3 traces/s across both environments over 10 hours a day is about
  2.5 million traces a month. Sampling everything would cost about USD 12 a month; keeping 10%
  of prod plus errors would cost about USD 1 to 3. Running 24 h a day, it is about 6 million
  traces and USD 30 a month at 100%.
- **With Tempo:** USD 0 extra (existing nodes); with S3, cents per month.

### Later phases

- **Phase 4, Istio ambient:**
  - ztunnel is L4 only and makes no spans. Waypoint proxies (Envoy) make L7 spans.
  - Istio's Telemetry API sends them over OTLP to a collector named as an extension provider:
    the same `monitoring` collector.
  - The services already forward W3C `traceparent`, so waypoint spans join the application
    traces. Keep W3C tracecontext everywhere and a stable collector address.
- **Phase 6, multi-cloud:**
  - Every cluster runs the same chart and its own collector. Collectors can export to their own
    Tempo, or over OTLP with authentication to one central Tempo.
  - With a collector in front, the backend is a config value of the exporter. X-Ray would tie
    traces to AWS.

### Metrics, traces and logs in Grafana

- **Exemplars:**
  - The frontend's hand-written metrics use the Prometheus 0.0.4 text format, which has no
    exemplars.
  - Without app changes: Tempo's metrics-generator writes span metrics and service-graph
    metrics with exemplars to Prometheus. That needs `enableRemoteWriteReceiver` and the
    `exemplar-storage` feature in kube-prometheus-stack.
  - Grafana then links a latency panel to example traces. The canary metrics stay as they are.
- **Trace ID in logs:**
  - Add `trace_id`/`span_id` to the JSON log lines (Go logrus fields, Python JSON formatters).
  - Container Insights already ships the logs to CloudWatch Logs, where Logs Insights can find a
    trace's lines.
  - Grafana's "trace to logs" link supports Loki natively. For CloudWatch, a data link with a
    Logs Insights query is the option, to verify on the installed Grafana version. Loki itself is
    out of scope.

## Decision (recommended)

**OpenTelemetry Collector through its Helm chart, exporting to Grafana Tempo in the cluster
(monolithic, local storage, 24 h retention), with tail sampling in the collector.**

Reasons:

1. **It works with Grafana as set up today.** Tempo is a core data source, unlike X-Ray's
   plugin. TraceQL, service graph and exemplars come from the same tool as our dashboards.
2. **No new AWS service.** No IAM role, no permission-boundary change, no bootstrap run, no
   per-trace bill; the data stays in the cluster.
3. **Same lifetime as our metrics.** Prometheus keeps 24 h in the pod and loses it when the pod is
   replaced; traces kept the same way are consistent with it. A lab needs the last hours of
   traces to debug a deploy or a canary, not weeks: traces kept 30 days add little. S3 storage is
   one values change when needed. (Corrected 2026-10-17: this reason first relied on a daily
   rebuild of the cluster, which does not exist.)
4. **Portable** to Phase 4 (waypoint spans over OTLP to the same collector) and Phase 6 (same
   chart on any cloud; the exporter is configuration).
5. **The collector chart, not the Operator:** one Deployment instead of CRDs and webhooks. We
   instrument in code and in the images instead of injecting agents.

Sampling:

- **SDKs:** parent-based, always on (the root is the frontend).
- **Collector:**
  - `filter`: drop health checks (`/_healthz`, `grpc.health.v1`);
  - `tail_sampling`: keep 100% of traces with an error and of traces slower than 1 s (the
    shop's latency SLO), plus 100% of the rest in dev and 10% in prod.
- **One collector replica for now**, so all spans of a trace meet in one place and the tail
  sampling rules see whole traces.
  - If the collector must scale, add a two-tier setup: a first tier with the `loadbalancing`
    exporter keyed on the trace ID (`routing_key: traceID`) in front of the sampling
    collectors.
  - Every span of a trace then reaches the same sampling replica. A plain Service in front of
    several sampling replicas is not allowed.

The roadmap's earlier "exporting to AWS X-Ray" is replaced by this. X-Ray stays the option when
traces must outlive the cluster without running storage.

### Capacity

Proposed requests and limits (no CPU limits, as for the rest of `monitoring`):

| Component | Replicas | CPU request | Memory request | Memory limit | Notes |
|---|---|---|---|---|---|
| OTel Collector (contrib) | 1 | 100m | 256Mi | 512Mi | `memory_limiter` at about 400 MiB (spike 100 MiB), so it refuses data before the OOM kill; tail sampling `decision_wait` 10 s, `num_traces` 20,000 |
| Tempo (single binary) | 1 | 100m | 384Mi | 1Gi | local disk `emptyDir` with `sizeLimit: 2Gi`, 24 h block retention |
| **Total added** | | **200m** | **640Mi** | | |

Current headroom, from the repo. These are requests, which is what the scheduler counts.

| Item | CPU | Memory | Source |
|---|---|---|---|
| Node group | about 7.6 allocatable | 4 x 4 GiB physical | `terraform-aws/variables.tf`: 4 x t3.medium (min 2, max 5); "about 7.6 CPU allocatable" in `values-dev.yaml`. Allocatable memory depends on the kubelet reservation for 110 pods: read it with `kubectl describe nodes` in step 1 |
| boutique-dev | 1.35 | 1.26 GiB | rendered chart at the HPA minimums |
| boutique-prod | 1.35 | 1.23 GiB | same; inventoryservice runs 2 replicas |
| monitoring | about 0.35 | about 0.9 GiB | `kube-prometheus-stack.values.yaml`: Prometheus, Grafana, operator, kube-state-metrics, node-exporter on each node |
| Argo Rollouts, metrics-server | about 0.15 | about 0.25 GiB | their values; Argo CD sets no requests |
| EKS add-ons and DaemonSets (CoreDNS, kube-proxy, VPC CNI, Pod Identity Agent, CloudWatch agent, Fluent Bit) | about 1.5 to 2 (estimate) | about 0.8 GiB (estimate) | not in the repo: measure in step 1 |
| **Total today** | **about 4.7 to 5.2** | **about 4.4 GiB** | |

- **Rendered totals:** the boutique figures leave out containers without requests, which get
  the LimitRange default (50m, 64Mi).
- **Normal running:** tracing adds 0.2 CPU and 0.6 GiB, leaving about 2.2 CPU of headroom. **No
  bigger node group is needed.**
- **Both environments at their HPA maximum:**
  - each environment adds about 1.4 CPU (frontend +3 x 100m, currency +3 x 100m, catalog
    +2 x 100m, cart +2 x 200m, recommendation +2 x 100m);
  - that brings requests to about 7.5 to 8 CPU, which is at the limit with or without tracing.
  - That is today's load-test case. For a load-test day, set `node_desired_size = 5` (already
    allowed by `max_size = 5`); there is no cluster autoscaler in the repo.
- **Step 1** records `kubectl describe nodes` (Allocated resources) before and after the
  install.

### Storage

- **Dev, now:** Tempo stores blocks on the pod's local disk (`emptyDir`, the chart default
  `persistence.enabled: false`).
  - Traces are lost when the Tempo pod restarts or moves to another node, and when the cluster is
    destroyed (a manual `infra` destroy).
  - That is acceptable for dev: Prometheus already keeps its 24 h in the pod the same way, and a
    trace is mostly read within hours of the request.
- **Prod option, decided later:** the Tempo S3 backend.
  - One bucket for traces only (encrypted, a lifecycle rule matching the retention, public
    access blocked).
  - Tempo reaches it through a Pod Identity role scoped to that bucket and the Tempo service
    account in `monitoring`, with the namespace-tag condition used for the other pod roles.
  - Today the deploy role may only use the Terraform state bucket in S3 (`terraform-bootstrap/boundaries.tf`).
    A traces bucket needs a boundary change and a bootstrap run, or the bucket in
    `terraform-bootstrap/` if traces must survive an `infra` destroy.
  - Decided when prod tracing is turned on (step 7) or when traces must outlive a pod restart.

### Install method and versions

- **Where it runs:** Tempo and the collector are installed by the existing `monitoring` job
  (`deploy/monitoring.sh`, run by the deploy workflow), next to kube-prometheus-stack.
- **Why not Argo CD:**
  - They are shared by the cluster: one collector and one Tempo serve `boutique-dev` and
    `boutique-prod`. They must exist before any app sends spans, and they plug into the
    Prometheus and Grafana that this job installs (the data source, and the remote-write
    receiver for span metrics).
  - The Argo CD project `boutique` may only deploy to `boutique-dev` and `boutique-prod` and no
    cluster-scoped objects (`deploy/argocd/project.yaml`). The collector needs a ClusterRole for
    `k8sattributes`, so Argo CD would need a second project.
  - The whole monitoring stack is not managed through GitOps today. Moving it to Argo CD is a
    separate decision for all of it, not for two charts.
- **Exact chart versions:** pinned in `deploy.yml` as environment variables, the way
  `KPS_VERSION` is passed. Unlike that range, these are exact versions. CI renders both charts
  with the same values.
  - `open-telemetry/opentelemetry-collector` **0.174.2** (Collector 0.161.0, `contrib` image),
    published 2026-10-01. `mode: deployment`, `replicaCount: 1`, preset
    `kubernetesAttributes`.
  - `grafana-community/tempo` **2.4.0** (Tempo 2.10.8, single binary), published 2026-09-11.
    `reportingEnabled: false` (usage reports to Grafana Labs off, like Grafana's analytics).
  - The Tempo charts in `grafana/helm-charts` (`tempo` 1.24.4, `tempo-distributed` 1.61.3) are
    marked deprecated since 2026-01-30. The single-binary chart now lives in the
    `grafana-community` repository (https://grafana-community.github.io/helm-charts).
  - Its 3.x line (Tempo 3.x, since 2026-09-11) is a new major version: we stay on 2.x and
    evaluate 3.x separately.

## Rollout plan (dev first, then prod through `env/prod`)

Each step is a small PR. Merging it deploys dev from `main` (Argo CD); nothing reaches prod
until step 7.

1. **Backend and collector (no app change).**
   - `deploy/monitoring.sh` installs Tempo and the collector in `monitoring` with the exact chart
     versions above. It uses the requests and limits from "Capacity" and records the node
     allocation before and after.
   - Grafana gets a Tempo data source with a fixed uid.
   - NetworkPolicies in `monitoring`: collector 4317 from the boutique namespaces only; Tempo
     from the collector and Grafana.
   - CI renders both charts.
   - Check: a test span sent with `telemetrygen` appears in Grafana.
2. **Chart switch, dev only.**
   - `tracing.enabled` (false by default, true in `values-dev.yaml`, false in
     `values-prod.yaml`) and `tracing.collectorAddr`.
   - `ENABLE_TRACING`, `COLLECTOR_SERVICE_ADDR`, `OTEL_SERVICE_NAME` and
     `OTEL_RESOURCE_ATTRIBUTES` (`deployment.environment`) on the services, no longer behind the
     GCP flags.
   - The shoppingassistantservice egress rule to the collector.
   - CI check: prod renders no `ENABLE_TRACING`.
   - Check: frontend, checkout, catalog, currency, payment, recommendation and email spans in one
     trace; the frontend canary passes (span overhead stays inside p95 under 1 s).
3. **Fix the existing instrumentation.**
   - Node: replace `exporter-otlp-grpc` 0.26.0 with the current `exporter-trace-otlp-grpc` at
     versions matching the SDK, and use a batch span processor.
   - Go: parent-based sampler.
   - emailservice: instrument the gRPC server regardless of the flag.
   - Upgrade the old Go and Python SDKs where it is low-risk.
4. **Instrument the services that have none:**
   - shippingservice: Go `otelgrpc`;
   - adservice: the OpenTelemetry Java agent in the image, enabled only when tracing is on.
     Measure the JVM start time against the liveness probe;
   - cartservice: the .NET OpenTelemetry SDK (ASP.NET Core and gRPC instrumentation, OTLP
     exporter);
   - inventoryservice and shoppingassistantservice: the Python SDK with botocore and gRPC
     instrumentation, plus manual server spans for `http.server`. The Bedrock span carries the
     model and token counts, never the question text.
5. **Async context.**
   - Put `traceparent` into the EventBridge event detail and read it in the SQS consumers
     (inventory, email), as span links.
   - Order-status Lambda tracing is optional (an OpenTelemetry Lambda layer).
6. **Links between signals.**
   - `trace_id`/`span_id` in the JSON logs.
   - The Tempo metrics-generator (span metrics and service graph) with exemplars, written to
     Prometheus.
     - Prometheus must accept remote writes:
       `prometheus.prometheusSpec.enableRemoteWriteReceiver: true` in
       `monitoring/kube-prometheus-stack.values.yaml`, plus
       `enableFeatures: [exemplar-storage]` for the exemplars.
     - **This changes the monitoring install.** The Prometheus pod restarts, which drops its
       in-pod 24 h of metrics, so apply it outside a canary.
     - The remote-write endpoint is open to anything that can reach Prometheus. Add a
       NetworkPolicy so only Tempo may write.
     - The CI step that renders kube-prometheus-stack covers it.
   - Grafana links: exemplars to Tempo, Tempo to span metrics, and a CloudWatch Logs Insights
     link by trace ID.
   - A "Traces" row on the Boutique dashboard and a RUNBOOK section.
7. **Prod.**
   - One values change (`tracing.enabled: true` in `values-prod.yaml`, prod sampling at 10%
     plus errors and slow traces), merged to `main`.
   - The deploy workflow promotes it to `env/prod` after the prod approval (ADR 0007), and the
     prod frontend canary must pass.
   - Rollback: revert the values commit.

## Consequences

- Two more workloads in `monitoring` (200m CPU and 640Mi of requests together, see
  "Capacity"); no bigger node group for normal running. Two more pinned charts to upgrade, by
  hand, in `deploy.yml`.
- Traces are lost when the Tempo pod restarts and when the cluster is destroyed, like the
  metrics. That is acceptable for dev; the S3 backend is the prod option, decided later.
- **Tail sampling pins the design to one collector replica:** the error and latency rules need
  every span of a trace on the same instance. That replica is a single point of failure for
  traces (not for the shop: the SDKs drop spans when the collector is down). Scaling it means
  adding the `loadbalancing` exporter tier keyed on the trace ID, never more replicas behind a
  plain Service.
- Span metrics turn on Prometheus's remote-write receiver: a change to the monitoring install
  and a new write path into Prometheus, to limit with a NetworkPolicy.
- Five services gain tracing code or an agent. The adservice JVM start time must be watched.
- Spans may carry attributes from requests: never the assistant's question, the session ID or
  personal data (attribute allow-list in the collector if needed).

## Revisit when

- Traces must survive a pod restart or an `infra` destroy, or be kept longer than a day: Tempo on
  S3, or X-Ray.
- The cluster grows past one collector replica: a load-balancing tier, or the Operator if many
  teams need auto-instrumentation.
- Phase 4 lands: point Istio's Telemetry API at the same collector.
- Phase 6 lands: a collector per cluster, and a central Tempo or one per cloud.
