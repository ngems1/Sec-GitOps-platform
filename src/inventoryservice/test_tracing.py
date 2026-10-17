"""Tests of tracing.py (ADR 0010). They need requirements.txt (opentelemetry, boto3). Tracing sets
process-wide state once, so the tests that start it run in a child process. AWS calls are stubbed
(botocore Stubber): no network, no credentials."""
import logging
import os
import subprocess
import sys
import textwrap
import unittest

import tracing

HERE = os.path.dirname(os.path.abspath(__file__))


def run_child(code):
    env = {k: v for k, v in os.environ.items() if not k.startswith("OTEL_")}
    result = subprocess.run([sys.executable, "-c", textwrap.dedent(code)], cwd=HERE, env=env,
                            capture_output=True, text=True, timeout=60)
    return result.returncode, result.stdout + result.stderr


class ResourceTest(unittest.TestCase):
    def tearDown(self):
        for k in ("OTEL_SERVICE_NAME", "OTEL_RESOURCE_ATTRIBUTES"):
            os.environ.pop(k, None)

    def test_off_unless_enable_tracing_is_1(self):
        self.assertIsNone(tracing.start_tracing("inventoryservice", logging.getLogger(), env={}))

    def test_service_name_from_env_and_default(self):
        os.environ["OTEL_SERVICE_NAME"] = "inventory-from-env"
        self.assertEqual(tracing.tracing_resource("inventoryservice").attributes["service.name"], "inventory-from-env")
        del os.environ["OTEL_SERVICE_NAME"]
        self.assertEqual(tracing.tracing_resource("inventoryservice").attributes["service.name"], "inventoryservice")

    def test_off_helpers_do_nothing(self):
        with tracing.server_span("GET", "/stock", "/stock", {}) as span:
            self.assertIsNone(span)
        with tracing.consumer_span("x") as span:
            self.assertIsNone(span)
        with tracing.quiet():
            pass


class TracingProcessTest(unittest.TestCase):
    def test_spans(self):
        code, out = run_child("""
            import logging, os
            import boto3
            from botocore.stub import Stubber
            from opentelemetry import trace
            from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter
            import tracing

            exporter = InMemorySpanExporter()
            provider = tracing.start_tracing("inventoryservice", logging.getLogger(), exporter=exporter,
                                             env={"ENABLE_TRACING": "1"})
            assert provider is not None
            caller = "0af7651916cd43dd8448eb211c80319c"
            # API: named after the route, continues the caller's trace; probes make no span
            with tracing.server_span("GET", "/stock/{productId}", "/stock/OLJCESPC7Z",
                                     {"traceparent": f"00-{caller}-b7ad6b7169203331-01"}) as span:
                tracing.set_status_code(span, 200)
            for probe in ("/healthz", "/readyz", "/metrics"):
                with tracing.server_span("GET", probe, probe, {}) as span:
                    assert span is None
            # A message: one consumer span, its DynamoDB call as a child
            kw = dict(region_name="us-east-1", aws_access_key_id="x", aws_secret_access_key="y")
            ddb = boto3.client("dynamodb", **kw)
            with Stubber(ddb) as stub:
                stub.add_response("get_item", {"Item": {"productId": {"S": "OLJCESPC7Z"}}})
                with tracing.consumer_span("process OrderCreated", {"messaging.system": "aws_sqs"}):
                    ddb.get_item(TableName="inventory", Key={"productId": {"S": "OLJCESPC7Z"}})
            # The long poll: no span
            sqs = boto3.client("sqs", **kw)
            with Stubber(sqs) as stub:
                stub.add_response("receive_message", {"Messages": []})
                with tracing.quiet():
                    sqs.receive_message(QueueUrl="https://sqs.us-east-1.amazonaws.com/1/q", WaitTimeSeconds=20)
            provider.force_flush()
            spans = {s.name: s for s in exporter.get_finished_spans()}
            assert set(spans) == {"GET /stock/{productId}", "process OrderCreated", "DynamoDB.GetItem"}, sorted(spans)
            api = spans["GET /stock/{productId}"]
            assert format(api.context.trace_id, "032x") == caller and api.kind == trace.SpanKind.SERVER
            assert api.attributes["http.status_code"] == 200
            assert "OLJCESPC7Z" not in api.name
            assert spans["DynamoDB.GetItem"].parent.span_id == spans["process OrderCreated"].context.span_id
            assert spans["process OrderCreated"].kind == trace.SpanKind.CONSUMER
            assert api.resource.attributes["service.name"] == "inventoryservice"
            print("OK", flush=True)
            os._exit(0)
        """)
        self.assertEqual(code, 0, out)

    def test_collector_unreachable_never_waits(self):
        code, out = run_child("""
            import logging, os, time
            import tracing
            # os._exit: a normal exit runs the SDK's final flush, which retries the closed port.
            try:
                assert tracing.start_tracing("inventoryservice", logging.getLogger(),
                                             env={"ENABLE_TRACING": "1", "COLLECTOR_SERVICE_ADDR": "127.0.0.1:1"})
                start = time.time()
                for i in range(200):
                    with tracing.server_span("GET", "/stock", "/stock", {}) as span:
                        tracing.set_status_code(span, 200)
                took = time.time() - start
                assert took < 1, f"200 requests took {took:.2f} s"
                time.sleep(6)  # one background export fails meanwhile
                print("OK", flush=True)
            except BaseException as err:
                print("FAIL", repr(err), flush=True)
                os._exit(1)
            os._exit(0)
        """)
        self.assertEqual(code, 0, out)


if __name__ == "__main__":
    unittest.main()
