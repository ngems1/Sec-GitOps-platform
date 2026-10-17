#!/bin/sh
# adservice entrypoint (ADR 0010). The OpenTelemetry Java agent is always on the JVM command line
# (JAVA_TOOL_OPTIONS in the Dockerfile) but active only with ENABLE_TRACING=1, the same switch as
# the other services; it then exports OTLP gRPC to COLLECTOR_SERVICE_ADDR (plain text inside the
# cluster). Otherwise OTEL_JAVAAGENT_ENABLED=false and the agent does nothing. Service name and
# resource attributes: OTEL_SERVICE_NAME / OTEL_RESOURCE_ATTRIBUTES (Helm chart).
set -eu
if [ "${ENABLE_TRACING:-}" = "1" ] && [ -n "${COLLECTOR_SERVICE_ADDR:-}" ]; then
  export OTEL_JAVAAGENT_ENABLED=true
  export OTEL_EXPORTER_OTLP_ENDPOINT="http://${COLLECTOR_SERVICE_ADDR}"
  echo "Tracing enabled (OpenTelemetry Java agent, collector ${COLLECTOR_SERVICE_ADDR})."
else
  export OTEL_JAVAAGENT_ENABLED=false
  echo "Tracing disabled."
fi
# ADSERVICE_BIN only for test-entrypoint.sh (CI).
exec "${ADSERVICE_BIN:-/app/build/install/hipstershop/bin/AdService}" "$@"
