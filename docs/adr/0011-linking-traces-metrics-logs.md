# 0011: Linking traces, metrics and logs (ADR 0010, rollout step 6)

Status: proposed. Date: 2026-10-17. Docs only: nothing is implemented by this ADR.

This ADR decides step 6 of ADR 0010 ("Links between signals"). It is a separate ADR because it
also chooses a log backend for Grafana, which ADR 0010 left out of scope. ADR 0010's step 6
text is replaced by the plan below.

## Context

What exists today (from the repo, 2026-10-17):

- **Traces:** all 12 services send spans to one OTel Collector (`monitoring`, one replica,
  tail sampling). The collector exports them to Tempo 2.10.8 (single binary, local disk,
  24 h). Tracing is on in dev and off in prod. The order flow over EventBridge and SQS is one
  trace (step 5).
- **Metrics:** Prometheus from kube-prometheus-stack (24 h in the pod, scrape every 30 s,
  requests 100m / 400Mi, limit 1200Mi). It scrapes `prometheus.io/*`-annotated pods in every
  namespace. The frontend canary analysis (ADR 0008) queries it with 1-minute windows on the
  canary pods only.
- **Logs:** the EKS add-on `amazon-cloudwatch-observability` (Container Insights) runs Fluent
  Bit on every node and ships container stdout to
  `/aws/containerinsights/<cluster>/application`.
  - **Grafana:** it already has a CloudWatch data source (uid `cloudwatch`, Pod Identity role
    `week3-boutique-grafana-cloudwatch`). Logs Insights reads are limited to that log group
    prefix and `/aws/lambda/week3-boutique-*` (`terraform-aws/monitoring.tf`).
  - **Retention:** the repo sets none on the Container Insights groups. Only the two Lambda
    log groups have 14 days.
  - **Control-plane logs:** the EKS module (`~> 20.0`) sends audit, api and authenticator logs
    by default to `/aws/eks/<cluster>/cluster`. CloudTrail goes to the audit bucket.
- **Log formats:** all 12 services log JSON to stdout. None has a trace ID:

  | Services | Logger | Today |
  |---|---|---|
  | frontend, checkoutservice, productcatalogservice, shippingservice | Go logrus `JSONFormatter` | the frontend builds one request logger per request in `logHandler`, inside the traced handler; the others mostly call the package logger without a context |
  | currencyservice, paymentservice | Node pino 8.15.0 | |
  | recommendationservice, emailservice | `python-json-logger` (`logger.py`, the same file in both) | |
  | inventoryservice, shoppingassistantservice | their own `JsonFormatter` | |
  | adservice | Log4j2 `JsonLayout` | already prints `$${ctx:traceId}` / `$${ctx:spanId}` under the old Stackdriver key names, always empty |
  | cartservice | .NET console logger, default format | |

