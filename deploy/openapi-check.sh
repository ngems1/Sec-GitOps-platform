#!/usr/bin/env bash
# Read-only: GET /openapi/v2 through kubectl proxy, in the protobuf form Argo CD asks for
# and in JSON (what "kubectl get --raw" gets). Prints OK/failed counts and the HTTP codes.
#   openapi-check.sh [tries]   (default 10, 2 s apart)
# Used by .github/workflows/eks-openapi-fix.yml.
set -u
tries="${1:-10}"
port=8001
base="http://127.0.0.1:${port}"
tmp=$(mktemp -d)

kubectl proxy --port="$port" >"$tmp/proxy.log" 2>&1 &
proxy=$!
trap 'kill "$proxy" 2>/dev/null; rm -rf "$tmp"' EXIT
for _ in $(seq 1 30); do
  curl -sf -o /dev/null "$base/version" && break
  sleep 1
done
if ! curl -sf -o /dev/null "$base/version"; then
  echo "kubectl proxy did not start:"
  cat "$tmp/proxy.log"
  exit 1
fi

names=(protobuf json)
declare -A accept=(
  [protobuf]='application/com.github.proto-openapi.spec.v2@v1.0+protobuf'
  [json]='application/json'
)
declare -A ok fail codes first
for n in "${names[@]}"; do ok[$n]=0; fail[$n]=0; codes[$n]=""; first[$n]=""; done

# Each round tries both forms, so they see the same moments.
for i in $(seq 1 "$tries"); do
  for n in "${names[@]}"; do
    code=$(curl -s -o "$tmp/body" -w '%{http_code}' --max-time 30 \
      -H "Accept: ${accept[$n]}" "$base/openapi/v2") || true
    codes[$n]+="${code} "
    if [ "$code" = 200 ]; then
      ok[$n]=$(( ok[$n] + 1 ))
    else
      fail[$n]=$(( fail[$n] + 1 ))
      # 000 = no HTTP answer (timeout or connection error).
      [ -n "${first[$n]}" ] || first[$n]="attempt ${i}, HTTP ${code}: $(head -c 300 "$tmp/body" 2>/dev/null | tr -c '[:print:]' ' ')"
    fi
  done
  [ "$i" = "$tries" ] || sleep 2
done

echo "GET /openapi/v2 through kubectl proxy (${tries} tries each, 2 s apart, 30 s timeout)"
for n in "${names[@]}"; do
  printf '%-9s OK %2d  failed %2d  codes: %s\n' "$n" "${ok[$n]}" "${fail[$n]}" "${codes[$n]}"
  printf '          Accept: %s\n' "${accept[$n]}"
done
for n in "${names[@]}"; do
  [ -z "${first[$n]}" ] || echo "first ${n} failure: ${first[$n]}"
done
