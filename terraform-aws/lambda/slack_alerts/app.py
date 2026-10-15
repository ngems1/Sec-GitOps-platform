"""slack-alerts Lambda: CloudWatch alarm (via SNS) or GuardDuty finding (via EventBridge) -> Slack.

Every alarm topic (one per environment) is subscribed to this function. It turns
the alarm into a short Slack message (red for ALARM, green for OK) and posts it to
the incoming webhook stored in Secrets Manager (SLACK_SECRET_ARN). The webhook URL
is written there by the infra workflow, so it never appears in code, Terraform
state or this function's settings.

An EventBridge rule (security-alerts.tf) also sends GuardDuty findings of high
severity here; they become one message each, with a link to the finding.

No webhook stored yet -> the alarm is logged and skipped (nothing fails).
"""
import json
import logging
import os
import time
import urllib.parse
import urllib.request

import boto3

log = logging.getLogger()
log.setLevel(logging.INFO)

_cache = {"url": None, "at": 0.0}
CACHE_SECONDS = 300

COLORS = {"ALARM": "#d93025", "OK": "#1e8e3e", "INSUFFICIENT_DATA": "#9aa0a6"}
ICONS = {"ALARM": ":red_circle:", "OK": ":large_green_circle:", "INSUFFICIENT_DATA": ":white_circle:"}


def webhook_url():
    """The webhook URL from Secrets Manager (cached for a few minutes), or None."""
    if _cache["url"] and time.time() - _cache["at"] < CACHE_SECONDS:
        return _cache["url"]
    client = boto3.client("secretsmanager")
    try:
        value = client.get_secret_value(SecretId=os.environ["SLACK_SECRET_ARN"])["SecretString"].strip()
    except client.exceptions.ResourceNotFoundException:
        return None  # the secret exists but no value was stored yet
    if not value.startswith("https://hooks.slack.com/"):
        raise ValueError("the stored Slack webhook URL is not a hooks.slack.com URL")
    _cache.update(url=value, at=time.time())
    return value


def console_link(region, alarm_name):
    return (f"https://{region}.console.aws.amazon.com/cloudwatch/home?region={region}"
            f"#alarmsV2:alarm/{urllib.parse.quote(alarm_name, safe='')}")


def slack_message(alarm):
    """Slack payload for one CloudWatch alarm notification (the SNS message body)."""
    name = alarm.get("AlarmName", "unknown alarm")
    state = alarm.get("NewStateValue", "UNKNOWN")
    old = alarm.get("OldStateValue", "")
    region = (alarm.get("AlarmArn", "").split(":")[3:4] or [os.environ.get("AWS_REGION", "us-east-1")])[0]
    env = "prod" if "-prod-" in name else "dev" if "-dev-" in name else "-"
    lines = [alarm.get("AlarmDescription") or "",
             f"*Environment:* {env}    *State:* {old} -> {state}",
             f"*Reason:* {alarm.get('NewStateReason', '')}",
             f"<{console_link(region, name)}|Open the alarm in CloudWatch>"]
    return {
        "text": f"{ICONS.get(state, '')} {state}: {name}",
        "attachments": [{"color": COLORS.get(state, "#9aa0a6"),
                         "text": "\n".join(line for line in lines if line),
                         "footer": alarm.get("StateChangeTime", "")}],
    }


def severity_label(severity):
    """GuardDuty's bands: 9.0+ critical, 7.0+ high, 4.0+ medium, otherwise low."""
    return "CRITICAL" if severity >= 9 else "HIGH" if severity >= 7 else "MEDIUM" if severity >= 4 else "LOW"


def guardduty_message(event):
    """Slack payload for one GuardDuty finding (an EventBridge "GuardDuty Finding" event)."""
    finding = event.get("detail", {})
    severity = float(finding.get("severity", 0))
    label = severity_label(severity)
    region = event.get("region") or finding.get("region") or os.environ.get("AWS_REGION", "us-east-1")
    link = (f"https://{region}.console.aws.amazon.com/guardduty/home?region={region}"
            f"#/findings?macros=current&fId={urllib.parse.quote(finding.get('id', ''), safe='')}")
    resource = finding.get("resource", {}).get("resourceType", "-")
    lines = [finding.get("description") or "",
             f"*Severity:* {severity:g} ({label})    *Type:* {finding.get('type', '-')}",
             f"*Resource:* {resource}    *Region:* {region}",
             f"<{link}|Open the finding in GuardDuty>"]
    return {
        "text": f":rotating_light: GuardDuty {label}: {finding.get('title') or finding.get('type', 'finding')}",
        "attachments": [{"color": COLORS["ALARM"] if severity >= 7 else "#f9ab00",
                         "text": "\n".join(line for line in lines if line),
                         "footer": finding.get("updatedAt", "")}],
    }


def payloads(event):
    """One Slack payload per alarm (SNS records) or for the GuardDuty finding (EventBridge)."""
    if event.get("source") == "aws.guardduty":
        return [guardduty_message(event)]
    out = []
    for record in event.get("Records", []):
        raw = record.get("Sns", {}).get("Message", "{}")
        try:
            alarm = json.loads(raw)
        except json.JSONDecodeError:
            alarm = {"AlarmName": "SNS message", "NewStateValue": "INSUFFICIENT_DATA", "NewStateReason": raw}
        out.append(slack_message(alarm))
    return out


def post(url, payload):
    req = urllib.request.Request(url, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as resp:  # noqa: S310 (fixed https host, checked above)
        return resp.status


def handler(event, context, get_url=webhook_url, send=post):
    url = get_url()
    for payload in payloads(event):
        if not url:
            log.warning(json.dumps({"msg": "no Slack webhook stored, alarm not sent", "alarm": payload["text"]}))
            continue
        send(url, payload)  # an error here makes the (asynchronous) delivery retry
        log.info(json.dumps({"msg": "alarm sent to Slack", "alarm": payload["text"]}))
