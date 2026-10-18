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

# Cardinality: the extra span-metric dimension is the namespace only; nothing personal.
[ "$(q '[.config.connectors.spanmetrics.dimensions[].name]')" = '["k8s.namespace.name"]' ] \
  || err "spanmetrics dimensions must be exactly k8s.namespace.name (plus the defaults)"
if q '.config.connectors' | grep -qiE 'session|user|email|client\.address|client_ip|http\.target|url\.full|url\.path'; then
  err "a connector names a personal or high-cardinality attribute"
fi

[ "$fail" -eq 0 ] || exit 1
echo "Collector pipelines: connectors before tail sampling, sampling unchanged (${f})."
