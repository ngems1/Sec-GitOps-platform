#!/usr/bin/env bash
# CI check: every PromQL query of the Grafana dashboards parses (RUNBOOK section 5).
#
#   deploy/tests/promql-check.sh [dashboard.json...]   default: monitoring/dashboards/*.json
#   PROMTOOL=/path/to/promtool (default: promtool on PATH)
#
# Each Prometheus target's expr (CloudWatch targets use "expression", not "expr") becomes one
# recording rule in a temporary rules file, checked by `promtool check rules`. Grafana
# variables are replaced first: $__rate_interval / $__interval / $__range by 5m, any other
# ${var} or $var by "dummy". Catches what broke Order success and Pods not ready after #61:
# label values without quotes (namespace=boutique-prod), which Prometheus rejects as bad_data.
set -euo pipefail

cd "$(dirname "$0")/../.."
files=("$@")
[ ${#files[@]} -gt 0 ] || files=(monitoring/dashboards/*.json)
promtool=${PROMTOOL:-promtool}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail=0
for f in "${files[@]}"; do
  # One rule per expr: record name "dashboard:p<panel id>_<n>", the panel title kept for messages.
  jq '[.. | objects | select(has("targets")) | . as $p | (.targets // [])
        | to_entries[] | select((.value.expr // "") != "")
        | {title: ($p.title // "?"), record: "dashboard:p\($p.id // 0)_\(.key)", expr: .value.expr}]' "$f" > "$work/exprs.json"
  n=$(jq length "$work/exprs.json")
  jq '{groups: [{name: "dashboard", rules: [.[] | {record, expr: (.expr
        | gsub("\\$(__rate_interval|__interval|__range)\\b"; "5m")
        | gsub("\\$\\{__(rate_interval|interval|range)\\}"; "5m")
        | gsub("\\$\\{[^}]*\\}"; "dummy")
        | gsub("\\$[A-Za-z_][A-Za-z0-9_]*"; "dummy"))}]}]}' "$work/exprs.json" > "$work/rules.json"
  if out=$("$promtool" check rules "$work/rules.json" 2>&1); then
    echo "${f}: ${n} PromQL queries parse"
  else
    fail=1
    echo "::error file=${f}::PromQL that Prometheus cannot parse (label values need quotes: namespace=\"boutique-prod\")"
    echo "$out" | sed 's/^/  /'
    # promtool names the rule by its position: show the panel behind each failing one.
    jq -r 'to_entries[] | "  rule \(.key + 1): \(.value.record) = \(.value.title): \(.value.expr)"' "$work/exprs.json" \
      | grep -E "^  rule ($(echo "$out" | grep -oE 'rule ([0-9]+)' | awk '{print $2}' | paste -sd'|' -)):" || true
  fi
done
exit "$fail"
