"""shoppingassistantservice: the AI shopping assistant's HTTP API (ADR 0009).

  POST /ask      {"question": "...", "currency": "EUR"} -> {"outcome", "answer", "products"}
  GET  /healthz  liveness
  GET  /readyz   readiness: 200 only after a one-token Bedrock Converse call succeeded
  GET  /metrics  Prometheus metrics

The frontend calls /ask and sends its session ID in the X-Session-Id header: it is only
the rate-limit key (hashed), never logged and never sent to the model. The question text
is never logged either; the logs keep the outcome, the duration and the error type.
AWS credentials come from EKS Pod Identity (no keys in the pod).
"""
import json
import logging
import os
import signal
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from prometheus_client import CONTENT_TYPE_LATEST, generate_latest

import assistant as core
import bedrock
import metrics as m
import tracing

# ------------------------------------------------------------------ config
PORT = int(os.environ.get("PORT", "8080"))
REGION = os.environ.get("AWS_REGION", "us-east-1")
MODEL_ID = bedrock.model_id(os.environ.get("BEDROCK_MODEL_ID", "amazon.nova-lite-v1:0"),
                            os.environ.get("BEDROCK_USE_INFERENCE_PROFILE", "false").lower() == "true")
CATALOG_ADDR = os.environ.get("PRODUCT_CATALOG_SERVICE_ADDR", "")
TIMEOUT = float(os.environ.get("REQUEST_TIMEOUT_SECONDS", "15"))
SETTINGS = {
    "max_tokens": int(os.environ.get("MAX_TOKENS", "600")),
    "temperature": float(os.environ.get("TEMPERATURE", "0.2")),
    "max_question_chars": int(os.environ.get("MAX_QUESTION_CHARS", "500")),
    "max_tool_steps": int(os.environ.get("MAX_TOOL_STEPS", "3")),
    "rate_per_minute": float(os.environ.get("RATE_PER_MINUTE", "10")),
    "daily_question_cap": int(os.environ.get("DAILY_QUESTION_CAP", "300")),
    "max_concurrent_calls": int(os.environ.get("MAX_CONCURRENT_CALLS", "2")),
    "deadline_seconds": TIMEOUT,
}
MAX_BODY_BYTES = 4096
READY_RETRY_SECONDS = 60

# HTTP status per outcome; the body always carries a short answer the page can show
STATUS = {"rate_limited": 429, "busy": 503, "error": 502}


# ------------------------------------------------------------------ logging (JSON lines)
class JsonFormatter(logging.Formatter):
    def format(self, record):
        out = {"ts": self.formatTime(record), "level": record.levelname, "msg": record.getMessage(),
               "service": "shoppingassistantservice"}
        out.update(tracing.log_trace_fields())  # trace_id, span_id, trace_flags (ADR 0011)
        out.update(getattr(record, "fields", {}))
        if record.exc_info:
            out["error"] = self.formatException(record.exc_info)
        return json.dumps(out)


handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(JsonFormatter())
log = logging.getLogger("assistant")
log.addHandler(handler)
log.setLevel(logging.INFO)


def info(msg, **fields):
    log.info(msg, extra={"fields": fields})


def warn(msg, **fields):
    log.warning(msg, extra={"fields": fields})


# ------------------------------------------------------------------ readiness
ready = threading.Event()


def check_bedrock(bot, stop):
    """One-token Converse call at startup, retried every minute until it works: the pod
    becomes Ready only when the role, the model ID and the network to Bedrock all work."""
    while not stop.is_set():
        try:
            bot.ping()
            ready.set()
            m.READY.set(1)
            info("bedrock check passed", model=MODEL_ID)
            return
        except Exception as err:  # noqa: BLE001
            warn("bedrock check failed, retrying", model=MODEL_ID,
                 errorType=getattr(err, "kind", "other"), error=str(err)[:300])
            stop.wait(READY_RETRY_SECONDS)


