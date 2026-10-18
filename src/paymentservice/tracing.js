/*
 * OpenTelemetry tracing (ADR 0010), started only with ENABLE_TRACING=1. Same file in
 * currencyservice and paymentservice. Must run BEFORE @grpc/grpc-js is loaded, so the gRPC
 * instrumentation can patch it.
 *   - service name and resource attributes from OTEL_SERVICE_NAME / OTEL_RESOURCE_ATTRIBUTES
 *     (the SDK's env detector, set by the Helm chart), with defaultServiceName as the fallback;
 *   - ParentBased(AlwaysOn) sampler, W3C trace context + baggage propagation;
 *   - BatchSpanProcessor: spans are queued and exported in the background (2048 at most, dropped
 *     beyond); a request never waits on the collector. Exports run with tracing suppressed, so
 *     they are not traced themselves;
 *   - OTLP gRPC to COLLECTOR_SERVICE_ADDR in plain text ("http://": no TLS inside the cluster).
 */
'use strict';

function startTracing(defaultServiceName, { exporter, env = process.env } = {}) {
  if (env.ENABLE_TRACING !== '1') {
    console.log('Tracing disabled.');
    return null;
  }
  console.log('Tracing enabled.');
  const { NodeSDK } = require('@opentelemetry/sdk-node');
  const { BatchSpanProcessor, ParentBasedSampler, AlwaysOnSampler } = require('@opentelemetry/sdk-trace-base');
  const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-grpc');
  const { GrpcInstrumentation } = require('@opentelemetry/instrumentation-grpc');
  const { CompositePropagator, W3CTraceContextPropagator, W3CBaggagePropagator } = require('@opentelemetry/core');
  const { Resource } = require('@opentelemetry/resources');
  const { SemanticResourceAttributes } = require('@opentelemetry/semantic-conventions');

  const sdk = new NodeSDK({
    // Default name only: the env detector (OTEL_SERVICE_NAME) is merged over it at start.
    resource: new Resource({ [SemanticResourceAttributes.SERVICE_NAME]: defaultServiceName }),
    spanProcessor: new BatchSpanProcessor(
      exporter || new OTLPTraceExporter({ url: `http://${env.COLLECTOR_SERVICE_ADDR}` })),
    sampler: new ParentBasedSampler({ root: new AlwaysOnSampler() }),
    textMapPropagator: new CompositePropagator({
      propagators: [new W3CTraceContextPropagator(), new W3CBaggagePropagator()],
    }),
    instrumentations: [new GrpcInstrumentation()],
  });
  sdk.start();
  return sdk;
}

/*
 * Trace context for the JSON logs (ADR 0011, step 6): pino's `mixin` option, so every line
 * logged while a span is active gets
 *   "trace_id": "4bf92f35...", "span_id": "00f067aa...", "trace_flags": "01"
 * (lower-case hex as in a W3C traceparent; the names of ADR 0011, the same in all languages).
 * Nothing is added while tracing is off (no SDK provider: prod today), so a caller's
 * traceparent can never put IDs in our logs, and nothing outside a valid span.
 */
function logTraceFields() {
  const api = require('@opentelemetry/api');
  const provider = api.trace.getTracerProvider();
  const delegate = typeof provider.getDelegate === 'function' ? provider.getDelegate() : provider;
  if (typeof delegate.getActiveSpanProcessor !== 'function') return {}; // the no-op provider
  const sc = api.trace.getSpanContext(api.context.active());
  if (!sc || !api.isSpanContextValid(sc)) return {};
  return {
    trace_id: sc.traceId,
    span_id: sc.spanId,
    trace_flags: (sc.traceFlags & api.TraceFlags.SAMPLED) ? '01' : '00',
  };
}

module.exports = { startTracing, logTraceFields };
