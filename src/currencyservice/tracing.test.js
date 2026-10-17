// Tests of tracing.js (node --test; no extra dependency). Same file in currencyservice and
// paymentservice, only SERVICE differs.
'use strict';

const { test, afterEach } = require('node:test');
const assert = require('node:assert');
const api = require('@opentelemetry/api');
const { InMemorySpanExporter } = require('@opentelemetry/sdk-trace-base');
const { startTracing } = require('./tracing');

const SERVICE = require('./package.json').name === 'grpc-currency-service' ? 'currencyservice' : 'paymentservice';
const ON = { ENABLE_TRACING: '1', COLLECTOR_SERVICE_ADDR: '127.0.0.1:1' }; // nothing listens there

let sdk = null;
afterEach(async () => {
  // shutdown flushes: to a closed port it fails, which only matters to the test, not a service
  if (sdk) await Promise.race([sdk.shutdown().catch(() => {}), new Promise(r => setTimeout(r, 2000))]);
  sdk = null;
  for (const k of ['OTEL_SERVICE_NAME', 'OTEL_RESOURCE_ATTRIBUTES']) delete process.env[k];
  api.trace.disable(); api.context.disable(); api.propagation.disable();
});

async function flush() {
  await api.trace.getTracerProvider().getDelegate().forceFlush();
}

test('off unless ENABLE_TRACING=1', () => {
  assert.strictEqual(startTracing(SERVICE, { env: {} }), null);
  assert.strictEqual(startTracing(SERVICE, { env: { ENABLE_TRACING: '0' } }), null);
});

test('service name and attributes from OTEL_SERVICE_NAME / OTEL_RESOURCE_ATTRIBUTES', async () => {
  process.env.OTEL_SERVICE_NAME = `${SERVICE}-from-env`;
  process.env.OTEL_RESOURCE_ATTRIBUTES = 'deployment.environment=dev,service.namespace=boutique';
  const exporter = new InMemorySpanExporter();
  sdk = startTracing(SERVICE, { exporter, env: ON });
  api.trace.getTracer('test').startSpan('work').end();
  await flush();
  const [span] = exporter.getFinishedSpans();
  assert.strictEqual(span.resource.attributes['service.name'], `${SERVICE}-from-env`);
  assert.strictEqual(span.resource.attributes['deployment.environment'], 'dev');
  assert.strictEqual(span.resource.attributes['service.namespace'], 'boutique');
});

test('default service name without OTEL_SERVICE_NAME (never unknown_service:node)', async () => {
  const exporter = new InMemorySpanExporter();
  sdk = startTracing(SERVICE, { exporter, env: ON });
  api.trace.getTracer('test').startSpan('work').end();
  await flush();
  assert.strictEqual(exporter.getFinishedSpans()[0].resource.attributes['service.name'], SERVICE);
});

test('ParentBased sampler and W3C propagation', async () => {
  const exporter = new InMemorySpanExporter();
  sdk = startTracing(SERVICE, { exporter, env: ON });
  const tracer = api.trace.getTracer('test');
  // An unsampled caller (traceparent flag 00): the span follows it and is not recorded.
  const unsampled = api.propagation.extract(api.context.active(),
    { traceparent: '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-00' });
  assert.strictEqual(tracer.startSpan('child', {}, unsampled).isRecording(), false);
  // A sampled caller: same trace ID, recorded.
  const sampled = api.propagation.extract(api.context.active(),
    { traceparent: '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01' });
  const child = tracer.startSpan('child', {}, sampled);
  assert.strictEqual(child.isRecording(), true);
  assert.strictEqual(child.spanContext().traceId, '0af7651916cd43dd8448eb211c80319c');
  // A new root is sampled, and its context goes out as a W3C traceparent.
  const root = tracer.startSpan('root');
  const carrier = {};
  api.propagation.inject(api.trace.setSpan(api.context.active(), root), carrier);
  assert.match(carrier.traceparent, /^00-[0-9a-f]{32}-[0-9a-f]{16}-01$/);
  root.end(); child.end();
});

test('collector unreachable: spans never wait, failed exports never crash', async () => {
  const unhandled = [];
  const onUnhandled = e => unhandled.push(e);
  process.on('unhandledRejection', onUnhandled);
  const start = Date.now();
  sdk = startTracing(SERVICE, { env: ON }); // the real OTLP exporter, to a closed port
  const tracer = api.trace.getTracer('test');
  for (let i = 0; i < 200; i++) tracer.startSpan(`request ${i}`).end();
  assert.ok(Date.now() - start < 1000, `took ${Date.now() - start} ms`);
  // The batch processor exports every 5 s: let one export fail in the background.
  await new Promise(r => setTimeout(r, 6500));
  process.off('unhandledRejection', onUnhandled);
  assert.deepStrictEqual(unhandled, [], 'a failed export became an unhandled rejection');
});
