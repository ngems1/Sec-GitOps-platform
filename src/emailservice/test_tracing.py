"""Tests of tracing.py (ADR 0010). Same file in recommendationservice and emailservice. They need
the service's requirements (opentelemetry, grpcio, grpcio-health-checking). Tracing sets
process-wide state once, so the tests that start it run in a child process."""
import logging
import os
import subprocess
import sys
import textwrap
import unittest

import tracing

HERE = os.path.dirname(os.path.abspath(__file__))
SERVICE = os.path.basename(HERE)
LOG = logging.getLogger("test")


def run_child(code, extra_env=None):
    env = {k: v for k, v in os.environ.items() if not k.startswith("OTEL_")}
    env.update(extra_env or {})
    result = subprocess.run([sys.executable, "-c", textwrap.dedent(code)], cwd=HERE, env=env,
                            capture_output=True, text=True, timeout=60)
    return result.returncode, result.stdout + result.stderr


class ResourceTest(unittest.TestCase):
    def setUp(self):
        self.saved = {k: os.environ.pop(k) for k in ("OTEL_SERVICE_NAME", "OTEL_RESOURCE_ATTRIBUTES") if k in os.environ}

    def tearDown(self):
        for k in ("OTEL_SERVICE_NAME", "OTEL_RESOURCE_ATTRIBUTES"):
            os.environ.pop(k, None)
        os.environ.update(self.saved)

    def test_off_unless_enable_tracing_is_1(self):
        self.assertIsNone(tracing.start_tracing(SERVICE, LOG, env={}))
        self.assertIsNone(tracing.start_tracing(SERVICE, LOG, env={"ENABLE_TRACING": "0"}))

    def test_service_name_and_attributes_from_env(self):
        os.environ["OTEL_SERVICE_NAME"] = SERVICE + "-from-env"
        os.environ["OTEL_RESOURCE_ATTRIBUTES"] = "deployment.environment=dev,service.namespace=boutique"
        attrs = tracing.tracing_resource(SERVICE).attributes
        self.assertEqual(attrs["service.name"], SERVICE + "-from-env")
        self.assertEqual(attrs["deployment.environment"], "dev")
        self.assertEqual(attrs["service.namespace"], "boutique")

    def test_default_service_name(self):
        self.assertEqual(tracing.tracing_resource(SERVICE).attributes["service.name"], SERVICE)


class TracingProcessTest(unittest.TestCase):
    def test_grpc_server_spans_parent_based_w3c(self):
        code, out = run_child("""
            import logging, os
            from concurrent import futures
            import grpc
            from grpc_health.v1 import health, health_pb2, health_pb2_grpc
            from opentelemetry import trace
            from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter
            import tracing

            exporter = InMemorySpanExporter()
            provider = tracing.start_tracing("svc", logging.getLogger(), exporter=exporter,
                                             env={"ENABLE_TRACING": "1"})
            assert provider is not None
            assert provider.sampler.get_description().startswith("ParentBased"), provider.sampler.get_description()

            server = grpc.server(futures.ThreadPoolExecutor(max_workers=2))
            health_pb2_grpc.add_HealthServicer_to_server(health.HealthServicer(), server)
            port = server.add_insecure_port("127.0.0.1:0")
            server.start()
            stub = health_pb2_grpc.HealthStub(grpc.insecure_channel(f"127.0.0.1:{port}"))
            caller = "0af7651916cd43dd8448eb211c80319c"
            stub.Check(health_pb2.HealthCheckRequest(), timeout=5,
                       metadata=[("traceparent", f"00-{caller}-b7ad6b7169203331-01")])
            # An unsampled caller: the server span follows it and is not exported.
            stub.Check(health_pb2.HealthCheckRequest(), timeout=5,
                       metadata=[("traceparent", "00-1af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-00")])
            provider.force_flush()
            spans = [s for s in exporter.get_finished_spans() if s.kind == trace.SpanKind.SERVER]
            assert [s.name for s in spans] == ["/grpc.health.v1.Health/Check"], [s.name for s in spans]
            assert format(spans[0].context.trace_id, "032x") == caller
            assert spans[0].resource.attributes["service.name"] == "svc"
            print("OK", flush=True)
            os._exit(0)
        """)
        self.assertEqual(code, 0, out)

    def test_collector_unreachable_never_waits(self):
        code, out = run_child("""
            import logging, os, time
            from opentelemetry import trace
            import tracing

            # Always leave with os._exit: a normal exit runs the SDK's final flush, which retries the
            # closed port for about a minute (the services stop on SIGTERM, without that flush).
            try:
                provider = tracing.start_tracing("svc", logging.getLogger(),
                                                 env={"ENABLE_TRACING": "1", "COLLECTOR_SERVICE_ADDR": "127.0.0.1:1"})
                assert provider is not None
                tracer = trace.get_tracer("test")
                start = time.time()
                for i in range(200):
                    tracer.start_span(f"request {i}").end()
                took = time.time() - start
                assert took < 1, f"200 spans took {took:.2f} s"
                time.sleep(6)  # one background export (every 5 s) fails meanwhile
                print("OK")
            except BaseException as err:
                print("FAIL", repr(err), flush=True)
                os._exit(1)
            os._exit(0)
        """)
        self.assertEqual(code, 0, out)


if __name__ == "__main__":
    unittest.main()
