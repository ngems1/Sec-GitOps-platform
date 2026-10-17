"""Unit tests for the order-status Lambda. Run: python -m unittest -v (no AWS, no MySQL)."""
import json
import unittest

import app


class FakeCursor:
    def __init__(self, db):
        self.db, self.rowcount, self._row = db, 0, None

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def execute(self, sql, params):
        if sql.startswith("UPDATE"):
            status, reason, oid = params
            row = self.db.get(oid)
            if row and row["status"] == "PENDING":
                row.update(status=status, status_reason=reason)
                self.rowcount = 1
            else:
                self.rowcount = 0
        else:
            row = self.db.get(params[0])
            self._row = dict(row, order_id=params[0]) if row else None

    def fetchone(self):
        return self._row


class FakeConn:
    def __init__(self, orders):
        self.db = {k: dict(v) for k, v in orders.items()}

    def cursor(self):
        return FakeCursor(self.db)

    def commit(self):
        pass


def sqs_event(*events):
    return {"Records": [{"messageId": f"m{i}", "body": json.dumps(e)} for i, e in enumerate(events)]}


def result(detail_type, order_id, **extra):
    return {"detail-type": detail_type, "detail": {"version": "1", "orderId": order_id, **extra}}


class OrderStatusTests(unittest.TestCase):
    def setUp(self):
        self.conn = FakeConn({
            "o1": {"email": "a@x.com", "status": "PENDING", "status_reason": ""},
            "o2": {"email": "b@x.com", "status": "PENDING", "status_reason": ""},
        })
        self.sent = []

    def run_handler(self, *events):
        return app.handler(sqs_event(*events), None, conn_factory=lambda: self.conn, publish=self.sent.append)

    def test_reserved_confirms_order(self):
        out = self.run_handler(result("InventoryReserved", "o1"))
        self.assertEqual(out, {"batchItemFailures": []})
        self.assertEqual(self.conn.db["o1"]["status"], "CONFIRMED")
        self.assertEqual((self.sent[0]["status"], self.sent[0]["email"]), ("CONFIRMED", "a@x.com"))

    def test_failed_marks_order_failed_with_reason(self):
        self.run_handler(result("InventoryFailed", "o2", reason="INSUFFICIENT_STOCK", productIds=["6E92ZMYYFZ"]))
        self.assertEqual(self.conn.db["o2"]["status"], "FAILED")
        self.assertEqual((self.sent[0]["reason"], self.sent[0]["productIds"]), ("INSUFFICIENT_STOCK", ["6E92ZMYYFZ"]))

    def test_redelivery_republishes_same_result(self):
        self.run_handler(result("InventoryReserved", "o1"), result("InventoryReserved", "o1"))
        self.assertEqual([s["status"] for s in self.sent], ["CONFIRMED", "CONFIRMED"])

    def test_conflicting_result_is_ignored(self):
        self.run_handler(result("InventoryFailed", "o1"), result("InventoryReserved", "o1"))
        self.assertEqual(self.conn.db["o1"]["status"], "FAILED")
        self.assertEqual(len(self.sent), 1)

    def test_unknown_order_is_retried(self):
        out = self.run_handler(result("InventoryReserved", "nope"), result("InventoryReserved", "o1"))
        self.assertEqual(out, {"batchItemFailures": [{"itemIdentifier": "m0"}]})  # only the bad one
        self.assertEqual(self.conn.db["o1"]["status"], "CONFIRMED")

    def test_bad_messages_are_retried(self):
        out = self.run_handler({"detail-type": "Other"}, result("InventoryReserved", "o1", version="9"))
        self.assertEqual(len(out["batchItemFailures"]), 2)
        self.assertEqual(self.sent, [])

    def test_trace_field_is_passed_on(self):
        tp = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
        self.run_handler(result("InventoryReserved", "o1", _trace={"traceparent": tp, "baggage": "x=y"}),
                         result("InventoryReserved", "o2"), result("InventoryFailed", "o1", _trace="bad"))
        self.assertEqual(self.sent[0]["_trace"], {"traceparent": tp})
        self.assertNotIn("_trace", self.sent[1])  # no field in, none out
        self.assertEqual(self.conn.db["o2"]["status"], "CONFIRMED")


if __name__ == "__main__":
    unittest.main()