- **Personal data already in the logs.** This has to be fixed whatever backend we choose:
  - checkoutservice logs the shopper's email address (`main.go`: "order confirmation email
    sent to %q", and the failure line);
  - emailservice logs it on every gRPC request (`email_server.py`: "A request to send order
    confirmation email to {}");
  - the frontend logs the session ID on every request, at Debug level, which is on
    (`main.go`: `log.Level = logrus.DebugLevel`, `middleware.go`: field `session`).
- **Cluster capacity:** 4 x t3.medium, about 7.6 CPU allocatable. CPU requests are at 82% now,
  and should be about 60% after the right-sizing PR (RUNBOOK section 13, the resource usage
  report).
- **Permission boundaries:** the deploy role may use S3 only for the Terraform state bucket
  (`terraform-bootstrap/boundaries.tf`). A new bucket means a boundary change and a bootstrap
  run.

## 1. Logs in Grafana

### Options

1. **CloudWatch Logs data source** (the logs we already ship).
   - **IAM:** no new role, no boundary change, no bootstrap run. See "Grafana's AWS
     credentials" below for what the repo shows.
   - **Compute:** none added. Fluent Bit already runs as part of Container Insights.
   - **Cost:** we already pay for ingestion, so no new line on the bill. Logs Insights is
     billed per GB scanned: a query over one trace's time window scans little. The
     unbounded retention is the cost to fix (see Decision).
   - **Trace to logs:** Grafana's Tempo "trace to logs" link does **not** support CloudWatch.
     The compatible sources are Loki, Elasticsearch, Splunk, OpenSearch, Falcon LogScale,
     Google Cloud Logging and VictoriaMetrics Logs (Grafana docs, "Configure trace to logs",
     checked 2026-10-17). Grafana Correlations show links only in Explore's Logs panel and
     Table, not in the trace view. So:
     - **logs to trace:** yes, a Correlation on the `trace_id` field from CloudWatch to Tempo;
     - **trace to logs:** no button in the trace view. Instead: a dashboard data link from a
       trace ID to a "Logs for a trace" panel, or the trace ID pasted into one Logs Insights
       query (Section 2).
   - **Multi-cloud:** AWS only. Phase 6 needs another log store per cloud, or a central one.
2. **Loki in the cluster** (single binary, plus Grafana Alloy or the OTel Collector `filelog`
   receiver as a DaemonSet).
   - **Trace to logs:** native in both directions (`tracesToLogsV2` in the Tempo data source,
     derived fields in the Loki data source). This is the best user experience.
   - **Storage:** either local `emptyDir` or S3.
     - Local: logs are lost with the pod, like Prometheus and Tempo. That is weak for logs,
       which we read after an incident.
     - S3: needs a bucket, a Pod Identity role, an S3 entry in the deploy boundary and a
       bootstrap run (the same path as ADR 0010's Tempo-on-S3 option).
   - **Compute:** Loki about 100m / 256Mi (limit 1Gi), plus an agent on each node, about
     4 x 50m / 64Mi (limit 256Mi). That is **about 300m CPU and 0.5 GiB of requests**: CPU
     requests go from 82% to about 86% today (about 64% after right-sizing).
   - **Duplication:** the cluster-wide logs (control plane, the add-on's own Fluent Bit,
     Lambdas) stay in CloudWatch. So every container line would be shipped twice, by two
     agents per node, to two stores with two retention policies. That is also two places to
     keep free of personal data.
   - **Install:** the Loki chart moved to `grafana-community/helm-charts` on 2026-03-16 (like
     Tempo's), and `loki-stack` is deprecated. It would be one more pinned chart in
     `deploy/monitoring.sh`.
   - **Multi-cloud:** the same chart runs on any cloud. This is the main argument for it in
     Phase 6.

### Grafana's AWS credentials (checked 2026-10-17)

**Grafana uses EKS Pod Identity, not IRSA and not the node role.** The repo shows:

- **The association:** `aws_eks_pod_identity_association.grafana` (`terraform-aws/monitoring.tf`)
  links namespace `monitoring`, service account `grafana`, to the role
  `week3-boutique-grafana-cloudwatch`. The role trusts only `pods.eks.amazonaws.com`
  (`workload-iam.tf`).
- **Grafana's values:** the chart creates the service account `grafana`
  (`kube-prometheus-stack.values.yaml`). The data source uses `authType: default`, the AWS SDK
  default chain.
- **Why the chain picks Pod Identity:** the EKS Pod Identity webhook puts
  `AWS_CONTAINER_CREDENTIALS_FULL_URI` and the token file into the pod when it is created. The
  SDK's container-credentials provider comes before the instance metadata provider.
- **No IRSA:** no `eks.amazonaws.com/role-arn` annotation anywhere in `monitoring/`,
  `terraform-aws/` or `deploy/`.
- **The role's log rights:**
  - `logs:DescribeLogGroups` and `logs:ListAggregateLogGroupSummaries` on `*` (they can't be
    scoped);
  - `logs:GetLogGroupFields`, `StartQuery`, `GetLogEvents` and `FilterLogEvents` on
    `/aws/containerinsights/<cluster>/*` and `/aws/lambda/week3-boutique-*`;
  - `logs:GetQueryResults` and `StopQuery` on `*` (AWS doesn't scope them).
  - There is no write action, and no other account's or project's log groups.

What the repo can't show, and its risk:

- **The node role as a fallback.** Grafana falls back to the node instance role through
  instance metadata (IMDS) in two cases:
  - the Grafana pod started before its association existed (the webhook adds the variables
    only at pod creation);
  - pods can reach IMDS. The repo leaves the node group's `metadata_options` at the EKS module
    default, so the hop limit is not visible here.
- **What the node role could do.** It has `CloudWatchAgentServerPolicy`. That policy allows
  log *writes* and `DescribeLogGroups`, but no `StartQuery`, `GetQueryResults`,
  `GetLogEvents`, `FilterLogEvents` or `GetMetricData`. So queries would fail with
  AccessDenied, and Grafana would get no extra rights.
- **The check, in PR 4 below.** Both are read-only:
  - the Grafana pod's environment has `AWS_CONTAINER_CREDENTIALS_FULL_URI` (names only, no
    values printed);
  - a Logs Insights query in Explore succeeds, and CloudTrail shows its `StartQuery` called
    by `week3-boutique-grafana-cloudwatch`, not by the node role.
- **Separate finding, not fixed by this ADR.** If pods can reach IMDS, every pod can use the
  node role (ECR pull, CNI, log writes). The fix is `http_put_response_hop_limit = 1` on the
  node group. It is a Terraform change to the nodes, to be decided on its own.

**Narrower scope** (optional PR 2b below):

- The `/aws/containerinsights/<cluster>/*` pattern also covers the `performance`, `dataplane`
  and `host` groups. Grafana only needs `application` for this ADR.
- Narrowing it to `/aws/containerinsights/<cluster>/application:*` changes only the existing
  role policy.
- The deploy role's boundary already allows `iam` and `logs` on resources tagged
  `Project = week3-boutique`, so **no boundary change and no bootstrap run**.
- IAM can't scope inside one log group, so the `application` group still holds every
  namespace's container logs (boutique-dev, boutique-prod, monitoring, Argo CD). That is why
  no personal data may be in any container log (PR 1).
- The Lambda groups stay in the policy: Grafana reads them today (SECURITY.md).

### Decision

**Option 1: the CloudWatch Logs data source.** Loki is not installed now.

1. **No new role, boundary or bootstrap change, and no new compute** on a cluster at 82% of
   its CPU requests. Grafana already reads these logs with its own Pod Identity role (see
   above). Loki's 300m would come out of the right-sizing margin before that work has
   landed.
2. **One log pipeline.** CloudWatch keeps the control-plane, audit and Lambda logs anyway.
   Loki would add a second copy of the container logs, not replace one.
3. **Logs outlive the cluster.** CloudWatch keeps them through pod restarts and an `infra`
   destroy, without an S3 change.
4. **The work that matters is portable.** `trace_id`/`span_id` in the JSON lines (Section 2)
   is the same for any backend. Moving to Loki later only adds an agent and a data source.
5. **The cost is the missing trace-view button.** Logs to trace is one click. Trace to logs
   goes through a dashboard link or one query. That is acceptable for a lab with one
   operator.

Also part of this decision:

- **Retention:** 14 days on `/aws/containerinsights/<cluster>/application` (the same as the
  Lambdas). First read the current value with `aws logs describe-log-groups`. The group was
  created by the add-on, so Terraform must import it before it manages the retention. The
  other Container Insights groups (`performance`, `dataplane`, `host`) get the same review.
- **No personal data in logs:**
  - Before any link makes the logs easier to search, the three lines above are fixed: mask the
    email the way emailservice's `mask_email` does, and drop the frontend's `session` field.
  - The frontend's request logs go from Debug to Info. That also cuts the per-request log
    volume we pay to ingest.
  - The trace and span IDs are not personal data.
- **Revisit** when Phase 6 needs one log view across clouds, or when trace-to-logs clicks are
  needed many times a day. Then use Loki on S3, with its own ADR.

## 2. Trace to logs

### `trace_id` and `span_id` in the JSON logs

> **Note 2026-10-17:** the log fields are `trace_id`, `span_id` and `trace_flags` (2-character
> lower-case hex: `"01"` sampled, `"00"` not) in all languages, as in the OTel log data model
> and the Node (pino) and Java agent integrations. The Python and .NET PRs must map to these
> names; .NET's `TraceId`/`SpanId` scope fields are not enough. The Go services have them
> (`logtrace.go`).

- **Field names:** `trace_id` and `span_id`, lower-case hex as in `traceparent`. These are the
  OpenTelemetry Java agent's defaults and the OTel log data model's names.
- **When they are written:** only when a span is active and valid. With tracing off (prod)
  the fields are absent, never empty strings.

| Service(s) | What it needs |
|---|---|
| frontend | In `logHandler`, add the IDs from `trace.SpanFromContext(ctx)` to the request logger. `tracedHandler` wraps it, so the span exists there. |
| checkoutservice, productcatalogservice, shippingservice | A logrus hook that reads `trace.SpanFromContext(entry.Context)`. Request-time calls switch to `log.WithContext(ctx)`; startup logs stay without IDs. |
| currencyservice, paymentservice | `@opentelemetry/instrumentation-pino`, at the version matching `sdk-node` 0.41.2. It adds `trace_id`, `span_id` and `trace_flags` itself. The SDK must start before `pino` is required, as it already does for gRPC. |
| recommendationservice, emailservice | In `CustomJsonFormatter.add_fields` (`logger.py`, both copies the same), read `trace.get_current_span().get_span_context()`. No new package. |
| inventoryservice, shoppingassistantservice | The same three lines in their own `JsonFormatter`. |
| adservice | The Java agent 2.32.0 already puts `trace_id`/`span_id` in the Log4j2 context data. In `log4j2.xml`, replace the Stackdriver keys with `trace_id` = `$${ctx:trace_id}` and `span_id` = `$${ctx:span_id}`. Check that the agent-off case writes no empty field. |
| cartservice | `AddJsonConsole` with `IncludeScopes` and `ActivityTrackingOptions = TraceId \| SpanId`. That writes `TraceId`/`SpanId` inside a scope. Either a small custom formatter maps them to `trace_id`/`span_id` at the top level, or the Logs Insights query matches both. Decide in the cart PR. |

Every PR gets a unit test: a log line written inside a recording span carries its IDs, and one
written with tracing off has no ID fields.

### Grafana

- **Logs to trace:** a provisioned Correlation, source `cloudwatch` (Logs), target `tempo`.
  - Its query is `${trace_id}`, using the `trace_id` field (or the path Container Insights
    puts it under). The link shows in Explore's Logs and Table views.
  - Correlations are provisioned like data sources. Check the provisioning format on the
    installed Grafana 13.
- **Trace to logs:**
  - A **"Logs for a trace"** dashboard: a `trace_id` text variable and one CloudWatch Logs
    Insights panel on the application log group:
    `fields @timestamp, kubernetes.container_name, @message | filter @message like "$trace_id" | sort @timestamp asc`.
  - `like` on `@message` works whatever field path the JSON is parsed into. A field filter can
    replace it once the path is known.
  - The Traces row (Section 4) links each trace ID to that dashboard with `${__value.raw}`.
  - RUNBOOK section 12 gets the same query for Explore.
- `tracesToLogsV2` in the Tempo data source stays unset, because CloudWatch is not a
  compatible target. If Loki comes later, it is the only change needed there.

## 3. Span metrics and exemplars

### Options

1. **Tempo metrics-generator** (`span-metrics`, `service-graphs`), remote-writing to Prometheus.
2. **The collector's `spanmetrics` and `servicegraph` connectors**, in the collector before
   tail sampling, exposed on a Prometheus endpoint that Prometheus scrapes.

### Decision

**Option 2: the collector connectors, scraped by Prometheus.** Not Tempo's metrics-generator.

- **Accuracy:** Tempo only receives the spans tail sampling kept.
  - Dev keeps 100%, so it makes no difference today.
  - At step 7, prod keeps 10% of normal traces and 100% of errors and slow ones. Tempo's span
    metrics would then show a prod error rate and latency about ten times too high.
  - The connectors count every span before sampling. Health-check spans are dropped earlier
    and are not counted either way.
- **No write path into Prometheus:** a scrape needs no `enableRemoteWriteReceiver` and no
  NetworkPolicy to fence it. The collector pod gets the `prometheus.io/*` annotations the
  existing `kubernetes-pods` job already uses.
- **Tempo is unchanged:** no generator memory in the single binary, no remote-write config.

Setup:

- **Pipeline:** the traces pipeline fans out to `spanmetrics` and `servicegraph` right after
  `memory_limiter` and `filter`, before `tail_sampling`. A `metrics` pipeline exports them with
  the `prometheus` exporter on port 8889, with `enable_open_metrics: true` so the exemplars
  are exposed.
- **Names:** Grafana's Service Graph needs `traces_service_graph_request_total`,
  `..._failed_total`, `..._server_seconds` and `..._client_seconds`. Its RED table needs
  `traces_spanmetrics_calls_total` and `traces_spanmetrics_duration_seconds_bucket`.
  - The connector's `namespace: traces.spanmetrics`, with durations in seconds, gives those
    names.
  - Grafana's docs name only Tempo and Alloy as sources. The PR checks the names in Explore
    before any panel uses them.
- **Labels:** `service.name`, `span.name`, `span.kind`, `status.code` (the defaults), plus
  `deployment.environment`.
  - No request attribute is a label. Span names are already templates (routes, gRPC methods,
    `chat <model id>`).
  - Exemplars carry only the trace ID.
- **Buckets:** 8 histogram buckets (5 ms to 5 s) instead of the default, to halve the series.
- **Size:** about 150 series groups per environment (span names x status), and about 10
  series each with 8 buckets. That is about 1,500 span-metric series per environment, plus
  about 1,000 service-graph series: **about 2,500 in dev, about 5,000 once prod traces**.
  Prometheus needs a few KiB per series, so about 20 to 40 MiB.
- **Prometheus:** `enableFeatures: [exemplar-storage]`, with exemplar storage at its default
  of 100,000 exemplars. No remote-write receiver.

### The Prometheus restart

Turning on `exemplar-storage` changes the Prometheus spec, so the pod restarts on the next
deploy run. It loses its in-pod 24 h of metrics.

- **Not during a canary.** The canary analysis reads Prometheus.
  - The `monitoring` job runs before `deploy-dev` and `monitoring.sh` waits for the release,
    so the dev canary of the same run starts on a restarted Prometheus. That is fine: its
    analysis uses 1-minute windows on the canary pods, after `initialDelay`.
  - The risk is a canary already in flight when the restart happens: a prod canary after an
    approval, or a manual monitoring run. Merge only when cluster-status shows no Rollout
    progressing in either namespace and no prod approval pending.
- **Not while right-sizing data is collected.** The resource usage report reads 24 h of cAdvisor
  data. Merge this PR only after that report was taken and the right-sizing PR has merged.
  Then wait a day before the next report.
- The ADR 0010 text about `enableRemoteWriteReceiver` and a remote-write NetworkPolicy no
  longer applies.

## 4. Grafana

- **A "Traces" row on the Boutique dashboard** (`monitoring/dashboards/boutique.json`). Every
  panel has an `env` variable (`deployment.environment`). Latency panels show exemplars, which
  link to Tempo.
  - **RED per service:** request rate (`rate(traces_spanmetrics_calls_total{span_kind="SPAN_KIND_SERVER"}[5m])`
    by service), error ratio (`status_code="STATUS_CODE_ERROR"` over all), and p95 from
    `traces_spanmetrics_duration_seconds_bucket`.
  - **Top slow routes:** `topk(10, ...)` of p95 by `span_name` for SERVER spans.
  - **Assistant:** Bedrock latency p50/p95 from span metrics on `span_name=~"chat .*"` in
    shoppingassistantservice.
    - Tokens from its existing `assistant_tokens_total{direction}` counter. Span metrics
      count spans; they can't sum an attribute like token counts.
    - Also `assistant_bedrock_errors_total`.
  - **Recent slow traces:** a Tempo TraceQL table (`{ traceDuration > 1s }`). Each trace ID
    has two data links: the trace in Explore, and "Logs for a trace" (Section 2).
- **Service Graph tab:** in the Tempo data source, `serviceMap.datasourceUid: prometheus` and
  `nodeGraph.enabled: true`.
- **`tracesToMetrics`** from a span to its service's RED queries in Prometheus.
- **The CloudWatch to Tempo Correlation** (Section 2).
- All of it is in `kube-prometheus-stack.values.yaml` and the dashboard JSON, so CI renders it.

## 5. Resources and PR order

### Requests and limits

The table lists the components that change; no CPU limits, as for the rest of `monitoring`.

| Component | Today (request CPU / memory, memory limit) | After | Why |
|---|---|---|---|
| OTel Collector | 100m / 256Mi, 512Mi | **150m / 384Mi, 768Mi**; `memory_limiter` `limit_mib` 600 | the connectors' series state, and every span counted before sampling |
| Prometheus | 100m / 400Mi, 1200Mi | **100m / 512Mi, 1200Mi** | about 2,500 to 5,000 series plus the exemplar buffer |
| Tempo, Grafana | unchanged | unchanged | no metrics-generator; panels only |
| Loki and its agent | none | none (not installed) | rejected option: it would add about 300m / 512Mi |
| **Added requests** | | **+50m CPU, +240Mi** | under 1 point of the 7.6 CPU allocatable |

### PR order

Each PR is small and dev first. Prod gets the log changes through the normal promotion (they
are code, with no prod-only switch). Tracing stays off in prod until ADR 0010 step 7.

1. **No personal data in logs** (checkout, email, frontend). Code only. Mask the email,
   drop `session`, frontend request logs at Info.
2. **Log retention.** Terraform: import the Container Insights application log group and set
   14 days. Plan shows only that group.
   - 2b (optional): narrow Grafana's log-read resources to the `application` group (see
     "Grafana's AWS credentials"). The plan shows only `aws_iam_role_policy.grafana`. No
     boundary or bootstrap change.
3. **`trace_id`/`span_id` in the logs, by language:**
   - 3a: the four Go services;
   - 3b: currency and payment (Node);
   - 3c: the four Python services;
   - 3d: adservice (`log4j2.xml`);
   - 3e: cartservice.
   One PR per group, with a unit test each and a check in dev Logs Insights.
4. **Logs to trace and trace to logs in Grafana:** the Correlation, the "Logs for a trace"
   dashboard, and the RUNBOOK query. No Prometheus change. Check first that Grafana uses its
   Pod Identity role, not the node role (the two read-only checks in "Grafana's AWS
   credentials").
5. **Collector span metrics** (`spanmetrics`, `servicegraph`, the `prometheus` exporter, pod
   annotations, the new collector resources). The metrics appear in Prometheus, without
   exemplars yet. Check the names against Grafana's Service Graph in Explore.
6. **Prometheus `exemplar-storage`** and the 512Mi request. This is the restart, alone in its
   PR, timed as in Section 3.
7. **Grafana:** the Traces row, the Tempo `serviceMap`, `nodeGraph` and `tracesToMetrics`,
   and the RUNBOOK section.

## Consequences

- No new AWS service, IAM role or boundary change. The only Terraform change is one log
  group's retention.
- No trace-to-logs button in the trace view; there is a dashboard link and one query.
  Loki remains the upgrade path, with its own ADR.
- The collector does more work (span metrics), on the same single replica. Its memory limit
  goes to 768Mi. If it is OOMKilled, the `memory_limiter` setting and the bucket count are
  the first things to tune.
- Span metrics stay accurate when prod traces are sampled at 10%.
- Prometheus restarts once, timed after the right-sizing data and outside a canary.
- Personal data comes out of the logs before the logs become easier to search.

## Revisit when

- Phase 6 needs one log view across clouds, or trace-to-logs is used daily: Loki (S3 backend,
  boundary change), with its own ADR.
- Grafana supports CloudWatch as a trace-to-logs target: set `tracesToLogsV2` and remove the
  dashboard workaround.
- The collector needs a second replica (ADR 0010): the connectors move to the
  load-balanced sampling tier, keyed on the trace ID, so each span is still counted once.
