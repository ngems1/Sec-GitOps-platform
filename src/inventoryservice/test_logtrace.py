"""Tests of log_trace_fields (tracing.py, ADR 0011): trace_id / span_id / trace_flags in the JSON log
lines. The same file in emailservice, recommendationservice, shoppingassistantservice and
inventoryservice; it uses the service's own formatter (logger.py, or server.py's JsonFormatter).
Needs the service's requirements (OpenTelemetry). Tracing sets process-wide state once, so each
case runs in a child process (and leaves with os._exit: no final export to a closed port)."""
import os
import subprocess
import sys
import textwrap
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SERVICE = os.path.basename(HERE)

SETUP = """
import io, json, logging, os, sys, types
sys.modules.setdefault("googlecloudprofiler", types.ModuleType("googlecloudprofiler"))
from opentelemetry import context, trace
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter
from opentelemetry.trace import NonRecordingSpan, SpanContext, TraceFlags
import tracing

buf = io.StringIO()
if os.path.exists("logger.py"):          # emailservice, recommendationservice
    from logger import getJSONLogger
    logger = getJSONLogger("logtrace-test")
    logger.handlers[-1].stream = buf
else:                                    # shoppingassistantservice, inventoryservice
    import server
    logger = logging.getLogger("logtrace-test")
    handler = logging.StreamHandler(buf)
    handler.setFormatter(server.JsonFormatter())
    logger.addHandler(handler)
    logger.setLevel(logging.INFO)
    logger.propagate = False

def lines():
    out = [json.loads(l) for l in buf.getvalue().splitlines() if l.strip()]
    buf.seek(0); buf.truncate()
    return out

def no_trace_fields(line):
    return not any(k in line for k in ("trace_id", "span_id", "trace_flags"))

# A caller's context: the traceparent 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-<flags>
def caller(flags):
    sc = SpanContext(trace_id=0x4bf92f3577b34da6a3ce929d0e0e4736, span_id=0x00f067aa0ba902b7,
                     is_remote=True, trace_flags=TraceFlags(flags))
    return trace.set_span_in_context(NonRecordingSpan(sc))
"""


def run_child(code):
    env = {k: v for k, v in os.environ.items() if not k.startswith("OTEL_")}
    result = subprocess.run([sys.executable, "-c", textwrap.dedent(SETUP) + textwrap.dedent(code)],
                            cwd=HERE, env=env, capture_output=True, text=True, timeout=60)
    return result.returncode, result.stdout + result.stderr


class LogTraceFieldsTest(unittest.TestCase):
    def test_ids_inside_a_span_none_outside(self):
        code, out = run_child("""
            assert tracing.start_tracing(SERVICE_NAME, logging.getLogger("t"), exporter=InMemorySpanExporter(),
                                         env={"ENABLE_TRACING": "1"}) is not None
            tracer = trace.get_tracer("test")
            with tracer.start_as_current_span("request") as span:
                # extra keys (python-json-logger) and "fields" (server.py JsonFormatter)
                logger.info("inside", extra={"orderId": "o-1", "fields": {"orderId": "o-1"}})
            sc = span.get_span_context()
            logger.info("outside")
            inside, outside = lines()
            assert inside["trace_id"] == format(sc.trace_id, "032x"), inside
            assert inside["span_id"] == format(sc.span_id, "016x"), inside
            assert inside["trace_flags"] == "01", inside
            assert len(inside["trace_id"]) == 32 and inside["trace_id"] == inside["trace_id"].lower()
            assert inside["orderId"] == "o-1", inside              # the existing fields stay
            assert "inside" in json.dumps(inside), inside
            assert no_trace_fields(outside), outside
            # an unsampled caller (flags 00): the span is valid but not sampled
            with tracer.start_as_current_span("child", context=caller(0)) as child:
                logger.info("unsampled")
            [unsampled] = lines()
            assert unsampled["trace_flags"] == "00", unsampled
            assert unsampled["span_id"] == format(child.get_span_context().span_id, "016x"), unsampled
            assert unsampled["trace_id"] == "4bf92f3577b34da6a3ce929d0e0e4736", unsampled
            print("OK", flush=True)
            os._exit(0)
        """.replace("SERVICE_NAME", repr(SERVICE)))
        self.assertEqual(code, 0, out)

    def test_tracing_off_no_fields_even_with_a_caller_traceparent(self):
        code, out = run_child("""
            assert tracing.start_tracing(SERVICE_NAME, logging.getLogger("t"), env={}) is None
            token = context.attach(caller(1))
            assert trace.get_current_span().get_span_context().is_valid  # the case covered
            logger.info("tracing off")
            context.detach(token)
            [line] = lines()
            assert no_trace_fields(line), line
            print("OK", flush=True)
            os._exit(0)
        """.replace("SERVICE_NAME", repr(SERVICE)))
        self.assertEqual(code, 0, out)


if __name__ == "__main__":
    unittest.main()