# ------------------------------------------------------------------ HTTP
def make_handler(bot):
    class Handler(BaseHTTPRequestHandler):
        def _send(self, code, body, ctype="application/json"):
            data = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode()
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):  # noqa: N802
            path = self.path.split("?")[0].rstrip("/")
            if path == "/healthz":
                return self._send(200, {"status": "ok"})
            if path == "/readyz":
                return self._send(200 if ready.is_set() else 503, {"ready": ready.is_set()})
            if path == "/metrics":
                return self._send(200, generate_latest(), CONTENT_TYPE_LATEST)
            return self._send(404, {"error": "not found"})

        def do_POST(self):  # noqa: N802
            if self.path.split("?")[0].rstrip("/") != "/ask":
                return self._send(404, {"error": "not found"})
            # One span per question (tracing.py): status, outcome and product count only, never the
            # question, the answer or the session.
            with tracing.server_span("POST", "/ask", "/ask", self.headers) as span:
                code, outcome, products = self._ask()
                if span is not None:
                    span.record(code, outcome, products)

        def _ask(self):
            """Answers one POST /ask; returns (status code, outcome, number of products)."""
            start = time.monotonic()
            try:
                length = int(self.headers.get("Content-Length") or 0)
                if length <= 0 or length > MAX_BODY_BYTES:
                    raise core.QuestionError("the body must be a JSON object of at most 4 KB")
                body = json.loads(self.rfile.read(length))
                if not isinstance(body, dict) or not isinstance(body.get("question"), str):
                    raise core.QuestionError('the body must be {"question": "...", "currency": "USD"}')
                session = self.headers.get("X-Session-Id") or self.client_address[0]
                result = bot.ask(body["question"], str(body.get("currency") or "USD"), session)
            except (core.QuestionError, ValueError) as err:
                m.REQUESTS.labels("bad_request").inc()
                self._send(400, {"outcome": "bad_request", "error": str(err)})
                return 400, "bad_request", 0
            finally:
                m.DURATION.observe(time.monotonic() - start)
                m.DAILY_USED.set(bot.daily.used)
            fields = {"outcome": result["outcome"], "products": len(result["products"]),
                      "durationMs": int((time.monotonic() - start) * 1000)}
            if "error" in result:
                fields["error"] = result.pop("error")
            info("question answered", **fields)
            code = STATUS.get(result["outcome"], 200)
            self._send(code, result)
            return code, result["outcome"], len(result["products"])

        def log_message(self, *args):  # silence default access log (probes are noisy)
            pass

    return Handler


def main():
    if not CATALOG_ADDR:
        log.error("missing configuration: PRODUCT_CATALOG_SERVICE_ADDR")
        sys.exit(1)

    # Tracing before the catalog's gRPC channel exists (its client spans, tracing.py).
    spans = tracing.OtelSpans() if tracing.start_tracing("shoppingassistantservice", log) else None
    import catalog  # gRPC: imported here so a missing address fails fast and clearly
    model = bedrock.BedrockModel(MODEL_ID, REGION, timeout_seconds=TIMEOUT)
    bot = core.Assistant(model, catalog.Catalog(CATALOG_ADDR), metrics=m.PrometheusMetrics(), spans=spans, **SETTINGS)
    m.DAILY_CAP.set(SETTINGS["daily_question_cap"])

    stop = threading.Event()
    threading.Thread(target=check_bedrock, args=(bot, stop), name="bedrock-check", daemon=True).start()
    server = ThreadingHTTPServer(("0.0.0.0", PORT), make_handler(bot))

    def shutdown(*_):
        info("shutting down")
        stop.set()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    info("listening", port=PORT, model=MODEL_ID, region=REGION, catalog=CATALOG_ADDR,
         dailyCap=SETTINGS["daily_question_cap"], maxTokens=SETTINGS["max_tokens"])
    server.serve_forever()


if __name__ == "__main__":
    main()
