"""Tests of tracing.py with real OpenTelemetry (ADR 0010). They need requirements.txt. Tracing sets
process-wide state once, so they run in a child process."""
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


class TracingTest(unittest.TestCase):
    def test_spans_never_carry_question_answer_or_session(self):
        code, out = run_child("""
            import logging, os
            from opentelemetry import trace
            from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter
            import assistant as core, bedrock, tracing
            from test_assistant import FakeCatalog, FakeModel, FakeMetrics, final, tool_use

            exporter = InMemorySpanExporter()
            provider = tracing.start_tracing("shoppingassistantservice", logging.getLogger(), exporter=exporter,
                                             env={"ENABLE_TRACING": "1"})
            assert provider is not None
            QUESTION, SESSION, ANSWER = "SECRET-QUESTION-42 a mug?", "SECRET-SESSION-7", "SECRET-ANSWER-99 the Mug [6E92ZMYYFZ]."
            model = FakeModel(tool_use("search_products", {"query": "mug"}), final(ANSWER),
                              bedrock.BedrockError("throttled", "Too many requests for SECRET-QUESTION-42"))
            model.model_id = "amazon.nova-lite-v1:0"
            bot = core.Assistant(model, FakeCatalog(), metrics=FakeMetrics(), spans=tracing.OtelSpans(), daily_question_cap=2)
            headers = {"traceparent": "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
                       "X-Session-Id": SESSION, "Content-Type": "application/json"}
            for expected in ("answered", "error", "paused"):
                with tracing.server_span("POST", "/ask", "/ask", headers) as req:
                    result = bot.ask(QUESTION, "EUR", SESSION)
                    assert result["outcome"] == expected, (result["outcome"], expected)
                    req.record(200 if expected != "error" else 502, result["outcome"], len(result["products"]))
            with tracing.server_span("GET", "/healthz", "/healthz", {}) as req:
                assert req is None
            provider.force_flush()
            spans = exporter.get_finished_spans()

            # Nothing secret anywhere: names, attributes, events, resource.
            dump = repr([(s.name, dict(s.attributes or {}), [(e.name, dict(e.attributes or {})) for e in s.events],
                          dict(s.resource.attributes)) for s in spans])
            for secret in ("SECRET-QUESTION", "SECRET-SESSION", "SECRET-ANSWER", core.session_key(SESSION),
                           __import__("hashlib").sha256(SESSION.encode()).hexdigest()):
                assert secret not in dump, f"{secret} found in spans"

            names = [s.name for s in spans]
            assert names.count("POST /ask") == 3, names
            assert names.count("chat amazon.nova-lite-v1:0") == 3, names  # 2 for the answer, 1 throttled
            chats = [s for s in spans if s.name.startswith("chat ")]
            ok = [dict(s.attributes) for s in chats if s.attributes["assistant.outcome"] == "ok"]
            assert ok[0]["assistant.step"] == 0 and ok[0]["assistant.tools"] == ("search_products",), ok[0]
            assert ok[0]["gen_ai.usage.input_tokens"] == 100 and ok[0]["gen_ai.usage.output_tokens"] == 10
            assert ok[0]["gen_ai.request.model"] == "amazon.nova-lite-v1:0" and ok[0]["gen_ai.system"] == "aws.bedrock"
            throttled = [s for s in chats if s.attributes["assistant.outcome"] == "rate_limited"]
            assert len(throttled) == 1 and throttled[0].status.status_code.name == "ERROR" and not throttled[0].events
            requests = [dict(s.attributes) for s in spans if s.name == "POST /ask"]
            assert [r["assistant.outcome"] for r in requests] == ["answered", "error", "kill_switch"], requests
            # the frontend's trace continues here; the model calls are children of the request
            req0 = [s for s in spans if s.name == "POST /ask"][0]
            assert format(req0.context.trace_id, "032x") == "0af7651916cd43dd8448eb211c80319c"
            assert all(c.context.trace_id in {s.context.trace_id for s in spans if s.name == "POST /ask"} for c in chats)
            print("OK", flush=True)
            os._exit(0)
        """)
        self.assertEqual(code, 0, out)

    def test_collector_unreachable_never_waits(self):
        code, out = run_child("""
            import logging, os, time
            import tracing
            try:
                assert tracing.start_tracing("shoppingassistantservice", logging.getLogger(),
                                             env={"ENABLE_TRACING": "1", "COLLECTOR_SERVICE_ADDR": "127.0.0.1:1"})
                spans = tracing.OtelSpans()
                start = time.time()
                for i in range(200):
                    with tracing.server_span("POST", "/ask", "/ask", {}) as req:
                        with spans.model_call("m", 0) as call:
                            call.record(input_tokens=1, output_tokens=1, tools=[], outcome="ok")
                        req.record(200, "answered", 0)
                took = time.time() - start
                assert took < 1, f"200 requests took {took:.2f} s"
                time.sleep(6)  # one background export fails meanwhile
                print("OK", flush=True)
            except BaseException as err:
                print("FAIL", repr(err), flush=True)
                os._exit(1)
            os._exit(0)  # skip the exit-time flush to the closed port
        """)
        self.assertEqual(code, 0, out)


if __name__ == "__main__":
    unittest.main()
