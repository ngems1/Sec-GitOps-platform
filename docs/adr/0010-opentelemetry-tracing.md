# 0010: OpenTelemetry tracing (OTel Collector + Grafana Tempo in the cluster)

Status: proposed (Phase 3, OpenTelemetry tracing). Date: 2026-10-16. Investigation only: nothing
is implemented by this ADR.

## Context

Phase 3 adds distributed tracing: one shopper request (ALB, frontend, then the gRPC services and
the AWS calls) seen as one trace in Grafana, next to the metrics we already have. Today the stack
has Prometheus and Grafana (kube-prometheus-stack, `monitoring` namespace, 24 h retention in the
pod), CloudWatch Container Insights for container logs, and no trace backend. The cluster is
small (t3.medium nodes) and `terraform-aws` is destroyed and re-created every day (BOOTSTRAP.md).

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
   - Fully managed and kept 30 days, so it survives the daily destroy. It also has the CloudWatch
     service map.
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
- Tail sampling in the collector decides after the whole trace has arrived. It needs every span
  of a trace to reach the same collector instance: easy with one replica, or a load-balancing
  tier later.

### Volume and cost estimate

- **Traffic:** the loadgenerator sends about 1.5 requests/s in dev and about 0.8 in prod
  (values comments). One shop page is about 10 spans; the home page converts nine prices.
- **Dev:** about 15 spans/s, so about 54,000 spans an hour, or about 0.5 million on a 10-hour
  day. That is a few hundred MB in Tempo before compression, fine on local disk with 24 h
  retention.
- **With X-Ray:** about 2.3 traces/s across both environments over 10 hours a day is about
  2.5 million traces a month. Sampling everything would cost about USD 12 a month; keeping 10%
  of prod plus errors would cost about USD 1 to 3.
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
3. **Same lifetime as our metrics.** Prometheus already keeps 24 h in the pod and the cluster is
   rebuilt daily, so traces kept 30 days add little for a lab. S3 storage is one values change
   when needed.
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
- **Collector size:** one replica until the volume needs more.

The roadmap's earlier "exporting to AWS X-Ray" is replaced by this. X-Ray stays the option when
traces must outlive the cluster without running storage.

## Rollout plan (dev first, then prod through `env/prod`)

Each step is a small PR. Merging it deploys dev from `main` (Argo CD); nothing reaches prod
until step 7.

1. **Backend and collector (no app change).**
   - `deploy/monitoring.sh` installs Tempo and the collector in `monitoring` with pinned chart
     versions.
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
   - The Tempo metrics-generator with exemplars into Prometheus (remote-write receiver and
     exemplar storage on).
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

- Two more workloads in `monitoring` (about 200m CPU and 768Mi together, to size during step 1)
  and two more pinned charts to upgrade.
- Traces are lost when the cluster is destroyed, like the metrics. That is acceptable for the
  lab, and S3 storage is the fix if not.
- Five services gain tracing code or an agent. The adservice JVM start time must be watched.
- Tail sampling ties all spans of a trace to one collector replica. Scaling out needs a
  load-balancing exporter tier.
- Spans may carry attributes from requests: never the assistant's question, the session ID or
  personal data (attribute allow-list in the collector if needed).

## Revisit when

- Traces must survive the daily destroy or be kept longer than a day: Tempo on S3, or X-Ray.
- The cluster grows past one collector replica: a load-balancing tier, or the Operator if many
  teams need auto-instrumentation.
- Phase 4 lands: point Istio's Telemetry API at the same collector.
- Phase 6 lands: a collector per cluster, and a central Tempo or one per cloud.
