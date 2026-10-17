"""OpenTelemetry tracing for inventoryservice (ADR 0010), started only with ENABLE_TRACING=1.

Same rules as the other Python services (recommendationservice/tracing.py):
- service name and resource attributes from OTEL_SERVICE_NAME / OTEL_RESOURCE_ATTRIBUTES; the
  service's own name only when OTEL_SERVICE_NAME is not set;
- ParentBased(ALWAYS_ON) sampler, W3C trace context + baggage;
- BatchSpanProcessor: spans are exported by a background thread and dropped when the queue is
  full; a request never waits on the collector. The SDK suppresses instrumentation while it
  exports, so the exporter's own calls are not traced.

What is traced here:
- the REST API (http.server has no official instrumentation): one SERVER span per request, named
  after the route ("GET /stock/{productId}"); /healthz, /readyz and /metrics are left out;
- each OrderCreated message: one CONSUMER span ("process OrderCreated"), with its DynamoDB and
  EventBridge calls as children (botocore instrumentation: the AWS operation and table, never
  request or response bodies). The span joins checkout's trace: EventBridge has no message
  attributes, so checkoutservice puts the W3C context in the event detail ("_trace":
  {"traceparent", "tracestate"}, src/checkoutservice/asyncevents.go). take_trace() removes it
  before the event is parsed, tracing on or off; events without it start a new trace as before;
- the InventoryReserved / InventoryFailed publish: a PRODUCER span, and its context in the
  event's "_trace" (with_trace(), only while a span is recording), for the order-status Lambda
  and emailservice. Span attributes: the order ID and messaging fields, never the email address;
- not the SQS long poll: a 20 s ReceiveMessage would be a 20 s span every poll, kept by the
  collector's "slow trace" rule. It runs with instrumentation suppressed (quiet()).
"""
import contextlib
import json
import os

_tracer = None


def tracing_resource(default_service_name):
    """OTEL_SERVICE_NAME / OTEL_RESOURCE_ATTRIBUTES, and the default name only when no name is set
    (passing it to Resource.create would override OTEL_SERVICE_NAME)."""
    from opentelemetry.sdk.resources import SERVICE_NAME, Resource

    resource = Resource.create()
    if str(resource.attributes.get(SERVICE_NAME, "")).startswith("unknown_service"):
        resource = resource.merge(Resource({SERVICE_NAME: default_service_name}))
    return resource


def start_tracing(default_service_name, logger, exporter=None, env=os.environ):
    """Returns the TracerProvider, or None when tracing is off or could not start (logged)."""
    global _tracer
    if env.get("ENABLE_TRACING") != "1":
        logger.info("Tracing disabled.")
        return None
    try:
        from opentelemetry import trace
        from opentelemetry.baggage.propagation import W3CBaggagePropagator
        from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
        from opentelemetry.instrumentation.botocore import BotocoreInstrumentor
        from opentelemetry.propagate import set_global_textmap
        from opentelemetry.propagators.composite import CompositePropagator
        from opentelemetry.sdk.trace import TracerProvider
        from opentelemetry.sdk.trace.export import BatchSpanProcessor
        from opentelemetry.sdk.trace.sampling import ALWAYS_ON, ParentBased
        from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator

        provider = TracerProvider(resource=tracing_resource(default_service_name), sampler=ParentBased(ALWAYS_ON))
        if exporter is None:
            exporter = OTLPSpanExporter(endpoint=env["COLLECTOR_SERVICE_ADDR"], insecure=True)
        provider.add_span_processor(BatchSpanProcessor(exporter))
        trace.set_tracer_provider(provider)
        set_global_textmap(CompositePropagator([TraceContextTextMapPropagator(), W3CBaggagePropagator()]))
        BotocoreInstrumentor().instrument()
        _tracer = trace.get_tracer("inventoryservice")
    except Exception as err:  # tracing must never stop the service from starting
        logger.warning(f"Tracing could not start, continuing without it: {err}")
        return None
    logger.info("Tracing enabled.")
    return provider


