"""OpenTelemetry tracing (ADR 0010), started only with ENABLE_TRACING=1. Same file in
recommendationservice and emailservice. Call it before any gRPC server or channel is created.

- service name and resource attributes from OTEL_SERVICE_NAME / OTEL_RESOURCE_ATTRIBUTES (set by
  the Helm chart); the service's own name only when OTEL_SERVICE_NAME is not set;
- ParentBased(ALWAYS_ON) sampler, W3C trace context + baggage propagation;
- gRPC server spans (and client spans when instrument_client), whenever tracing is on;
- BatchSpanProcessor: spans are exported by a background thread and dropped when the queue is
  full; a request never waits on the collector. The SDK suppresses instrumentation while it
  exports, so the exporter's own gRPC calls are not traced.
"""
import os


def tracing_resource(default_service_name):
    """The resource: OTEL_SERVICE_NAME / OTEL_RESOURCE_ATTRIBUTES (read by Resource.create), and the
    default name only when no service name is set. Passing the name to Resource.create would
    override OTEL_SERVICE_NAME."""
    from opentelemetry.sdk.resources import SERVICE_NAME, Resource

    resource = Resource.create()
    if str(resource.attributes.get(SERVICE_NAME, "")).startswith("unknown_service"):
        resource = resource.merge(Resource({SERVICE_NAME: default_service_name}))
    return resource


def start_tracing(default_service_name, logger, instrument_client=False, exporter=None, env=os.environ):
    """Returns the TracerProvider, or None when tracing is off or could not start (logged)."""
    if env.get("ENABLE_TRACING") != "1":
        logger.info("Tracing disabled.")
        return None
    try:
        from opentelemetry import trace
        from opentelemetry.baggage.propagation import W3CBaggagePropagator
        from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
        from opentelemetry.instrumentation.grpc import GrpcInstrumentorClient, GrpcInstrumentorServer
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
        GrpcInstrumentorServer().instrument()
        if instrument_client:
            GrpcInstrumentorClient().instrument()
    except Exception as err:  # tracing must never stop the service from starting
        logger.warning(f"Tracing could not start, continuing without it: {err}")
        return None
    logger.info("Tracing enabled.")
    return provider

def log_trace_fields():
    """Trace context for the JSON logs (ADR 0011, step 6): {"trace_id", "span_id", "trace_flags"}
    of the current span, lower-case hex as in a W3C traceparent (trace_flags "01" sampled, "00"
    not), the same names in all languages. Empty while tracing is off (no SDK provider: prod
    today), so a caller's traceparent can never put IDs in our logs, and outside a valid span."""
    try:
        from opentelemetry import trace
        from opentelemetry.sdk.trace import TracerProvider
    except ImportError:  # OpenTelemetry not installed (some unit tests): no fields
        return {}
    if not isinstance(trace.get_tracer_provider(), TracerProvider):
        return {}
    sc = trace.get_current_span().get_span_context()
    if not sc.is_valid:
        return {}
    return {
        "trace_id": format(sc.trace_id, "032x"),
        "span_id": format(sc.span_id, "016x"),
        "trace_flags": "01" if sc.trace_flags.sampled else "00",
    }
