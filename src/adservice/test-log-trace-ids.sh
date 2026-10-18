#!/usr/bin/env bash
# End-to-end test (ADR 0011): adservice, run with the OpenTelemetry Java agent and EXACTLY the
# environment of its image (the ENV block of the Dockerfile, read from the file so it cannot
# drift) through its own docker-entrypoint.sh, answers one ad request from AdServiceClient. Its
# log line "received ad request" must carry trace_id / span_id / trace_flags with tracing on, and
# none of them with tracing off. It would have caught the agent config that disabled the Log4j
# context-data instrumentation (OTEL_INSTRUMENTATION_COMMON_DEFAULT_ENABLED=false).
#
#   test-log-trace-ids.sh <built app dir (build/install/hipstershop)> <opentelemetry-javaagent.jar>
# Needs java on PATH. Nothing listens on the collector address: spans are dropped, which is fine.
set -euo pipefail

app=$(cd "${1:?built app dir}" && pwd)
agent=$(cd "$(dirname "${2:?agent jar}")" && pwd)/$(basename "$2")
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'kill "${server:-}" 2>/dev/null || true; rm -rf "$work"' EXIT

# The Dockerfile's ENV block as KEY=VALUE lines, with the agent at its local path.
awk '/^ENV JAVA_TOOL_OPTIONS=/ {f = 1}
     f { line = $0; more = (line ~ /\\[ \t]*$/)
         sub(/^ENV /, "", line); sub(/[ \t]*\\[ \t]*$/, "", line); gsub(/^[ \t]+/, "", line)
         print line; if (!more) exit }' "$here/Dockerfile" | sed 's/"//g' > "$work/env"
grep -q '^OTEL_INSTRUMENTATION_COMMON_DEFAULT_ENABLED=' "$work/env" || { echo "FAIL: could not read the Dockerfile ENV block"; cat "$work/env"; exit 1; }
sed -i "s#/app/opentelemetry-javaagent.jar#${agent}#" "$work/env"

run() { # <ENABLE_TRACING> -> the server's "received ad request" line
  local port=$1 tracing=$2
  ( set -a; . "$work/env"; set +a
    export ENABLE_TRACING="$tracing" COLLECTOR_SERVICE_ADDR=127.0.0.1:1 PORT="$port" \
           OTEL_JAVAAGENT_LOGGING=none ADSERVICE_BIN="$app/bin/AdService"
    exec bash "$here/docker-entrypoint.sh" ) > "$work/server-$tracing.log" 2>&1 &
  server=$!
  for _ in $(seq 1 60); do grep -q "Ad Service started" "$work/server-$tracing.log" 2>/dev/null && break; sleep 1; done
  grep -q "Ad Service started" "$work/server-$tracing.log" || { echo "FAIL: adservice did not start"; tail -20 "$work/server-$tracing.log"; exit 1; }
  JAVA_TOOL_OPTIONS= "$app/bin/AdServiceClient" kitchen localhost "$port" > /dev/null 2>&1 || true
  sleep 1
  kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true
  grep '"received ad request' "$work/server-$tracing.log" | head -1
}

on=$(run 19555 1)
off=$(run 19556 "")
echo "tracing on:  ${on}"
echo "tracing off: ${off}"
fail=0
[ -n "$on" ] && [ -n "$off" ] || { echo "FAIL: no 'received ad request' line"; exit 1; }
for f in trace_id span_id trace_flags; do
  grep -q "\"${f}\":\"[0-9a-f]" <<< "$on" || { echo "FAIL: tracing on, no ${f}"; fail=1; }
  if grep -q "\"${f}\"" <<< "$off"; then echo "FAIL: tracing off, ${f} present"; fail=1; fi
done
grep -qE '"trace_flags":"0[01]"' <<< "$on" || { echo "FAIL: trace_flags is not 01/00"; fail=1; }
[ "$fail" -eq 0 ] && echo "adservice log trace IDs: OK"
exit "$fail"
