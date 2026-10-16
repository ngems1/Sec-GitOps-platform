#!/usr/bin/env bash
# Shared by deploy/monitoring.sh (Grafana) and deploy/argocd-ui.sh (Argo CD UI): turns an
# "allowed addresses" GitHub variable into the comma-separated list the ALB annotation
# alb.ingress.kubernetes.io/inbound-cidrs expects.
#   source deploy/cidrs.sh
#   list=$(allowed_cidrs MONITORING_ALLOWED_CIDR "$MONITORING_ALLOWED_CIDR") || exit 1
# Accepts one or more IPv4 CIDRs separated by commas; spaces, tabs and line breaks around them
# are ignored ("203.0.113.7/32, 198.51.100.4/32" is fine). Refuses anything else, and any
# range wider than /8 (0.0.0.0/0 included): the UIs must never be open to the internet.
# The addresses are people's IPs and the Actions logs are public: errors name the entry's
# position, never its value (callers also mask the whole variable).

allowed_cidrs() {
  local name=$1 raw=$2 out="" c i=0 n
  local -a parts
  raw=$(tr -d ' \t\r\n' <<<"$raw")
  IFS=',' read -ra parts <<<"$raw"
  for c in "${parts[@]}"; do
    [ -n "$c" ] || continue
    i=$((i + 1))
    if ! [[ "$c" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]]; then
      echo "::error::${name}: entry ${i} is not an IPv4 CIDR like 203.0.113.7/32" >&2
      return 1
    fi
    for n in 1 2 3 4; do
      if [ "${BASH_REMATCH[$n]}" -gt 255 ]; then
        echo "::error::${name}: entry ${i} has an address part above 255" >&2
        return 1
      fi
    done
    if [ "${BASH_REMATCH[5]}" -gt 32 ] || [ "${BASH_REMATCH[5]}" -lt 8 ]; then
      echo "::error::${name}: entry ${i} has prefix /${BASH_REMATCH[5]}: use /8 to /32 (your IP is /32); never the whole internet" >&2
      return 1
    fi
    out="${out:+${out},}${c}"
  done
  if [ -z "$out" ]; then
    echo "::error::${name} has no CIDR in it" >&2
    return 1
  fi
  printf '%s' "$out"
}
