"""Tests of the HTTP server (server.py) with Bedrock down: the pod stays Ready, and a question gets a
clear error answer (HTTP 502), quickly. A fake Bedrock and a fake catalog: no AWS, no network."""
import json
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

import assistant as core
import bedrock
import metrics as m
import server
from test_assistant import FakeCatalog


class DownModel:
    """Bedrock unavailable: every Converse call fails, like an outage or throttling."""

    def __init__(self):
        self.calls = 0

    def converse(self, request):
        self.calls += 1
        raise bedrock.BedrockError("throttled", "Rate exceeded")


class ServerWithBedrockDownTest(unittest.TestCase):
    def setUp(self):
        self.model = DownModel()
        self.bot = core.Assistant(self.model, FakeCatalog(), metrics=m.PrometheusMetrics(), spans=None,
                                  **server.SETTINGS)
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), server.make_handler(self.bot))
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.httpd.server_address[1]}"
        self.stop = threading.Event()

    def tearDown(self):
        self.stop.set()
        server.stopping.clear()
        self.httpd.shutdown()
        self.httpd.server_close()

    def get(self, path):
        try:
            with urllib.request.urlopen(self.base + path, timeout=5) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as err:
            return err.code, json.loads(err.read())

    def ask(self, question):
        req = urllib.request.Request(self.base + "/ask", data=json.dumps({"question": question}).encode(),
                                     headers={"Content-Type": "application/json", "X-Session-Id": "s1"})
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as err:
            return err.code, json.loads(err.read())

    def test_ready_and_live_while_bedrock_is_down(self):
        # The startup check keeps failing (it retries in the background) ...
        threading.Thread(target=server.check_bedrock, args=(self.bot, self.stop), daemon=True).start()
        deadline = time.monotonic() + 5
        while self.model.calls == 0 and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertGreaterEqual(self.model.calls, 1, "the Bedrock check should have run")
        # ... and the pod is still Ready and live: readiness never depends on Bedrock.
        self.assertEqual(self.get("/readyz"), (200, {"ready": True}))
        self.assertEqual(self.get("/healthz"), (200, {"status": "ok"}))

    def test_question_gets_a_clear_error_quickly(self):
        start = time.monotonic()
        code, body = self.ask("What is the cheapest item?")
        self.assertLess(time.monotonic() - start, 3)
        self.assertEqual(code, 502)
        self.assertEqual(body["outcome"], "error")
        self.assertEqual(body["answer"], core.ERROR_ANSWER)
        self.assertNotIn("error", body)  # the error detail stays in the server log
        self.assertNotIn("Rate exceeded", json.dumps(body))

    def test_not_ready_once_shutting_down(self):
        server.stopping.set()
        self.assertEqual(self.get("/readyz"), (503, {"ready": False}))
        self.assertEqual(self.get("/healthz"), (200, {"status": "ok"}))

    def test_shutdown_waits_for_questions_in_flight(self):
        self.assertTrue(server.wait_for_inflight(0.1))  # idle: nothing to wait for
        with server.inflight_lock:
            server.inflight_count[0] += 1
        self.assertFalse(server.wait_for_inflight(0.1))  # a question still running

        def finish():
            time.sleep(0.2)
            with server.inflight_lock:
                server.inflight_count[0] -= 1
                server.inflight_lock.notify_all()
        threading.Thread(target=finish).start()
        self.assertTrue(server.wait_for_inflight(2))


if __name__ == "__main__":
    unittest.main()
