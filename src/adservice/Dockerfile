# Copyright 2020 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

FROM eclipse-temurin:21-jdk AS builder

WORKDIR /app

COPY ["build.gradle", "gradlew", "./"]
COPY gradle gradle
RUN chmod +x gradlew
RUN ./gradlew downloadRepos

COPY . .
RUN chmod +x gradlew
RUN ./gradlew installDist

# Week 3: runtime base image updated (the 2023 image had CRITICAL CVEs, blocked by the ECR scan gate)
FROM eclipse-temurin:21-jre-alpine

# Week 3: security fixes on top of the base image. The Google Cloud Profiler agent
# that used to be downloaded here is gone: it only works on GCP.
RUN apk upgrade --no-cache && apk add --no-cache ca-certificates

WORKDIR /app
COPY --from=builder /app .

# OpenTelemetry Java agent (ADR 0010), pinned and checked: the SHA-256 is the one GitHub publishes
# for this release asset. Active only with ENABLE_TRACING=1 (docker-entrypoint.sh).
ARG OTEL_JAVAAGENT_VERSION=2.32.0
ARG OTEL_JAVAAGENT_SHA256=f787eb6c7f3d18e69a431e108a15278d25ee37f83d68b678f621e063f3988f82
RUN wget -q -O /app/opentelemetry-javaagent.jar \
      "https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v${OTEL_JAVAAGENT_VERSION}/opentelemetry-javaagent.jar" \
    && echo "${OTEL_JAVAAGENT_SHA256}  /app/opentelemetry-javaagent.jar" | sha256sum -c - \
    && chmod 0444 /app/opentelemetry-javaagent.jar && chmod 0755 /app/docker-entrypoint.sh
# Agent settings that never change. Only two instrumentations are on (low overhead: no JVM,
# executor or HTTP-client instrumentation): gRPC server and client, and Log4j context data, which
# puts the active span's trace_id / span_id / trace_flags in the log lines (ADR 0011; without it
# the JSON lines had no IDs; test-log-trace-ids.sh checks it). Traces only, W3C context, and the
# caller's sampling decision is followed (the collector's tail sampling decides).
ENV JAVA_TOOL_OPTIONS="-javaagent:/app/opentelemetry-javaagent.jar" \
    OTEL_JAVAAGENT_ENABLED=false \
    OTEL_SERVICE_NAME=adservice \
    OTEL_EXPORTER_OTLP_PROTOCOL=grpc \
    OTEL_TRACES_EXPORTER=otlp \
    OTEL_METRICS_EXPORTER=none \
    OTEL_LOGS_EXPORTER=none \
    OTEL_TRACES_SAMPLER=parentbased_always_on \
    OTEL_PROPAGATORS=tracecontext,baggage \
    OTEL_INSTRUMENTATION_COMMON_DEFAULT_ENABLED=false \
    OTEL_INSTRUMENTATION_GRPC_ENABLED=true \
    OTEL_INSTRUMENTATION_LOG4J_CONTEXT_DATA_ENABLED=true

EXPOSE 9555
ENTRYPOINT ["/app/docker-entrypoint.sh"]