UNTRACED_PATHS = ("/healthz", "/readyz", "/metrics")


@contextlib.contextmanager
def server_span(method, route, path, headers):
    """A SERVER span for one API request, continuing the caller's trace (W3C headers). Yields the
    span (or None when tracing is off or the path is a probe) to set the status code on."""
    if _tracer is None or path in UNTRACED_PATHS:
        yield None
        return
    from opentelemetry import propagate, trace

    ctx = propagate.extract(dict(headers.items()))
    with _tracer.start_as_current_span(f"{method} {route}", context=ctx, kind=trace.SpanKind.SERVER,
                                       attributes={"http.method": method, "http.route": route}) as span:
        yield span


def set_status_code(span, code):
    if span is None:
        return
    from opentelemetry.trace import Status, StatusCode

    span.set_attribute("http.status_code", code)
    if code >= 500:
        span.set_status(Status(StatusCode.ERROR))


TRACE_FIELD = "_trace"


def take_trace(sqs_body):
    """Splits an SQS body (an EventBridge event) into (the body without detail._trace, the W3C
    carrier). A body that is not JSON or has no trace field comes back unchanged with {}."""
    try:
        event = json.loads(sqs_body)
    except (TypeError, ValueError):
        return sqs_body, {}
    detail = event.get("detail") if isinstance(event, dict) else None
    if not isinstance(detail, dict) or TRACE_FIELD not in detail:
        return sqs_body, {}
    raw = detail.pop(TRACE_FIELD)
    if not isinstance(raw, dict):
        return json.dumps(event), {}
    # Only the two W3C keys, as short strings: the field comes from a message, not from us.
    carrier = {k: raw[k] for k in ("traceparent", "tracestate") if isinstance(raw.get(k), str) and len(raw[k]) <= 512}
    return json.dumps(event), carrier


@contextlib.contextmanager
def consumer_span(name, attributes=None, carrier=None):
    """A CONSUMER span for one queue message (its AWS calls become children), a child of the
    producer span in carrier (from take_trace) when there is one, else a new trace."""
    if _tracer is None:
        yield None
        return
    from opentelemetry import trace
    from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator

    ctx = TraceContextTextMapPropagator().extract(carrier) if carrier else None
    with _tracer.start_as_current_span(name, context=ctx, kind=trace.SpanKind.CONSUMER,
                                       attributes=attributes or {}) as span:
        yield span


@contextlib.contextmanager
def producer_span(name, bus, order_id):
    """A PRODUCER span around PutEvents: the bus and the order, never the shopper."""
    if _tracer is None:
        yield None
        return
    from opentelemetry import trace

    with _tracer.start_as_current_span(name, kind=trace.SpanKind.PRODUCER, attributes={
            "messaging.system": "aws_eventbridge", "messaging.operation": "publish",
            "messaging.destination.name": bus, "boutique.order_id": order_id}) as span:
        yield span


def with_trace(detail):
    """detail plus "_trace" (the current span's W3C context, never baggage) while a span is
    recording; detail unchanged otherwise (tracing off)."""
    if _tracer is None:
        return detail
    from opentelemetry import trace
    from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator

    if not trace.get_current_span().is_recording():
        return detail
    carrier = {}
    TraceContextTextMapPropagator().inject(carrier)
    return {**detail, TRACE_FIELD: carrier} if carrier.get("traceparent") else detail


def set_order_id(span, order_id):
    if span is not None:
        span.set_attribute("boutique.order_id", order_id)


@contextlib.contextmanager
def quiet():
    """No spans inside (instrumentation suppressed): for the SQS long poll."""
    if _tracer is None:
        yield
        return
    from opentelemetry import context
    from opentelemetry.instrumentation.utils import _SUPPRESS_INSTRUMENTATION_KEY

    token = context.attach(context.set_value(_SUPPRESS_INSTRUMENTATION_KEY, True))
    try:
        yield
    finally:
        context.detach(token)
