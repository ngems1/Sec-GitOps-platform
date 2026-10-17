"""Week 3: order notifications from the event flow (step 4).

  order-status Lambda --OrderStatusUpdated--> EventBridge --> notification-q --> here

For every final order status (CONFIRMED or FAILED) the customer gets exactly one
email, and every email is logged in the DynamoDB notifications table:

  notificationId = <orderId>#<status>   (one notification per order and status)

Never twice: the log row is written FIRST, with a condition "only if it does not
exist yet". If the same event arrives twice (SQS delivers at least once), the
condition fails, the duplicate is skipped and the message deleted.

Delivery: real email through Amazon SES (SesSender) when the recipient is one of the
verified addresses (SES sandbox, SES_ALLOWED_RECIPIENTS); otherwise "log" mode: the
email is rendered and written to the service log. If SES refuses an email, the log
row is removed again and the message retried, so the retry is not taken for a duplicate.

Slack: when SLACK_ORDERS_WEBHOOK_URL is set, each new notification is also posted to
the team's orders channel (SlackNotifier). Best effort: Slack never blocks or fails the
processing, and at most one message every few seconds is posted (a load test places
thousands of orders): the next message says how many were not shown.

Failures: an invalid event or an AWS error leaves the message in the queue; it is
retried and, after 3 tries, moved to the dead-letter queue (CloudWatch alarm -> Slack).
This module has no boto3 import, so the tests run without AWS.

Tracing (ADR 0010, messagetrace.py): one CONSUMER span per message, in the order's trace when the
event has a "_trace" field; the field is removed before the event is parsed.
"""
import json
import time
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timezone

import messagetrace

SCHEMA_VERSION = "1"
EVENT_TYPE = "OrderStatusUpdated"
STATUSES = ("CONFIRMED", "FAILED")
DELIVERY_MODE = "log"


class InvalidEvent(Exception):
    """The message can't be processed. Retried, then moved to the dead-letter queue."""


@dataclass
class OrderStatus:
    order_id: str
    status: str
    reason: str = ""
    email: str = ""
    product_ids: list = field(default_factory=list)
    event_id: str = ""

    @property
    def notification_id(self):
        return f"{self.order_id}#{self.status}"


def parse_message(body):
    """SQS message body (an EventBridge event) -> OrderStatus."""
    try:
        event = json.loads(body)
    except (TypeError, ValueError) as exc:
        raise InvalidEvent(f"not JSON: {exc}") from exc
    if not isinstance(event, dict):
        raise InvalidEvent("event is not a JSON object")
    if event.get("detail-type") != EVENT_TYPE:
        raise InvalidEvent(f"unexpected event type {event.get('detail-type')!r}")
    detail = event.get("detail") or {}
    if str(detail.get("version", "")) != SCHEMA_VERSION:
        raise InvalidEvent(f"unsupported {EVENT_TYPE} version {detail.get('version')!r}")
    order_id = str(detail.get("orderId") or "")
    status = str(detail.get("status") or "")
    if not order_id:
        raise InvalidEvent(f"{EVENT_TYPE} without orderId")
    if status not in STATUSES:
        raise InvalidEvent(f"unexpected order status {status!r}")
    return OrderStatus(
        order_id=order_id,
        status=status,
        reason=str(detail.get("reason") or ""),
        email=str(detail.get("email") or ""),
        product_ids=[str(p) for p in detail.get("productIds") or []],
        event_id=str(event.get("id") or ""),
    )


def mask_email(address):
    """someone@example.com -> s*****e@example.com (the log never holds full addresses)."""
    if "@" not in address:
        return ""
    user, domain = address.split("@", 1)
    if len(user) <= 2:
        return f"{user[:1]}*@{domain}"
    return f"{user[0]}{'*' * (len(user) - 2)}{user[-1]}@{domain}"


