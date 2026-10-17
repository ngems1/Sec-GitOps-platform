"""Tests of tracing.py (ADR 0010). They need requirements.txt (opentelemetry, boto3). Tracing sets
process-wide state once, so the tests that start it run in a child process. AWS calls are stubbed
(botocore Stubber): no network, no credentials."""
import json
import logging
import os
import subprocess
import sys
import textwrap
import unittest

import tracing

HERE = os.path.dirname(os.path.abspath(__file__))
PRODUCER = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"


class FakeSqs:
    """One receive with the given bodies, then stops the consumer loop."""

    def __init__(self, server, bodies):
        self.server, self.bodies, self.deleted = server, bodies, []

    def receive_message(self, **_):
        if self.bodies is None:
            self.server.stop.set()
            return {}
        msgs = [{"Body": b, "ReceiptHandle": f"r{i}"} for i, b in enumerate(self.bodies)]
        self.bodies = None
        return {"Messages": msgs}

    def delete_message(self, QueueUrl, ReceiptHandle):
        self.deleted.append(ReceiptHandle)


def order_body(order_id, trace=None):
    detail = {"version": "1", "orderId": order_id, "email": "jane@example.com",
              "items": [{"productId": "OLJCESPC7Z", "quantity": 1}]}
    if trace is not None:
        detail["_trace"] = trace
    return json.dumps({"detail-type": "OrderCreated", "source": "boutique.checkout", "detail": detail})


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
        with tracing.producer_span("publish InventoryReserved", "bus", "o1") as span:
            self.assertIsNone(span)
        self.assertEqual(tracing.with_trace({"orderId": "o1"}), {"orderId": "o1"})  # prod: no field added


class TraceFieldTest(unittest.TestCase):
    def test_take_trace_strips_the_field(self):
        body, carrier = tracing.take_trace(order_body("o1", {"traceparent": PRODUCER, "tracestate": "k=v",
                                                              "baggage": "session=s1"}))
        self.assertEqual(carrier, {"traceparent": PRODUCER, "tracestate": "k=v"})
        self.assertNotIn("_trace", json.loads(body)["detail"])
        self.assertEqual(json.loads(body), json.loads(order_body("o1")))

    def test_events_without_or_with_a_bad_field(self):
        old = order_body("o1")
        self.assertEqual(tracing.take_trace(old), (old, {}))  # byte for byte
        self.assertEqual(tracing.take_trace("not json"), ("not json", {}))
        for bad in ("x", {"traceparent": 5}, {"traceparent": "0" * 600}):
            body, carrier = tracing.take_trace(order_body("o1", bad))
            self.assertEqual((json.loads(body), carrier), (json.loads(old), {}))

    def test_consumer_tracing_off(self):
        # Prod: the field is stripped before parsing, the message is processed and deleted, and
        # the result event gets no field.
        import server
        from test_inventory import FakeDynamo, FakeEvents

        import inventory as inv
        store = inv.InventoryStore(FakeDynamo(), "t")
        store.seed({"OLJCESPC7Z": 5})
        events, sqs = FakeEvents(), FakeSqs(server, [order_body("o1", {"traceparent": PRODUCER}), order_body("o2")])
        server.stop.clear()
        server.consume(store, sqs, events)
        self.assertEqual(sqs.deleted, ["r0", "r1"])
        self.assertEqual([json.loads(e["Detail"]) for e in events.sent],
                         [{"version": "1", "orderId": o, "items": [{"productId": "OLJCESPC7Z", "quantity": 1}]}
                          for o in ("o1", "o2")])


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

    def test_consumer_joins_the_trace_and_passes_it_on(self):
        code, out = run_child("""
            import json, logging, os
            from opentelemetry import trace
            from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter
            import inventory as inv, server, tracing
            from test_inventory import FakeDynamo, FakeEvents
            from test_tracing import PRODUCER, FakeSqs, order_body

            exporter = InMemorySpanExporter()
            provider = tracing.start_tracing("inventoryservice", logging.getLogger(), exporter=exporter,
                                             env={"ENABLE_TRACING": "1"})
            store = inv.InventoryStore(FakeDynamo(), "t")
            store.seed({"OLJCESPC7Z": 1})
            events = FakeEvents()
            sqs = FakeSqs(server, [order_body("o1", {"traceparent": PRODUCER}), order_body("o2")])
            server.consume(store, sqs, events)
            assert sqs.deleted == ["r0", "r1"], sqs.deleted
            provider.force_flush()
            spans = exporter.get_finished_spans()
            consumers = [s for s in spans if s.name == "process OrderCreated"]
            producers = {s.attributes["boutique.order_id"]: s for s in spans if s.kind == trace.SpanKind.PRODUCER}
            # o1 continues checkout's trace, as a child of its PRODUCER span; o2 (no field) a new trace
            c1, c2 = consumers
            assert format(c1.context.trace_id, "032x") == PRODUCER.split("-")[1]
            assert format(c1.parent.span_id, "016x") == PRODUCER.split("-")[2] and c1.parent.is_remote
            assert c1.kind == trace.SpanKind.CONSUMER and c1.attributes["boutique.order_id"] == "o1"
            assert c2.parent is None and c2.context.trace_id != c1.context.trace_id
            # The result events carry the inventory PRODUCER span's context
            assert producers["o1"].name == "publish InventoryReserved" and producers["o2"].name == "publish InventoryFailed"
            for entry, oid in zip(events.sent, ("o1", "o2")):
                p = producers[oid]
                tp = json.loads(entry["Detail"])["_trace"]["traceparent"]
                assert tp == f"00-{p.context.trace_id:032x}-{p.context.span_id:016x}-01", tp
                assert p.parent.span_id == (c1 if oid == "o1" else c2).context.span_id
            # Privacy: the event had an email address; no span name or attribute has it
            for s in spans:
                assert "jane" not in s.name and not any("jane" in str(v) for v in s.attributes.values()), s.name
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
