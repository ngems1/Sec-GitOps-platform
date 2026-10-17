"""Unit tests for the notification consumer. Run: python -m unittest -v test_notifications

In-memory fakes for DynamoDB, SQS and the logger: no AWS account or boto3 needed.
"""
import json
import unittest

import messagetrace
import notifications as n


def status_event(order_id="o-1", status="CONFIRMED", email="someone@example.com", **detail):
    body = {"version": "1", "orderId": order_id, "status": status, "email": email,
            "reason": "" if status == "CONFIRMED" else "INSUFFICIENT_STOCK", "productIds": [], **detail}
    return json.dumps({"id": "evt-1", "detail-type": "OrderStatusUpdated",
                       "source": "boutique.orderstatus", "detail": body})


class FakeAwsError(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.response = {"Error": {"Code": code}}


class FakeDynamo:
    def __init__(self, fail=None):
        self.items, self.fail = {}, fail

    def put_item(self, TableName, Item, ConditionExpression=None):
        if self.fail:
            raise FakeAwsError(self.fail)
        key = Item["notificationId"]["S"]
        if ConditionExpression == "attribute_not_exists(notificationId)" and key in self.items:
            raise FakeAwsError("ConditionalCheckFailedException")
        self.items[key] = Item

    def delete_item(self, TableName, Key):
        self.items.pop(Key["notificationId"]["S"], None)


class FakeLogger:
    def __init__(self):
        self.lines = []

    def _log(self, level, msg, extra=None, **_):
        self.lines.append((level, msg, extra or {}))

    def info(self, msg, extra=None, **kw):
        self._log("info", msg, extra, **kw)

    def warning(self, msg, extra=None, **kw):
        self._log("warning", msg, extra, **kw)

    def error(self, msg, extra=None, **kw):
        self._log("error", msg, extra, **kw)

    def exception(self, msg, extra=None, **kw):
        self._log("exception", msg, extra, **kw)

    def sent(self):
        return [extra for level, msg, extra in self.lines if msg == "email sent"]


class FakeSqs:
    def __init__(self, bodies):
        self.messages = [{"MessageId": f"m{i}", "ReceiptHandle": f"r{i}", "Body": b}
                         for i, b in enumerate(bodies)]
        self.deleted = []

    def receive_message(self, **_):
        batch, self.messages = self.messages, []
        return {"Messages": batch}

    def delete_message(self, QueueUrl, ReceiptHandle):
        self.deleted.append(ReceiptHandle)


class ParseTest(unittest.TestCase):
    def test_valid_event(self):
        order = n.parse_message(status_event(status="FAILED", productIds=["6E92ZMYYFZ"]))
        self.assertEqual((order.order_id, order.status, order.reason), ("o-1", "FAILED", "INSUFFICIENT_STOCK"))
        self.assertEqual(order.product_ids, ["6E92ZMYYFZ"])
        self.assertEqual(order.notification_id, "o-1#FAILED")

    def test_invalid_events(self):
        for body in ["not json", "[]",
                     json.dumps({"detail-type": "OrderCreated", "detail": {"version": "1"}}),
                     status_event(version="2"), status_event(order_id=""), status_event(status="PENDING")]:
            with self.subTest(body=body):
                with self.assertRaises(n.InvalidEvent):
                    n.parse_message(body)

    def test_mask_email(self):
        self.assertEqual(n.mask_email("someone@example.com"), "s*****e@example.com")
        self.assertEqual(n.mask_email("ab@x.io"), "a*@x.io")
        self.assertEqual(n.mask_email(""), "")

    def test_render(self):
        ok_subject, _ = n.render_email(n.parse_message(status_event(order_id="21b52dcc-be7a")))
        self.assertEqual(ok_subject, "Your order 21b52dcc is confirmed")
        _, failed_body = n.render_email(n.parse_message(status_event(status="FAILED", productIds=["MUG"])))
        self.assertIn("out of stock (MUG)", failed_body)


class HandleTest(unittest.TestCase):
    def setUp(self):
        self.ddb, self.logger = FakeDynamo(), FakeLogger()
        self.log_table = n.NotificationLog(self.ddb, "notifications")

    def test_sends_once_and_logs_masked_row(self):
        self.assertEqual(n.handle(status_event(), self.log_table, self.logger), "sent")
        row = self.ddb.items["o-1#CONFIRMED"]
        self.assertEqual(row["recipient"]["S"], "s*****e@example.com")
        self.assertEqual(row["delivery"]["S"], "log")
        self.assertEqual(len(self.logger.sent()), 1)

    def test_duplicate_event_sends_nothing(self):
        n.handle(status_event(), self.log_table, self.logger)
        self.assertEqual(n.handle(status_event(), self.log_table, self.logger), "duplicate")
        self.assertEqual(len(self.logger.sent()), 1)

    def test_confirmed_then_failed_are_two_notifications(self):
        n.handle(status_event(status="CONFIRMED"), self.log_table, self.logger)
        n.handle(status_event(status="FAILED"), self.log_table, self.logger)
        self.assertEqual(set(self.ddb.items), {"o-1#CONFIRMED", "o-1#FAILED"})

    def test_no_email_is_logged_not_sent(self):
        self.assertEqual(n.handle(status_event(email=""), self.log_table, self.logger), "no-email")
        self.assertEqual(self.logger.sent(), [])

    def test_aws_error_propagates_for_retry(self):
        log_table = n.NotificationLog(FakeDynamo(fail="ProvisionedThroughputExceededException"), "t")
        with self.assertRaises(FakeAwsError):
            n.handle(status_event(), log_table, self.logger)


class ConsumerTest(unittest.TestCase):
    def test_deletes_only_handled_messages(self):
        sqs, logger = FakeSqs([status_event(), "garbage", status_event()]), FakeLogger()
        consumer = n.Consumer(sqs, "q", n.NotificationLog(FakeDynamo(), "t"), logger)
        self.assertEqual(consumer.poll_once(wait_seconds=0), ["sent", "invalid", "duplicate"])
        self.assertEqual(sqs.deleted, ["r0", "r2"])  # the invalid one stays: retried, then DLQ
        self.assertTrue(consumer.healthy())

    def test_trace_field_is_removed_before_processing(self):
        tp = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
        traced = json.loads(status_event())
        traced["detail"]["_trace"] = {"traceparent": tp}
        body, carrier = messagetrace.take_trace(json.dumps(traced))
        self.assertEqual((json.loads(body), carrier), (json.loads(status_event()), {"traceparent": tp}))
        self.assertEqual(messagetrace.take_trace(status_event()), (status_event(), {}))  # old events unchanged
        self.assertEqual(messagetrace.take_trace("garbage"), ("garbage", {}))
        # Processed and deleted, with or without the field (and with a broken one)
        broken = json.loads(status_event())
        broken["detail"].update(orderId="o2", _trace="x")
        sqs = FakeSqs([json.dumps(traced), json.dumps(broken)])
        consumer = n.Consumer(sqs, "q", n.NotificationLog(FakeDynamo(), "t"), FakeLogger())
        self.assertEqual(consumer.poll_once(wait_seconds=0), ["sent", "sent"])
        self.assertEqual(sqs.deleted, ["r0", "r1"])

    def test_aws_error_keeps_message(self):
        sqs = FakeSqs([status_event()])
        consumer = n.Consumer(sqs, "q", n.NotificationLog(FakeDynamo(fail="InternalServerError"), "t"), FakeLogger())
        self.assertEqual(consumer.poll_once(wait_seconds=0), ["error"])
        self.assertEqual(sqs.deleted, [])



class FakeClock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


class SlackTest(unittest.TestCase):
    def setUp(self):
        self.posts, self.clock = [], FakeClock()
        self.slack = n.SlackNotifier("https://hooks.example/x", "dev", FakeLogger(), min_interval=5,
                                     post=self.posts.append, clock=self.clock)

    def test_confirmed_and_failed_texts(self):
        self.assertTrue(self.slack.notify(n.parse_message(status_event("abc-1", "CONFIRMED"))))
        self.clock.now += 10
        self.assertTrue(self.slack.notify(n.parse_message(status_event("def-2", "FAILED"))))
        self.assertIn("Order `abc` confirmed [dev]", self.posts[0]["text"])
        self.assertIn("Order `def` failed [dev]: out of stock", self.posts[1]["text"])

    def test_rate_limit_counts_skipped(self):
        order = n.parse_message(status_event())
        self.assertTrue(self.slack.notify(order))
        self.assertFalse(self.slack.notify(order))   # 0 s later: skipped
        self.assertFalse(self.slack.notify(order))
        self.clock.now += 6
        self.assertTrue(self.slack.notify(order))
        self.assertEqual(len(self.posts), 2)
        self.assertIn("+2 more", self.posts[1]["text"])

    def test_slack_error_never_raises(self):
        def broken(_):
            raise OSError("network down")
        slack = n.SlackNotifier("https://hooks.example/x", post=broken, clock=self.clock)
        self.assertFalse(slack.notify(n.parse_message(status_event())))

    def test_duplicate_event_posts_once(self):
        log = n.NotificationLog(FakeDynamo(), "t")
        logger = FakeLogger()
        n.handle(status_event(), log, logger, self.slack)
        self.clock.now += 10
        self.assertEqual(n.handle(status_event(), log, logger, self.slack), "duplicate")
        self.assertEqual(len(self.posts), 1)



class FakeSes:
    def __init__(self, fail=False):
        self.sent, self.fail = [], fail

    def send_email(self, FromEmailAddress, Destination, Content):
        if self.fail:
            raise FakeAwsError("MessageRejected")
        self.sent.append((FromEmailAddress, Destination["ToAddresses"][0], Content["Simple"]["Subject"]["Data"]))
        return {"MessageId": f"m-{len(self.sent)}"}


class SesTest(unittest.TestCase):
    def setUp(self):
        self.ddb, self.logger = FakeDynamo(), FakeLogger()
        self.log_table = n.NotificationLog(self.ddb, "notifications")

    def test_verified_recipient_gets_a_real_email(self):
        ses = n.SesSender(FakeSes(), "orders@shop.example", ["Me@Mail.example"])
        self.assertEqual(n.handle(status_event(email="me@mail.example"), self.log_table, self.logger, ses=ses), "sent")
        self.assertEqual(ses.ses.sent, [("orders@shop.example", "me@mail.example", "Your order o is confirmed")])
        self.assertEqual(self.ddb.items["o-1#CONFIRMED"]["delivery"]["S"], "ses")

    def test_other_recipients_stay_in_log_mode(self):
        ses = n.SesSender(FakeSes(), "orders@shop.example", ["me@mail.example"])
        n.handle(status_event(email="someone@example.com"), self.log_table, self.logger, ses=ses)
        self.assertEqual(ses.ses.sent, [])
        self.assertEqual(self.ddb.items["o-1#CONFIRMED"]["delivery"]["S"], "log")

    def test_ses_error_releases_the_row_so_the_retry_sends(self):
        ses = n.SesSender(FakeSes(fail=True), "orders@shop.example", ["me@mail.example"])
        with self.assertRaises(FakeAwsError):
            n.handle(status_event(email="me@mail.example"), self.log_table, self.logger, ses=ses)
        self.assertNotIn("o-1#CONFIRMED", self.ddb.items)
        ses.ses.fail = False
        self.assertEqual(n.handle(status_event(email="me@mail.example"), self.log_table, self.logger, ses=ses), "sent")
        self.assertEqual(len(ses.ses.sent), 1)


class NoAddressInLogsTest(unittest.TestCase):
    """The service log never holds the shopper's address, not even masked (ADR 0011)."""

    def test_no_address_in_any_log_line(self):
        logger = FakeLogger()
        log_table = n.NotificationLog(FakeDynamo(), "t")
        ses = n.SesSender(FakeSes(), "orders@shop.example", ["jane.doe@mail.example"])
        n.handle(status_event(email="jane.doe@mail.example"), log_table, logger, ses=ses)  # SES
        n.handle(status_event(email="jane.doe@mail.example"), log_table, logger, ses=ses)  # duplicate
        n.handle(status_event(order_id="o-2", email="john.roe@other.example"), log_table, logger)  # log mode
        n.handle(status_event(order_id="o-3", email=""), log_table, logger)  # no address
        self.assertEqual(len(logger.sent()), 2)
        for level, msg, extra in logger.lines:
            line = msg + " " + " ".join(str(v) for v in extra.values())
            for secret in ("jane", "john", "mail.example", "other.example", "*@"):
                self.assertNotIn(secret, line, (level, msg, extra))
            self.assertIn("orderId", extra)


if __name__ == "__main__":
    unittest.main()
