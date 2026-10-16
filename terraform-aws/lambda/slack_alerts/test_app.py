import json
import unittest

import app

ALARM = {
    "AlarmName": "week3-boutique-dev-order-status-dlq-not-empty",
    "AlarmDescription": "Messages for the order-status consumer are failing",
    "AlarmArn": "arn:aws:cloudwatch:us-east-1:111122223333:alarm:week3-boutique-dev-order-status-dlq-not-empty",
    "NewStateValue": "ALARM",
    "OldStateValue": "OK",
    "NewStateReason": "Threshold Crossed: 1 datapoint [1.0] was greater than 0.0",
    "StateChangeTime": "2026-10-02T16:00:00.000+0000",
}


def sns_event(message):
    return {"Records": [{"Sns": {"Message": message}}]}


# Shape of an EventBridge "GuardDuty Finding" event (trimmed to the fields used).
GUARDDUTY = {
    "source": "aws.guardduty",
    "detail-type": "GuardDuty Finding",
    "region": "us-east-1",
    "detail": {
        "id": "a1b2c3d4e5f6",
        "type": "UnauthorizedAccess:IAMUser/InstanceCredentialExfiltration.OutsideAWS",
        "title": "Credentials for an EC2 instance role were used from outside AWS.",
        "description": "Credentials created for the role were used from an external IP address.",
        "severity": 8,
        "resource": {"resourceType": "AccessKey"},
        "updatedAt": "2026-10-15T12:00:00.000Z",
    },
}


class SlackAlertsTest(unittest.TestCase):
    def test_alarm_message(self):
        msg = app.slack_message(ALARM)
        self.assertIn("ALARM: week3-boutique-dev-order-status-dlq-not-empty", msg["text"])
        body = msg["attachments"][0]
        self.assertEqual(body["color"], app.COLORS["ALARM"])
        self.assertIn("*Environment:* dev", body["text"])
        self.assertIn("region=us-east-1#alarmsV2:alarm/week3-boutique-dev-order-status-dlq-not-empty", body["text"])

    def test_ok_is_green(self):
        msg = app.slack_message(dict(ALARM, NewStateValue="OK", OldStateValue="ALARM"))
        self.assertEqual(msg["attachments"][0]["color"], app.COLORS["OK"])

    def test_posts_each_alarm(self):
        sent = []
        app.handler(sns_event(json.dumps(ALARM)), None,
                    get_url=lambda: "https://hooks.slack.com/services/x", send=lambda u, p: sent.append(p))
        self.assertEqual(len(sent), 1)

    def test_no_webhook_skips(self):
        sent = []
        app.handler(sns_event(json.dumps(ALARM)), None, get_url=lambda: None, send=lambda u, p: sent.append(p))
        self.assertEqual(sent, [])

    def test_non_json_message(self):
        sent = []
        app.handler(sns_event("plain text"), None,
                    get_url=lambda: "https://hooks.slack.com/services/x", send=lambda u, p: sent.append(p))
        self.assertIn("plain text", sent[0]["attachments"][0]["text"])

    def test_budget_notification(self):
        sent = []
        text = ("AWS Budget Notification October 16, 2026\nAWS Account 111122223333\n\n"
                "You requested that we alert you when the ACTUAL Cost associated with your "
                "week3-boutique-bedrock-daily budget is greater than $0.50 for the current day.")
        app.handler(sns_event(text), None,
                    get_url=lambda: "https://hooks.slack.com/services/x", send=lambda u, p: sent.append(p))
        self.assertIn("ALARM: AWS Budget (Bedrock daily)", sent[0]["text"])
        self.assertEqual(sent[0]["attachments"][0]["color"], app.COLORS["ALARM"])
        self.assertIn("week3-boutique-bedrock-daily", sent[0]["attachments"][0]["text"])
        self.assertIsNone(app.budget_alarm("something else"))

    def test_guardduty_message(self):
        msg = app.guardduty_message(GUARDDUTY)
        self.assertIn("GuardDuty HIGH: Credentials for an EC2 instance role", msg["text"])
        body = msg["attachments"][0]
        self.assertEqual(body["color"], app.COLORS["ALARM"])
        self.assertIn("*Severity:* 8 (HIGH)", body["text"])
        self.assertIn("*Resource:* AccessKey", body["text"])
        self.assertIn("guardduty/home?region=us-east-1#/findings?macros=current&fId=a1b2c3d4e5f6", body["text"])

    def test_guardduty_severity_bands(self):
        self.assertEqual(app.severity_label(9.5), "CRITICAL")
        self.assertEqual(app.severity_label(7), "HIGH")
        self.assertEqual(app.severity_label(6.9), "MEDIUM")
        self.assertEqual(app.severity_label(1), "LOW")

    def test_guardduty_event_posts_one_message(self):
        sent = []
        app.handler(GUARDDUTY, None,
                    get_url=lambda: "https://hooks.slack.com/services/x", send=lambda u, p: sent.append(p))
        self.assertEqual(len(sent), 1)
        self.assertIn("GuardDuty HIGH", sent[0]["text"])

    def test_guardduty_no_webhook_skips(self):
        sent = []
        app.handler(GUARDDUTY, None, get_url=lambda: None, send=lambda u, p: sent.append(p))
        self.assertEqual(sent, [])


if __name__ == "__main__":
    unittest.main()
