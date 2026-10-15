# GuardDuty findings of high severity (>= 7 by default) -> slack-alerts Lambda -> Slack.
#
# GuardDuty itself is account-level and lives in terraform-bootstrap (never destroyed,
# ADR 0003); this rule is destroyed and recreated with the rest of terraform-aws. Findings
# arrive on the default event bus of this region. Before GuardDuty is on, the rule simply
# never matches.
resource "aws_cloudwatch_event_rule" "guardduty_high" {
  name        = "${var.project}-guardduty-high"
  description = "GuardDuty findings with severity >= ${var.guardduty_alert_min_severity}, to the slack-alerts Lambda"

  event_pattern = jsonencode({
    source        = ["aws.guardduty"]
    "detail-type" = ["GuardDuty Finding"]
    detail = {
      severity = [{ numeric = [">=", var.guardduty_alert_min_severity] }]
    }
  })
}

resource "aws_cloudwatch_event_target" "guardduty_high" {
  rule = aws_cloudwatch_event_rule.guardduty_high.name
  arn  = aws_lambda_function.slack_alerts.arn
}

resource "aws_lambda_permission" "guardduty_high" {
  statement_id  = "eventbridge-guardduty"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.slack_alerts.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.guardduty_high.arn
}
