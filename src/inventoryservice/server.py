"""inventoryservice: REST API for stock + SQS consumer for OrderCreated.

  GET /stock              all stock levels
  GET /stock/<productId>  one product
  GET /healthz            liveness
  GET /readyz             readiness (consumer loop is polling)
  GET /metrics            Prometheus metrics

Consumer loop: inventory-q (OrderCreated) -> reserve stock in DynamoDB ->
publish InventoryReserved / InventoryFailed to EventBridge -> delete the message.
A message is deleted only after its result event is published. If anything
fails, the message becomes visible again and is retried; after 3 tries SQS
moves it to the dead-letter queue.
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

import boto3
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

import inventory as inv
import tracing

# ------------------------------------------------------------------ config
PORT = int(os.environ.get("PORT", "8080"))
REGION = os.environ.get("AWS_REGION", "us-east-1")
TABLE = os.environ.get("INVENTORY_TABLE", "")
QUEUE_URL = os.environ.get("INVENTORY_QUEUE_URL", "")
BUS = os.environ.get("EVENT_BUS_NAME", "")
CONSUMER_ENABLED = os.environ.get("CONSUMER_ENABLED", "true").lower() == "true"
SEED_STOCK = os.environ.get("SEED_STOCK", "true").lower() == "true"
DEFAULT_STOCK = int(os.environ.get("DEFAULT_STOCK", "50"))
STOCK_OVERRIDES = os.environ.get("STOCK_OVERRIDES", "6E92ZMYYFZ:2")  # Mug starts low: easy InventoryFailed demo

# ------------------------------------------------------------------ logging (JSON lines)
class JsonFormatter(logging.Formatter):
    def format(self, record):
        out = {"ts": self.formatTime(record), "level": record.levelname, "msg": record.getMessage(),
               "service": "inventoryservice"}
        out.update(getattr(record, "fields", {}))
        if record.exc_info:
            out["error"] = self.formatException(record.exc_info)
        return json.dumps(out)


handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(JsonFormatter())
log = logging.getLogger("inventory")
log.addHandler(handler)
log.setLevel(logging.INFO)


def info(msg, **fields):
    log.info(msg, extra={"fields": fields})


# ------------------------------------------------------------------ metrics
RESERVATIONS = Counter("inventory_reservations_total", "Reservation results", ["result"])
MESSAGE_ERRORS = Counter("inventory_message_errors_total", "Messages that failed and will be retried", ["kind"])
PROCESSING = Histogram("inventory_message_processing_seconds", "Time to process one OrderCreated message")

# ------------------------------------------------------------------ consumer
stop = threading.Event()
last_poll = {"t": 0.0}


def handle_message(store, events, msg, body=None, span=None):
    """body: the SQS body without its trace field (tracing.take_trace); span: the message's span."""
    with PROCESSING.time():
        order_id, items = inv.parse_order_created(msg["Body"] if body is None else body)
        tracing.set_order_id(span, order_id)
        res = store.reserve(order_id, items)
        detail_type, detail = inv.result_event(res)
        with tracing.producer_span(f"publish {detail_type}", BUS, order_id):
            inv.publish(events, BUS, detail_type, tracing.with_trace(detail))
    RESERVATIONS.labels("duplicate" if res.duplicate else res.status.lower()).inc()
    info("order processed", orderId=order_id, result=res.status, duplicate=res.duplicate,
         failedProducts=res.failed_products, receiveCount=msg.get("Attributes", {}).get("ApproximateReceiveCount"))


