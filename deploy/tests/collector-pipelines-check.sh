#!/usr/bin/env bash
# CI check: the OTel Collector's pipelines (ADR 0011, PR 5; monitoring/otel-collector.values.yaml).
#
#   deploy/tests/collector-pipelines-check.sh [collector values file]
#
# Span metrics and the service graph must see ALL spans, so the connectors are fed by traces/in,
# before tail sampling; tail sampling runs only in traces/sampled, after the forward connector,
# with the same policies as before (errors, slower than 1 s, 100% of dev, 10% of prod). The span
# metrics keep their low-cardinality dimensions.
set -euo pipefail

cd "$(dirname "$0")/../.."
f=${1:-monitoring/otel-collector.values.yaml}
fail=0
err() { echo "::error file=${f}::$1"; fail=1; }
q() { yq -o=json -I=0 "$1" "$f"; }

for c in spanmetrics servicegraph forward; do
  [ "$(q ".config.connectors | has(\"$c\")")" = true ] || err "connector $c missing"
done
[ "$(q '.config.service.pipelines.traces')" = null ] || err "the old single 'traces' pipeline must be null (traces/in + traces/sampled)"

# gRPC health probes are dropped before the connectors (they made user -> service edges), on
# rpc.service and on the span name (with or without the leading "/"), and the filter runs in traces/in.
filt='.config.processors["filter/otlp-export"].traces.span'
[ "$(q "[${filt}[]] | any_c(. == \"span.attributes[\\\"rpc.service\\\"] == \\\"grpc.health.v1.Health\\\"\")")" = true ] \
  && [ "$(q "[${filt}[]] | any_c(test(\"IsMatch\\\\(span.name, .*grpc.*health.*Health/\\\\(Check\\\\|Watch\\\\)\"))")" = true ] \
  || err "filter/otlp-export must drop gRPC health probe spans (rpc.service grpc.health.v1.Health, and span name .../Health/(Check|Watch))"
# HTTP health checks too (frontend /_healthz: kubelet and ALB; /healthz, /readyz), by route and path.
for a in http.route url.path; do
  [ "$(q "[${filt}[]] | any_c(test(\"IsMatch\\\\(span.attributes\\\\[\\\"${a}\\\"\\\\].*_healthz\\\\|healthz\\\\|readyz\"))")" = true ] \
    || { err "filter/otlp-export must drop HTTP health checks by ${a} (/_healthz, /healthz, /readyz)"; break; }
done
[ "$(q '.config.service.pipelines["traces/in"].processors | any_c(. == "filter/otlp-export")')" = true ] \
  || err "traces/in must run filter/otlp-export before the connectors"

# traces/in: every span, no sampling, into the three connectors.
[ "$(q '.config.service.pipelines["traces/in"].receivers')" = '["otlp"]' ] || err "traces/in must receive otlp"
[ "$(q '.config.service.pipelines["traces/in"].processors | any_c(. == "tail_sampling")')" = false ] \
  || err "tail_sampling must not be in traces/in: the span metrics must count ALL spans"
for c in spanmetrics servicegraph forward; do
  [ "$(q ".config.service.pipelines[\"traces/in\"].exporters | any_c(. == \"$c\")")" = true ] || err "traces/in must export to $c"
done

# traces/sampled: after the forward connector, tail sampling first, then batch, then Tempo.
[ "$(q '.config.service.pipelines["traces/sampled"].receivers')" = '["forward"]' ] || err "traces/sampled must receive from forward"
[ "$(q '.config.service.pipelines["traces/sampled"].processors[0]')" = '"tail_sampling"' ] || err "traces/sampled must start with tail_sampling"
[ "$(q '.config.service.pipelines["traces/sampled"].exporters')" = '["otlp_grpc/tempo"]' ] || err "traces/sampled must export to Tempo"

# The sampling decision is unchanged.
[ "$(q '[.config.processors.tail_sampling.policies[].name]')" = '["drop-health-checks","keep-errors","keep-slow","dev-all","prod-10-percent"]' ] \
  || err "tail_sampling policies changed"
[ "$(q '.config.processors.tail_sampling.decision_wait')" = '"30s"' ] || err "decision_wait must stay 30s"
[ "$(q '.config.processors.tail_sampling.policies[] | select(.name == "keep-slow") | .latency.threshold_ms')" = 1000 ] || err "keep-slow must stay 1000 ms"
[ "$(q '[.config.processors.tail_sampling.policies[] | select(.name == "dev-all" or .name == "prod-10-percent") | .and.and_sub_policy[] | select(.type == "probabilistic") | .probabilistic.sampling_percentage]')" = '[100,10]' ] \
  || err "dev must stay at 100%, prod at 10%"

# metrics/spans: the connectors to the Prometheus exporter.
[ "$(q '.config.service.pipelines["metrics/spans"].receivers | sort')" = '["servicegraph","spanmetrics"]' ] || err "metrics/spans must receive spanmetrics and servicegraph"
[ "$(q '.config.service.pipelines["metrics/spans"].exporters')" = '["prometheus/span-metrics"]' ] || err "metrics/spans must export to prometheus/span-metrics"

# The names Grafana's Service Graph / RED table query (Grafana 13.2.1, Tempo plugin 13.1.5,
# graphTransform.ts): traces_spanmetrics_calls_total and traces_spanmetrics_latency_bucket.
[ "$(q '.config.connectors.spanmetrics.namespace')" = '"traces.spanmetrics"' ] \
  || err "spanmetrics namespace must be traces.spanmetrics (traces_spanmetrics_calls_total in Grafana)"
[ "$(q '[.config.processors["transform/span-metrics-resource"].metric_statements[] | select(.context == "metric") | .statements[]] | any_c(test("set\\(name, \"traces.spanmetrics.latency\"\\) where name == \"traces.spanmetrics.duration\""))')" = true ] \
  || err "the duration histogram must be renamed traces.spanmetrics.latency (traces_spanmetrics_latency_bucket in Grafana)"
[ "$(q '[.config.processors["transform/span-metrics-resource"].metric_statements[] | select(.context == "metric") | .statements[]] | any_c(test("set\\(unit, \"\"\\) where name == \"traces.spanmetrics.latency\""))')" = true ] \
  || err "the latency histogram's unit must be cleared (no _seconds suffix)"
[ "$(q '.config.service.pipelines["metrics/spans"].processors[0]')" = '"transform/span-metrics-resource"' ] \
  || err "metrics/spans must run transform/span-metrics-resource first (names and labels)"

# Cardinality: the extra span-metric dimension is the namespace only; nothing personal.
[ "$(q '[.config.connectors.spanmetrics.dimensions[].name]')" = '["k8s.namespace.name"]' ] \
  || err "spanmetrics dimensions must be exactly k8s.namespace.name (plus the defaults)"
if q '.config.connectors' | grep -qiE 'session|user|email|client\.address|client_ip|http\.target|url\.full|url\.path'; then
  err "a connector names a personal or high-cardinality attribute"
fi

[ "$fail" -eq 0 ] || exit 1
echo "Collector pipelines: connectors before tail sampling, sampling unchanged (${f})."
