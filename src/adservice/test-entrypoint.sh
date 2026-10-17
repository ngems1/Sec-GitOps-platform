#!/usr/bin/env bash
# CI test of docker-entrypoint.sh (ADR 0010): the Java agent is active only with ENABLE_TRACING=1 and
# then exports to COLLECTOR_SERVICE_ADDR. The entrypoint runs `env` instead of the JVM here.
set -euo pipefail
here=$(dirname "$0")
run() { env -i PATH="$PATH" ADSERVICE_BIN=env "$@" sh "$here/docker-entrypoint.sh"; }
fail() { echo "::error::adservice entrypoint: $1"; exit 1; }

out=$(run ENABLE_TRACING=1 COLLECTOR_SERVICE_ADDR=otel-collector.monitoring.svc:4317)
grep -qx 'OTEL_JAVAAGENT_ENABLED=true' <<<"$out" || fail "agent not enabled with ENABLE_TRACING=1"
grep -qx 'OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.monitoring.svc:4317' <<<"$out" || fail "wrong collector endpoint"

for env in "ENABLE_TRACING=0" "ENABLE_TRACING=" "ENABLE_TRACING=1"; do  # the last one: no collector address
  out=$(run "$env")
  grep -qx 'OTEL_JAVAAGENT_ENABLED=false' <<<"$out" || fail "agent not disabled with ${env} (and no collector)"
  ! grep -q '^OTEL_EXPORTER_OTLP_ENDPOINT=' <<<"$out" || fail "endpoint set while disabled"
done
echo "adservice entrypoint: OK"
