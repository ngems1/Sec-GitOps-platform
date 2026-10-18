#!/usr/bin/env bash
# CI check: Grafana keeps its trace <-> logs links (ADR 0011, PR 4; RUNBOOK section 12).
#
#   deploy/tests/grafana-links-check.sh [kube-prometheus-stack values] [logs-traces dashboard] [boutique dashboard]
#   default: monitoring/kube-prometheus-stack.values.yaml monitoring/dashboards/logs-traces.json
#            monitoring/dashboards/boutique.json
#
# Tempo -> CloudWatch: Grafana's tracesToLogsV2 has no CloudWatch support, so the provisioned
# Tempo data source carries a correlation (traceID -> a Logs Insights query of the application log
# group). CloudWatch -> Tempo: a correlation on the trace_id field. Their variables must be
# written $${...}: Grafana expands ${...} in provisioning files as environment variables, which
# emptied them. The dashboard keeps its "Open trace" / "Logs for this trace" links.
# Service Graph (ADR 0011, PR 7): the Tempo data source reads the service graph from Prometheus
# (serviceMap) and draws node graphs; the Boutique dashboard keeps its Service graph panel and
# exemplars on its span latency panel.
set -euo pipefail

cd "$(dirname "$0")/../.."
values=${1:-monitoring/kube-prometheus-stack.values.yaml}
dashboard=${2:-monitoring/dashboards/logs-traces.json}
boutique=${3:-monitoring/dashboards/boutique.json}
LOG_GROUP=/aws/containerinsights/week3-boutique-eks/application
fail=0
err() { echo "::error file=$1::$2"; fail=1; }

ds() { # uid -> that additional data source as JSON
  yq -o=json -I=0 ".grafana.additionalDataSources[] | select(.uid == \"$1\")" "$values"
}
tempo=$(ds tempo); cloudwatch=$(ds cloudwatch)
[ -n "$tempo" ] || err "$values" "no Tempo data source (uid tempo)"
[ -n "$cloudwatch" ] || err "$values" "no CloudWatch data source (uid cloudwatch)"

t=$(jq -c '[.correlations[]? | select(.targetUID == "cloudwatch" and .type == "query" and .config.field == "traceID")][0] // empty' <<< "$tempo")
if [ -z "$t" ]; then
  err "$values" "Tempo lost its logs link: no correlation to cloudwatch on field traceID (trace -> logs)"
else
  jq -e '.config.target.queryMode == "Logs"' <<< "$t" >/dev/null || err "$values" "Tempo -> logs: target is not a Logs Insights query"
  jq -e --arg g "$LOG_GROUP" '.config.target.logGroupNames | index($g)' <<< "$t" >/dev/null || err "$values" "Tempo -> logs: not the log group $LOG_GROUP"
  jq -e '.config.target.expression | contains("filter trace_id = \"$${traceID}\"")' <<< "$t" >/dev/null \
    || err "$values" "Tempo -> logs: the query must filter trace_id = \"\$\${traceID}\" (escaped \$\$)"
fi

c=$(jq -c '[.correlations[]? | select(.targetUID == "tempo" and .type == "query" and .config.field == "trace_id")][0] // empty' <<< "$cloudwatch")
if [ -z "$c" ]; then
  err "$values" "CloudWatch lost its trace link: no correlation to tempo on field trace_id (logs -> trace)"
else
  jq -e '.config.target.queryType == "traceql" and .config.target.query == "$${trace_id}"' <<< "$c" >/dev/null \
    || err "$values" "logs -> trace: the Tempo query must be \$\${trace_id} (escaped \$\$)"
fi

# Every ${...} in a correlation must be escaped as $${...}.
if jq -r '.correlations[]?.config.target | .. | strings' <<< "$tempo $cloudwatch" | grep -E '(^|[^$])\$\{' >/dev/null; then
  err "$values" "a correlation has an unescaped \${...}: Grafana empties it at provisioning (write \$\${...})"
fi

[ -f "$dashboard" ] || err "$dashboard" "missing"
if [ -f "$dashboard" ]; then
  open=$(jq '[.. | objects | select(.title? == "Open trace" and .internal.datasourceUid? == "tempo")] | length' "$dashboard")
  logs=$(jq '[.. | objects | select(.title? == "Logs for this trace" and ((.url? // "") | contains("var-trace_id=${__value.raw}")))] | length' "$dashboard")
  [ "$open" -ge 3 ] || err "$dashboard" "expected 3 'Open trace' links to Tempo, found $open"
  [ "$logs" -ge 2 ] || err "$dashboard" "expected 2 'Logs for this trace' links, found $logs"
fi

jq -e '.jsonData.serviceMap.datasourceUid == "prometheus" and .jsonData.nodeGraph.enabled == true' <<< "$tempo" >/dev/null \
  || err "$values" "Tempo lost its Service Graph: jsonData.serviceMap.datasourceUid must be prometheus and nodeGraph.enabled true"

[ -f "$boutique" ] || err "$boutique" "missing"
if [ -f "$boutique" ]; then
  graph=$(jq '[.panels[] | select(.type == "nodeGraph" and .datasource.uid == "tempo" and any(.targets[]?; .queryType == "serviceMap"))] | length' "$boutique")
  ex=$(jq '[.panels[] | select(any(.targets[]?; (.expr // "" | contains("traces_spanmetrics_latency_bucket")) and .exemplar == true))] | length' "$boutique")
  [ "$graph" -ge 1 ] || err "$boutique" "no Service graph panel (nodeGraph on Tempo, queryType serviceMap)"
  [ "$ex" -ge 1 ] || err "$boutique" "no span latency panel (traces_spanmetrics_latency_bucket) with exemplars on"
fi

[ "$fail" -eq 0 ] || exit 1
echo "Grafana trace <-> logs links and Service Graph in place (${values}, ${dashboard}, ${boutique})."
