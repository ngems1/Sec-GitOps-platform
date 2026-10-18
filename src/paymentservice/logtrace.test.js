// Tests of logTraceFields (tracing.js, ADR 0011): trace_id / span_id / trace_flags in the pino
// JSON lines. Same file in currencyservice and paymentservice.
'use strict';

const { test, afterEach } = require('node:test');
const assert = require('node:assert');
const pino = require('pino');
const api = require('@opentelemetry/api');
const { InMemorySpanExporter } = require('@opentelemetry/sdk-trace-base');
const { AsyncLocalStorageContextManager } = require('@opentelemetry/context-async-hooks');
const { W3CTraceContextPropagator } = require('@opentelemetry/core');
const { startTracing, logTraceFields } = require('./tracing');

const ON = { ENABLE_TRACING: '1', COLLECTOR_SERVICE_ADDR: '127.0.0.1:1' };
const CLIENT = '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01';

let sdk = null;
afterEach(async () => {
  if (sdk) await Promise.race([sdk.shutdown().catch(() => {}), new Promise(r => setTimeout(r, 2000))]);
  sdk = null;
  api.trace.disable(); api.context.disable(); api.propagation.disable();
});

// A logger with the services' options (server.js), writing JSON lines to an array.
function testLogger() {
  const lines = [];
  const logger = pino({
    name: 'test',
    messageKey: 'message',
    mixin: logTraceFields,
    formatters: { level (label) { return { severity: label }; } },
  }, { write (s) { lines.push(JSON.parse(s)); } });
  return { logger, lines };
}

function assertNoTraceFields(line) {
  for (const k of ['trace_id', 'span_id', 'trace_flags']) assert.ok(!(k in line), `${k} should be absent: ${JSON.stringify(line)}`);
}

test('a line inside a span carries its IDs; outside a span, none', () => {
  sdk = startTracing('test', { exporter: new InMemorySpanExporter(), env: ON });
  const { logger, lines } = testLogger();
  let sc;
  api.trace.getTracer('test').startActiveSpan('request', span => {
    sc = span.spanContext();
    logger.info({ currency: 'EUR' }, 'inside');
    span.end();
  });
  logger.info('outside');
  const [inside, outside] = lines;
  assert.strictEqual(inside.trace_id, sc.traceId);
  assert.strictEqual(inside.span_id, sc.spanId);
  assert.strictEqual(inside.trace_flags, '01');
  assert.match(inside.trace_id, /^[0-9a-f]{32}$/);
  // the existing fields stay
  assert.strictEqual(inside.message, 'inside');
  assert.strictEqual(inside.severity, 'info');
  assert.strictEqual(inside.currency, 'EUR');
  assertNoTraceFields(outside);
});

test('an unsampled caller gives trace_flags "00"', () => {
  sdk = startTracing('test', { exporter: new InMemorySpanExporter(), env: ON });
  const { logger, lines } = testLogger();
  const unsampled = api.propagation.extract(api.context.active(), { traceparent: CLIENT.slice(0, -2) + '00' });
  const span = api.trace.getTracer('test').startSpan('child', {}, unsampled);
  api.context.with(api.trace.setSpan(unsampled, span), () => logger.info('unsampled'));
  span.end();
  assert.strictEqual(lines[0].trace_id, span.spanContext().traceId);
  assert.strictEqual(lines[0].span_id, span.spanContext().spanId);
  assert.strictEqual(lines[0].trace_flags, '00');
});

// Tracing off (prod): even with a caller's traceparent in the active context, no IDs.
test('tracing off: no fields, even with a caller traceparent', () => {
  assert.strictEqual(startTracing('test', { env: {} }), null);
  api.context.setGlobalContextManager(new AsyncLocalStorageContextManager().enable());
  const ctx = new W3CTraceContextPropagator().extract(api.ROOT_CONTEXT, { traceparent: CLIENT }, api.defaultTextMapGetter);
  assert.ok(api.isSpanContextValid(api.trace.getSpanContext(ctx)), 'the caller context is there (the case covered)');
  const { logger, lines } = testLogger();
  api.context.with(ctx, () => logger.info('tracing off'));
  assertNoTraceFields(lines[0]);
});
