#!/usr/bin/env bash
# CI check: latency graph -> example trace stays wired (ADR 0011, PR 6; RUNBOOK section 12).
#
#   deploy/tests/exemplars-check.sh [kube-prometheus-stack values] [collector values]
#   default: monitoring/kube-prometheus-stack.values.yaml monitoring/otel-collector.values.yaml
#
# The collector puts trace IDs (exemplars) on the span-metric histogram buckets and serves them in
# OpenMetrics; Prometheus scrapes OpenMetrics (3.14's default, unless scrapeProtocols or a flag
# that prefers protobuf changes it) and keeps them only with exemplar-storage, in a small buffer;
# Grafana's Prometheus data source opens an exemplar's trace_id in Tempo (uid tempo).
set -euo pipefail

cd "$(dirname "$0")/../.."
kps=${1:-monitoring/kube-prometheus-stack.values.yaml}
col=${2:-monitoring/otel-collector.values.yaml}
fail=0
err() { echo "::error file=$1::$2"; fail=1; }
q() { yq -o=json -I=0 "$1" "$2"; }

spec='.prometheus.prometheusSpec'
[ "$(q "[${spec}.enableFeatures[]?] | any_c(. == \"exemplar-storage\")" "$kps")" = true ] \
  || err "$kps" "prometheusSpec.enableFeatures must contain exemplar-storage (Prometheus drops exemplars without it)"
max=$(q "${spec}.exemplars.maxSize // 0" "$kps")
[[ "$max" =~ ^[0-9]+$ ]] && [ "$max" -ge 1000 ] && [ "$max" -le 200000 ] \
  || err "$kps" "prometheusSpec.exemplars.maxSize must be set, 1000-200000 (an in-memory buffer; 100000 = about 18 MiB), got ${max}"

# Exemplars travel in OpenMetrics: it must stay the first protocol Prometheus asks for.
first=$(q "${spec}.scrapeProtocols[0] // \"\"" "$kps")
if [ "$first" != '""' ]; then
  [[ "$first" == '"OpenMetricsText'* ]] || err "$kps" "prometheusSpec.scrapeProtocols must start with OpenMetricsText (got ${first})"
elif [ "$(q "[${spec}.enableFeatures[]?] | any_c(. == \"created-timestamp-zero-ingestion\" or . == \"st-storage\")" "$kps")" = true ]; then
  err "$kps" "this feature flag makes Prometheus prefer protobuf: set scrapeProtocols with OpenMetricsText1.0.0 first"
fi

dest='.grafana.additionalDataSources[] | select(.uid == "prometheus") | .jsonData.exemplarTraceIdDestinations[]?'
[ "$(q "[${dest} | select(.name == \"trace_id\" and .datasourceUid == \"tempo\")] | length" "$kps")" -ge 1 ] \
  || err "$kps" "the Prometheus data source must link exemplars to Tempo: exemplarTraceIdDestinations {name: trace_id, datasourceUid: tempo}"
if yq "${dest} | .. | select(tag == \"!!str\")" "$kps" | grep -E '(^|[^$])\$\{' >/dev/null; then
  err "$kps" "exemplarTraceIdDestinations has an unescaped \${...}: Grafana empties it at provisioning (write \$\${...})"
fi

[ "$(q '.config.connectors.spanmetrics.exemplars.enabled' "$col")" = true ] \
  || err "$col" "spanmetrics exemplars.enabled must be true (the trace IDs on the latency buckets)"
[ "$(q '.config.exporters["prometheus/span-metrics"].enable_open_metrics' "$col")" = true ] \
  || err "$col" "prometheus/span-metrics enable_open_metrics must be true (the classic text format has no exemplars)"

[ "$fail" -eq 0 ] || exit 1
echo "Exemplars: collector -> Prometheus (exemplar-storage, maxSize ${max}) -> Grafana -> Tempo (${kps}, ${col})."
