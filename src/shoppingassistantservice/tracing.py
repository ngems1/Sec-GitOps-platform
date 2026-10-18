"""OpenTelemetry tracing for shoppingassistantservice (ADR 0010), started only with ENABLE_TRACING=1.

Same rules as the other Python services (service name from OTEL_SERVICE_NAME, ParentBased sampler,
W3C trace context, background batch export, exports never traced, collector down = nothing waits).

Spans:
- one SERVER span per POST /ask (the frontend's trace continues here), with the outcome
  (answered, paused -> kill_switch, rate_limited, ...) and the number of products cited;
  /healthz, /readyz and /metrics make no span;
- one CLIENT span per Bedrock Converse call ("chat <model id>"): model ID, step, input and output
  tokens, the tool names the model asked for, and the outcome (ok, rate_limited, timeout, error);
- CLIENT spans for the catalog gRPC calls (grpc client instrumentation).

NEVER in a span name, attribute or event: the question, the answer, the session ID or its hash.
The spans are built from a fixed list of typed fields (no free text), exceptions are not recorded
as events (an error message could echo the request), and botocore is not instrumented (its Bedrock
support can record message content).
"""
import contextlib
import os

_tracer = None

UNTRACED_PATHS = ("/healthz", "/readyz", "/metrics")
# assistant outcome -> span outcome: the daily cap is the kill switch
REQUEST_OUTCOMES = {"paused": "kill_switch"}


def tracing_resource(default_service_name):
    """OTEL_SERVICE_NAME / OTEL_RESOURCE_ATTRIBUTES, and the default name only when no name is set."""
    from opentelemetry.sdk.resources import SERVICE_NAME, Resource

    resource = Resource.create()
    if str(resource.attributes.get(SERVICE_NAME, "")).startswith("unknown_service"):
        resource = resource.merge(Resource({SERVICE_NAME: default_service_name}))
    return resource


def start_tracing(default_service_name, logger, exporter=None, env=os.environ):
    """Returns the TracerProvider, or None when tracing is off or could not start (logged).
    Call it before the catalog's gRPC channel is created."""
    global _tracer
    if env.get("ENABLE_TRACING") != "1":
        logger.info("Tracing disabled.")
        return None
    try:
        from opentelemetry import trace
        from opentelemetry.baggage.propagation import W3CBaggagePropagator
        from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
        from opentelemetry.instrumentation.grpc import GrpcInstrumentorClient
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
        GrpcInstrumentorClient().instrument()
        _tracer = trace.get_tracer("shoppingassistantservice")
    except Exception as err:  # tracing must never stop the service from starting
        logger.warning(f"Tracing could not start, continuing without it: {err}")
        return None
    logger.info("Tracing enabled.")
    return provider


@contextlib.contextmanager
def server_span(method, route, path, headers):
    """SERVER span for one request, continuing the caller's W3C trace (only traceparent and baggage
    are read from the headers). Yields a recorder, or None for probes and when tracing is off."""
    if _tracer is None or path in UNTRACED_PATHS:
        yield None
        return
    from opentelemetry import propagate, trace

    carrier = {k.lower(): v for k, v in headers.items() if k.lower() in ("traceparent", "tracestate", "baggage")}
    with _tracer.start_as_current_span(f"{method} {route}", context=propagate.extract(carrier),
                                       kind=trace.SpanKind.SERVER, record_exception=False,
                                       attributes={"http.method": method, "http.route": route}) as span:
        yield _Request(span)


class _Request:
    def __init__(self, span):
        self.span = span

    def record(self, status_code, outcome=None, products=None):
        from opentelemetry.trace import Status, StatusCode

        self.span.set_attribute("http.status_code", int(status_code))
        if outcome:
            self.span.set_attribute("assistant.outcome", REQUEST_OUTCOMES.get(outcome, str(outcome)))
        if products is not None:
            self.span.set_attribute("assistant.products", int(products))
        if int(status_code) >= 500:
            self.span.set_status(Status(StatusCode.ERROR))


class OtelSpans:
    """assistant.Assistant's span hook (assistant.NoSpans when tracing is off)."""

    @contextlib.contextmanager
    def model_call(self, model_id, step):
        if _tracer is None:
            from assistant import NoSpans

            with NoSpans().model_call(model_id, step) as call:
                yield call
            return
        from opentelemetry import trace

        with _tracer.start_as_current_span(f"chat {model_id}", kind=trace.SpanKind.CLIENT, record_exception=False,
                                           set_status_on_exception=False,
                                           attributes={"gen_ai.system": "aws.bedrock",
                                                       "gen_ai.operation.name": "chat",
                                                       "gen_ai.request.model": str(model_id),
                                                       "assistant.step": int(step)}) as span:
            call = _ModelCall(span)
            try:
                yield call
            except BaseException:
                if not call.recorded:
                    call.record(outcome="error")
                raise


class _ModelCall:
    def __init__(self, span):
        self.span = span
        self.recorded = False

    def record(self, input_tokens=0, output_tokens=0, tools=(), outcome="ok"):
        from opentelemetry.trace import Status, StatusCode

        self.recorded = True
        self.span.set_attribute("gen_ai.usage.input_tokens", int(input_tokens or 0))
        self.span.set_attribute("gen_ai.usage.output_tokens", int(output_tokens or 0))
        self.span.set_attribute("assistant.tools", [str(t) for t in tools])
        self.span.set_attribute("assistant.outcome", str(outcome))
        if outcome != "ok":
            self.span.set_status(Status(StatusCode.ERROR))

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