def render_email(order):
    """(subject, body) for one order status."""
    short = order.order_id.split("-")[0]
    if order.status == "CONFIRMED":
        subject = f"Your order {short} is confirmed"
        body = ("Thank you for your order!\n\n"
                "All your items are reserved and your order is being prepared for shipping.\n\n"
                f"Order ID: {order.order_id}\n")
    else:
        products = ", ".join(order.product_ids) or "some items"
        reason = "out of stock" if order.reason == "INSUFFICIENT_STOCK" else (order.reason or "not available")
        subject = f"We couldn't complete your order {short}"
        body = ("We're sorry, we couldn't complete your order.\n\n"
                f"Reason: {reason} ({products}).\n"
                "Any payment for this order will be refunded.\n\n"
                f"Order ID: {order.order_id}\n")
    return subject, body


def _error_code(exc):
    return getattr(exc, "response", {}).get("Error", {}).get("Code", "")


class NotificationLog:
    """The DynamoDB notifications table."""

    def __init__(self, dynamodb_client, table_name):
        self.ddb = dynamodb_client
        self.table = table_name

    def claim(self, order, subject, delivery=DELIVERY_MODE):
        """Write the log row if this notification is new. False = already sent (duplicate)."""
        item = {
            "notificationId": {"S": order.notification_id},
            "orderId": {"S": order.order_id},
            "status": {"S": order.status},
            "channel": {"S": "email"},
            "delivery": {"S": delivery},
            "recipient": {"S": mask_email(order.email)},
            "subject": {"S": subject},
            "sentAt": {"S": datetime.now(timezone.utc).isoformat(timespec="seconds")},
        }
        if order.reason:
            item["reason"] = {"S": order.reason}
        if order.event_id:
            item["eventId"] = {"S": order.event_id}
        try:
            self.ddb.put_item(TableName=self.table, Item=item,
                              ConditionExpression="attribute_not_exists(notificationId)")
            return True
        except Exception as exc:  # noqa: BLE001
            if _error_code(exc) == "ConditionalCheckFailedException":
                return False
            raise

    def release(self, order):
        """Remove the row of a notification that could not be sent (the retry sends it)."""
        self.ddb.delete_item(TableName=self.table, Key={"notificationId": {"S": order.notification_id}})


class SesSender:
    """Real emails with Amazon SES (sesv2), only to the allowed (verified) recipients."""

    def __init__(self, sesv2_client, from_address, allowed_recipients):
        self.ses, self.from_address = sesv2_client, from_address
        self.allowed = {a.strip().lower() for a in allowed_recipients if a.strip()}

    def can_send(self, address):
        return address.strip().lower() in self.allowed

    def send(self, order, subject, body):
        """Returns the SES message ID. Raises on any SES error (the caller retries)."""
        resp = self.ses.send_email(
            FromEmailAddress=self.from_address,
            Destination={"ToAddresses": [order.email]},
            Content={"Simple": {"Subject": {"Data": subject, "Charset": "UTF-8"},
                                "Body": {"Text": {"Data": body, "Charset": "UTF-8"}}}})
        return resp.get("MessageId", "")


class SlackNotifier:
    """Posts order outcomes to a Slack incoming webhook (the team's #boutique-orders)."""

    def __init__(self, webhook_url, environment="", logger=None, min_interval=5.0,
                 post=None, clock=time.monotonic):
        self.url, self.environment, self.logger = webhook_url, environment, logger
        self.min_interval, self.clock = min_interval, clock
        self.post = post or self._post
        self.last_sent = None
        self.skipped = 0

    def _post(self, payload):
        req = urllib.request.Request(self.url, data=json.dumps(payload).encode(),
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=3) as resp:  # noqa: S310 - fixed https webhook
            resp.read()

    def text(self, order):
        short = order.order_id.split("-")[0]
        env = f" [{self.environment}]" if self.environment else ""
        items = f"{len(order.product_ids)} product(s)" if order.product_ids else "order"
        if order.status == "CONFIRMED":
            line = f":white_check_mark: Order `{short}` confirmed{env}: {items} reserved, ready to ship."
        else:
            reason = "out of stock" if order.reason == "INSUFFICIENT_STOCK" else (order.reason or "not available")
            line = f":x: Order `{short}` failed{env}: {reason}. Customer notified, payment refunded."
        if self.skipped:
            line += f"  _(+{self.skipped} more since the last message, not shown)_"
        return line

    def notify(self, order):
        """True if posted. Never raises: Slack is a nice-to-have, not part of the order flow."""
        now = self.clock()
        if self.last_sent is not None and now - self.last_sent < self.min_interval:
            self.skipped += 1
            return False
        try:
            self.post({"text": self.text(order)})
        except Exception as exc:  # noqa: BLE001
            if self.logger:
                self.logger.warning("slack notification failed", extra={"orderId": order.order_id, "error": str(exc)})
            return False
        self.last_sent, self.skipped = now, 0
        return True


