"""Tests of the message spans (messagetrace.py, ADR 0010 step 5) with OpenTelemetry installed (the
service's requirements). Tracing sets process-wide state once, so they run in a child process."""
import os
import subprocess
import sys
import textwrap
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))


def run_child(code):
    env = {k: v for k, v in os.environ.items() if not k.startswith("OTEL_")}
    result = subprocess.run([sys.executable, "-c", textwrap.dedent(code)], cwd=HERE, env=env,
                            capture_output=True, text=True, timeout=60)
    return result.returncode, result.stdout + result.stderr


CHILD_SETUP = """
    import json, logging, os
    import notifications as n
    from test_notifications import FakeDynamo, FakeLogger, FakeSqs, status_event

    PRODUCER = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
    traced = json.loads(status_event(order_id="o1", email="jane@example.com"))
    traced["detail"]["_trace"] = {"traceparent": PRODUCER}
    bodies = [json.dumps(traced), status_event(order_id="o2"), "garbage"]
"""


class MessageSpanTest(unittest.TestCase):
    def test_consumer_joins_the_trace(self):
        code, out = run_child(CHILD_SETUP + """
    from opentelemetry import trace
    from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter
    import tracing

    exporter = InMemorySpanExporter()
    provider = tracing.start_tracing("emailservice", logging.getLogger(), exporter=exporter,
                                     env={"ENABLE_TRACING": "1"})
    sqs = FakeSqs(bodies)
    results = n.Consumer(sqs, "q", n.NotificationLog(FakeDynamo(), "t"), FakeLogger()).poll_once(wait_seconds=0)
    assert results == ["sent", "sent", "invalid"], results
    provider.force_flush()
    s1, s2, s3 = exporter.get_finished_spans()
    # o1 continues the order's trace, as a child of the producer span in "_trace"
    assert s1.name == "process OrderStatusUpdated" and s1.kind == trace.SpanKind.CONSUMER
    assert format(s1.context.trace_id, "032x") == PRODUCER.split("-")[1]
    assert format(s1.parent.span_id, "016x") == PRODUCER.split("-")[2] and s1.parent.is_remote
    assert s1.attributes["boutique.order_id"] == "o1"
    # o2 (no field): a new trace; the invalid message: an error span, retried
    assert s2.parent is None and s2.context.trace_id != s1.context.trace_id
    assert s3.status.status_code == trace.StatusCode.ERROR
    # Privacy: no email address in span names or attributes
    for s in (s1, s2, s3):
        assert "@" not in s.name and not any("@" in str(v) for v in s.attributes.values()), s.attributes
    print("OK", flush=True)
    os._exit(0)
""")
        self.assertEqual(code, 0, out)

    def test_tracing_off_exports_nothing(self):
        # Prod: OpenTelemetry is installed but not started: no-op spans, messages processed as before.
        code, out = run_child(CHILD_SETUP + """
    from opentelemetry import trace
    import messagetrace

    sqs = FakeSqs(bodies)
    results = n.Consumer(sqs, "q", n.NotificationLog(FakeDynamo(), "t"), FakeLogger()).poll_once(wait_seconds=0)
    assert results == ["sent", "sent", "invalid"], results
    assert sqs.deleted == ["r0", "r1"], sqs.deleted
    with messagetrace.consumer_span("x", {"traceparent": PRODUCER}) as span:
        assert not span.is_recording()
    print("OK", flush=True)
    os._exit(0)
""")
        self.assertEqual(code, 0, out)


if __name__ == "__main__":
    unittest.main()
