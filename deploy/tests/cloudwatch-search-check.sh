#!/usr/bin/env bash
# CI check: CloudWatch SEARCH terms must be token matches (RUNBOOK section 5).
#
#   deploy/tests/cloudwatch-search-check.sh [file...]
#   default: monitoring/dashboards/boutique.json deploy/diagnose.sh
#
# In a SEARCH term, a double-quoted string is an exact match of a WHOLE metric name, dimension
# name or dimension value: SEARCH('... "boutique-dev"') never matches the ALB dimension value
# app/boutique-dev/<id>. Unquoted, boutique-dev is a token match. Fails when a SEARCH term quotes
# anything other than MetricName="...". For the dashboard it also checks that a panel titled
# "dev" or "prod" searches only its own ALB (boutique-dev / boutique-prod).
set -euo pipefail

cd "$(dirname "$0")/../.."
files=("$@")
[ ${#files[@]} -gt 0 ] || files=(monitoring/dashboards/boutique.json deploy/diagnose.sh)

fail=0
for f in "${files[@]}"; do
  # Every SEARCH expression, one per line, with shell-escaped quotes (\") made plain.
  if [[ "$f" == *.json ]]; then
    # CloudWatch targets only (the panel's or the target's data source uid "cloudwatch"): PromQL
    # in the same file has quoted label values on purpose (deploy/tests/promql-check.sh).
    exprs=$(jq -r '.. | objects | select(has("targets")) | . as $p | (.targets // [])[]
      | select(((.datasource.uid // $p.datasource.uid) // "") == "cloudwatch") | (.expression // empty)' "$f")
  else
    exprs=$(grep -F 'SEARCH(' "$f" | sed 's/\\"/"/g')
  fi
  while IFS= read -r term; do
    [ -n "$term" ] || continue
    # The search term is the first argument; drop MetricName="..." and the {schema}.
    rest=$(sed -E 's/MetricName="[^"]*"//g; s/\{[^}]*\}//' <<< "$term")
    if [[ "$rest" == *'"'* ]]; then
      echo "::error file=${f}::CloudWatch SEARCH quotes a term (exact whole-value match, never a fragment): ${term}"
      fail=1
    fi
  done < <(grep -oE "SEARCH\('[^']*'" <<< "$exprs" || true)

  if [[ "$f" == *.json ]]; then
    # A dev panel must not search the prod ALB, and the reverse.
    wrong=$(jq -r '.panels[]? | select(.title | test("\\b(dev|prod)\\b")) | .title as $t
      | ($t | capture("\\b(?<env>dev|prod)\\b").env) as $env
      | (if $env == "dev" then "prod" else "dev" end) as $other
      | [.targets[]? | (.expression // "")] | map(select(test("boutique-" + $other))) | select(length > 0)
      | "\($t): searches boutique-\($other)"' "$f")
    if [ -n "$wrong" ]; then
      echo "::error file=${f}::${wrong}"
      fail=1
    fi
  fi
done

[ "$fail" -eq 0 ] || exit 1
echo "CloudWatch SEARCH terms are token matches (${files[*]})."
