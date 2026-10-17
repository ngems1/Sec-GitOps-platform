"""order-status Lambda: inventory result -> order status in MySQL -> OrderStatusUpdated.

Trigger: SQS order-status-q (EventBridge rule: InventoryReserved | InventoryFailed).

  InventoryReserved -> orders.status = CONFIRMED
  InventoryFailed   -> orders.status = FAILED (reason = INSUFFICIENT_STOCK)

Then publishes OrderStatusUpdated (source boutique.orderstatus), which the
notification consumer (emailservice) turns into exactly one email.

Idempotent: the UPDATE only moves an order out of PENDING. A redelivered event
finds the order already in that status and simply re-publishes the same result.
If the order row is not there yet, the message fails and is retried
(3 tries, then the dead-letter queue).

Tracing (ADR 0010, step 5): the Lambda has no OpenTelemetry. It only copies the
event's "_trace" field (W3C traceparent/tracestate, put there by inventoryservice)
to OrderStatusUpdated, so emailservice's span joins the order's trace, as a child of
inventory's publish span. Events without the field are handled as before.

Runs inside the VPC. DB credentials come from the RDS-managed secret in
Secrets Manager; on "access denied" (password rotated) it re-reads the secret once.
pymysql and the RDS CA bundle are added to this folder by the infra workflow.
"""
import json
import logging
import os

log = logging.getLogger()
log.setLevel(logging.INFO)

SOURCE = "boutique.orderstatus"
SCHEMA_VERSION = "1"
RESULTS = {"InventoryReserved": "CONFIRMED", "InventoryFailed": "FAILED"}
CA_BUNDLE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "global-bundle.pem")

_clients = {}
_state = {"conn": None, "creds": None}


class OrderNotFound(Exception):
    """The order row does not exist (yet). Retried, then sent to the DLQ."""


def _client(name):
    if name not in _clients:
        import boto3  # available in the Lambda runtime
        _clients[name] = boto3.client(name)
    return _clients[name]


def _credentials(refresh=False):
    if refresh or _state["creds"] is None:
        secret = _client("secretsmanager").get_secret_value(SecretId=os.environ["DB_SECRET_ARN"])
        _state["creds"] = json.loads(secret["SecretString"])
    return _state["creds"]


def _connect(refresh=False):
    import pymysql  # vendored at build time

    creds = _credentials(refresh)
    return pymysql.connect(
        host=os.environ["DB_HOST"],
        port=int(os.environ.get("DB_PORT", "3306")),
        user=creds["username"],
        password=creds["password"],
        database=os.environ["DB_NAME"],
        ssl_ca=CA_BUNDLE if os.path.exists(CA_BUNDLE) else None,
        connect_timeout=5,
        autocommit=False,
        cursorclass=pymysql.cursors.DictCursor,
    )


def get_connection():
    conn = _state["conn"]
    if conn is not None:
        try:
            conn.ping(reconnect=True)
            return conn
        except Exception:  # noqa: BLE001
            _state["conn"] = None
    try:
        _state["conn"] = _connect()
    except Exception as exc:  # noqa: BLE001
        if getattr(exc, "args", [None])[0] != 1045:  # 1045 = access denied
            raise
        log.info("access denied, re-reading the rotated DB secret")
        _state["conn"] = _connect(refresh=True)
    return _state["conn"]


def apply_result(conn, order_id, new_status, reason):
    """Move the order out of PENDING. Returns (row, changed)."""
    with conn.cursor() as cur:
        cur.execute(
            "UPDATE orders SET status = %s, status_reason = %s "
            "WHERE order_id = %s AND status = 'PENDING'",
            (new_status, reason, order_id),
        )
        changed = cur.rowcount == 1
        cur.execute("SELECT order_id, email, status, status_reason FROM orders WHERE order_id = %s", (order_id,))
        row = cur.fetchone()
    conn.commit()
    return row, changed


def process(event, conn, publish):
    detail_type = event.get("detail-type")
    if detail_type not in RESULTS:
        raise ValueError(f"unexpected event type {detail_type}")
    detail = event.get("detail") or {}
    if str(detail.get("version", "")) != SCHEMA_VERSION:
        raise ValueError(f"unsupported {detail_type} version {detail.get('version')}")
    order_id = detail.get("orderId")
    if not order_id:
        raise ValueError(f"{detail_type} without orderId")
    trace_field = _trace_field(detail.get("_trace"))

    new_status = RESULTS[detail_type]
    reason = "" if new_status == "CONFIRMED" else str(detail.get("reason") or "INSUFFICIENT_STOCK")

    row, changed = apply_result(conn, order_id, new_status, reason)
    if row is None:
        raise OrderNotFound(order_id)
    if row["status"] != new_status:
        log.warning(json.dumps({"msg": "order already settled differently, ignoring",
                                "orderId": order_id, "current": row["status"], "event": detail_type}))
        return None

    out = {"version": SCHEMA_VERSION, "orderId": order_id, "status": new_status,
           "reason": row["status_reason"], "email": row["email"],
           "productIds": detail.get("productIds", [])}
    if trace_field:
        out["_trace"] = trace_field
    publish(out)
    log.info(json.dumps({"msg": "order status updated", "orderId": order_id,
                         "status": new_status, "duplicate": not changed}))
    return out


def _trace_field(raw):
    """The W3C keys of an incoming "_trace" field, as short strings, or None."""
    if not isinstance(raw, dict):
        return None
    out = {k: raw[k] for k in ("traceparent", "tracestate") if isinstance(raw.get(k), str) and len(raw[k]) <= 512}
    return out if "traceparent" in out else None


def _publish(detail):
    resp = _client("events").put_events(Entries=[{
        "Source": SOURCE,
        "DetailType": "OrderStatusUpdated",
        "Detail": json.dumps(detail),
        "EventBusName": os.environ["EVENT_BUS_NAME"],
    }])
    if resp.get("FailedEntryCount", 0):
        raise RuntimeError(f"PutEvents failed: {resp.get('Entries')}")


def handler(event, context, conn_factory=get_connection, publish=_publish):
    failures = []
    for record in event.get("Records", []):
        try:
            process(json.loads(record["body"]), conn_factory(), publish)
        except Exception:  # noqa: BLE001 - only this message is retried
            log.exception("failed to process message %s", record.get("messageId"))
            failures.append({"itemIdentifier": record["messageId"]})
    return {"batchItemFailures": failures}
