"""The gRPC SendOrderConfirmation log line holds the order ID, never the shopper's address
(ADR 0011). Needs the service's requirements (grpc, demo_pb2), like test_tracing.py, except
google-cloud-profiler (CI leaves it out: it compiles C++), which is stubbed."""
import sys
import types
import unittest

sys.modules.setdefault("googlecloudprofiler", types.ModuleType("googlecloudprofiler"))

import demo_pb2  # noqa: E402
import email_server  # noqa: E402


class SendOrderConfirmationLogTest(unittest.TestCase):
    def test_logs_the_order_id_not_the_address(self):
        request = demo_pb2.SendOrderConfirmationRequest(
            email="jane.doe@mail.example", order=demo_pb2.OrderResult(order_id="o-42"))
        with self.assertLogs("emailservice-server", level="INFO") as logs:
            email_server.DummyEmailService().SendOrderConfirmation(request, None)
        record = logs.records[-1]
        self.assertEqual(record.orderId, "o-42")
        everything = " ".join(str(v) for v in vars(record).values())
        for secret in ("jane", "mail.example"):
            self.assertNotIn(secret, everything)


if __name__ == "__main__":
    unittest.main()
