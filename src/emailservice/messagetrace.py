"""Trace context of the OrderStatusUpdated messages (ADR 0010, step 5).

EventBridge has no message attributes, so the W3C context travels in the event detail, in a
"_trace" field ({"traceparent", "tracestate"}): checkoutservice adds it to OrderCreated,
inventoryservice to its result event, and the order-status Lambda copies it to
OrderStatusUpdated. Here:

- take_trace() removes the field before the event is parsed, tracing on or off; events without
  it are handled as before;
- consumer_span() is one CONSUMER span per message, a child of inventory's publish span when the
  field was there (else a new trace). The SQS long poll is not a span. Span attributes: the order
  ID and messaging fields, never the email address.

No span without tracing: the OpenTelemetry API's default provider is a no-op until tracing.py
starts the SDK (ENABLE_TRACING=1). Without the package (the notification unit tests), the
helpers do nothing.
"""
import contextlib
import json

TRACE_FIELD = "_trace"


def take_trace(body):
    """Splits an SQS body (an EventBridge event) into (the body without detail._trace, the W3C
    carrier). A body that is not JSON or has no trace field comes back unchanged with {}."""
    try:
        event = json.loads(body)
    except (TypeError, ValueError):
        return body, {}
    detail = event.get("detail") if isinstance(event, dict) else None
    if not isinstance(detail, dict) or TRACE_FIELD not in detail:
        return body, {}
    raw = detail.pop(TRACE_FIELD)
    if not isinstance(raw, dict):
        return json.dumps(event), {}
    # Only the two W3C keys, as short strings: the field comes from a message, not from us.
    carrier = {k: raw[k] for k in ("traceparent", "tracestate") if isinstance(raw.get(k), str) and len(raw[k]) <= 512}
    return json.dumps(event), carrier


@contextlib.contextmanager
def consumer_span(name, carrier=None, attributes=None):
    """Yields the span (or None without OpenTelemetry). An exception inside marks it as an error."""
    try:
        from opentelemetry import trace
        from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator
    except ImportError:
        yield None
        return
    ctx = TraceContextTextMapPropagator().extract(carrier) if carrier else None
    with trace.get_tracer("emailservice").start_as_current_span(
            name, context=ctx, kind=trace.SpanKind.CONSUMER, attributes=attributes or {}) as span:
        yield span


def set_order_id(span, order_id):
    if span is not None:
        span.set_attribute("boutique.order_id", order_id)