def send(logger, order, subject, body):
    """Log-mode delivery: the rendered email goes to the service log."""
    logger.info("email sent", extra={
        "orderId": order.order_id, "status": order.status, "to": mask_email(order.email),
        "subject": subject, "delivery": DELIVERY_MODE, "body": body})


def handle(body, log_table, logger, slack=None, ses=None, span=None):
    """Process one message. Returns 'sent', 'duplicate' or 'no-email'. Raises to retry.
    span: the message's span, if any (gets the order ID)."""
    order = parse_message(body)
    messagetrace.set_order_id(span, order.order_id)
    subject, text = render_email(order)
    delivery = "ses" if ses and order.email and ses.can_send(order.email) else DELIVERY_MODE
    if not log_table.claim(order, subject, delivery):
        logger.info("duplicate event, email already sent",
                    extra={"orderId": order.order_id, "status": order.status})
        return "duplicate"
    result = "sent"
    if not order.email:
        logger.warning("no email address on the order, nothing sent",
                       extra={"orderId": order.order_id, "status": order.status})
        result = "no-email"
    elif delivery == "ses":
        try:
            message_id = ses.send(order, subject, text)
        except Exception:
            log_table.release(order)  # so the retried message can send it
            raise
        logger.info("email sent", extra={
            "orderId": order.order_id, "status": order.status, "to": mask_email(order.email),
            "subject": subject, "delivery": "ses", "sesMessageId": message_id})
    else:
        send(logger, order, subject, text)
    if slack:
        slack.notify(order)  # once per new notification, after the email
    return result


class Consumer:
    """Long-polls notification-q; deletes a message only once it is handled."""

    def __init__(self, sqs, queue_url, log_table, logger, slack=None, ses=None):
        self.sqs, self.queue_url, self.log_table, self.logger = sqs, queue_url, log_table, logger
        self.slack, self.ses = slack, ses
        self.last_poll = 0.0
        self.stopping = False

    def healthy(self, max_silence=90):
        return time.time() - self.last_poll < max_silence

    def poll_once(self, wait_seconds=20):
        self.last_poll = time.time()
        resp = self.sqs.receive_message(QueueUrl=self.queue_url, MaxNumberOfMessages=10,
                                        WaitTimeSeconds=wait_seconds,
                                        AttributeNames=["ApproximateReceiveCount"])
        results = []
        for msg in resp.get("Messages", []):
            try:
                body, carrier = messagetrace.take_trace(msg["Body"])
                with messagetrace.consumer_span(f"process {EVENT_TYPE}", carrier,
                                                {"messaging.system": "aws_sqs", "messaging.operation": "process"}) as span:
                    results.append(handle(body, self.log_table, self.logger, self.slack, self.ses, span))
                    self.sqs.delete_message(QueueUrl=self.queue_url, ReceiptHandle=msg["ReceiptHandle"])
            except InvalidEvent as exc:
                self.logger.error("invalid message, will retry then go to the DLQ",
                                  extra={"error": str(exc), "messageId": msg.get("MessageId")})
                results.append("invalid")
            except Exception as exc:  # noqa: BLE001 - AWS errors: the message is retried
                self.logger.exception("processing failed, message will be retried",
                                      extra={"error": str(exc), "messageId": msg.get("MessageId")})
                results.append("error")
        return results

    def run(self):
        self.logger.info("notification consumer started", extra={"queue": self.queue_url})
        while not self.stopping:
            try:
                self.poll_once()
            except Exception as exc:  # noqa: BLE001 - keep polling, AWS hiccups are transient
                self.logger.exception("receive_message failed", extra={"error": str(exc)})
                time.sleep(5)
