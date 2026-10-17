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
  request or response bodies);
- not the SQS long poll: a 20 s ReceiveMessage would be a 20 s span every poll, kept by the
  collector's "slow trace" rule. It runs with instrumentation suppressed (quiet()).
"""
import contextlib
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


@contextlib.contextmanager
def consumer_span(name, attributes=None):
    """A CONSUMER span for one queue message (its AWS calls become children)."""
    if _tracer is None:
        yield None
        return
    from opentelemetry import trace

    with _tracer.start_as_current_span(name, kind=trace.SpanKind.CONSUMER, attributes=attributes or {}) as span:
        yield span


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
