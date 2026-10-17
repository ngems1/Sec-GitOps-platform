#!/usr/bin/env bash
# Renders the resource usage report from a directory holding cpu_avg.json, cpu_p95.json,
# cpu_max.json, mem_p95.json, mem_max.json, hours.json (Prometheus results), pods.json,
# workloads.json and nodes.json (kubectl). Used by deploy/resource-usage.sh, and by CI on testdata/.
#   bash deploy/resource-usage/render.sh DIR
set -euo pipefail
dir=$1
here=$(dirname "$0")
args=()
for f in cpu_avg cpu_p95 cpu_max mem_p95 mem_max hours pods workloads nodes; do
  args+=(--slurpfile "$f" "${dir}/${f}.json")
done
{ jq -rn "${args[@]}" -f "${here}/report.jq"; echo "#__end__"; } | while IFS= read -r line; do
  # Blocks between "#" headings are tables: align each one on its own.
  if [[ "$line" == "#"* || -z "$line" ]]; then
    [ -n "${block:-}" ] && printf '%s' "$block" | column -t -s $'\t'
    block=""
    if [ -n "$line" ] && [ "$line" != "#__end__" ]; then echo; echo "${line#\# }"; fi
  else
    block+="${line}"$'\n'
  fi
done