def consume(store, sqs, events):
    info("consumer started", queue=QUEUE_URL)
    while not stop.is_set():
        last_poll["t"] = time.time()
        try:
            with tracing.quiet():  # the 20 s long poll is not a span (tracing.py)
                resp = sqs.receive_message(QueueUrl=QUEUE_URL, MaxNumberOfMessages=10, WaitTimeSeconds=20,
                                           AttributeNames=["ApproximateReceiveCount"])
        except Exception:  # noqa: BLE001 - keep polling, AWS hiccups are transient
            MESSAGE_ERRORS.labels("receive").inc()
            log.exception("receive_message failed")
            stop.wait(5)
            continue
        for msg in resp.get("Messages", []):
            try:
                # The trace field comes out before the event is parsed; the span continues
                # checkout's trace when the field was there.
                body, carrier = tracing.take_trace(msg["Body"])
                with tracing.consumer_span("process OrderCreated",
                                           {"messaging.system": "aws_sqs", "messaging.operation": "process"},
                                           carrier) as span:
                    handle_message(store, events, msg, body, span)
                    sqs.delete_message(QueueUrl=QUEUE_URL, ReceiptHandle=msg["ReceiptHandle"])
            except inv.InvalidEvent as exc:
                MESSAGE_ERRORS.labels("invalid").inc()
                log.error("invalid message, will retry then go to DLQ: %s", exc)
            except Exception:  # noqa: BLE001
                MESSAGE_ERRORS.labels("processing").inc()
                log.exception("processing failed, message will be retried")
    info("consumer stopped")


# ------------------------------------------------------------------ HTTP
def make_handler(store, consumer_thread):
    class Handler(BaseHTTPRequestHandler):
        def _send(self, code, body, ctype="application/json"):
            self.last_code = code  # for the request's span (tracing.py)
            data = body if isinstance(body, bytes) else json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):  # noqa: N802
            path = self.path.split("?")[0].rstrip("/")
            if path == "/healthz":
                return self._send(200, {"status": "ok"})
            if path == "/readyz":
                alive = (not CONSUMER_ENABLED) or (
                    consumer_thread is not None and consumer_thread.is_alive() and time.time() - last_poll["t"] < 90)
                return self._send(200 if alive else 503, {"ready": alive})
            if path == "/metrics":
                return self._send(200, generate_latest(), CONTENT_TYPE_LATEST)
            # The API, traced: one span per request named after its route (no product ID in the name).
            route = "/stock" if path == "/stock" else "/stock/{productId}" if path.startswith("/stock/") else "/{unknown}"
            with tracing.server_span("GET", route, path, self.headers) as span:
                self._api(path)
                tracing.set_status_code(span, getattr(self, "last_code", 200))

        def _api(self, path):
            try:
                if path == "/stock":
                    return self._send(200, store.list_stock())
                if path.startswith("/stock/"):
                    pid = path[len("/stock/"):]
                    qty = store.get_stock(pid)
                    if qty is None:
                        return self._send(404, {"error": "unknown product", "productId": pid})
                    return self._send(200, {"productId": pid, "stock": qty})
            except Exception:  # noqa: BLE001
                log.exception("stock lookup failed")
                return self._send(500, {"error": "stock lookup failed"})
            return self._send(404, {"error": "not found"})

        def log_message(self, *args):  # silence default access log (probes are noisy)
            pass

    return Handler


def main():
    missing = [n for n, v in [("INVENTORY_TABLE", TABLE), ("EVENT_BUS_NAME", BUS)] if not v]
    if CONSUMER_ENABLED and not QUEUE_URL:
        missing.append("INVENTORY_QUEUE_URL")
    if missing:
        log.error("missing configuration: %s", ", ".join(missing))
        sys.exit(1)

    # Tracing before any AWS client exists (botocore instrumentation, tracing.py).
    tracing.start_tracing("inventoryservice", log)

    session = boto3.session.Session(region_name=REGION)
    store = inv.InventoryStore(session.client("dynamodb"), TABLE)

    if SEED_STOCK:
        stock = {pid: DEFAULT_STOCK for pid in inv.CATALOG_PRODUCT_IDS}
        stock.update(inv.parse_stock_overrides(STOCK_OVERRIDES))
        info("seeded stock", created=store.seed(stock))

    consumer = None
    if CONSUMER_ENABLED:
        consumer = threading.Thread(target=consume, args=(store, session.client("sqs"), session.client("events")),
                                    name="consumer", daemon=True)
        consumer.start()

    server = ThreadingHTTPServer(("0.0.0.0", PORT), make_handler(store, consumer))

    def shutdown(*_):
        info("shutting down")
        stop.set()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    info("listening", port=PORT, table=TABLE, bus=BUS, consumer=CONSUMER_ENABLED)
    server.serve_forever()
    if consumer:
        consumer.join(timeout=25)


if __name__ == "__main__":
    main()
