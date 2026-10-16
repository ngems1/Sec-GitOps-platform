# Bedrock daily budget of the AI shopping assistant (ADR 0009). Account-level, so here (never
# destroyed), applied by the bootstrap role; the CI roles' boundaries need no budgets rights.
#
# AWS Budgets publishes to this topic; terraform-aws subscribes the slack-alerts Lambda to it
# (GitHub variable BUDGET_ALERTS_TOPIC_ARN = the output below), so alerts reach #boutique-alerts
# like the CloudWatch alarms. A budget only alerts (AWS updates the cost a few times a day, so
# hours late), it does not stop spending: the assistant's own daily question cap does that.

resource "aws_sns_topic" "budget_alerts" {
  name = "${var.project}-budget-alerts"
  # No KMS key: AWS Budgets cannot publish to a topic encrypted with the AWS-managed SNS key.
}

data "aws_iam_policy_document" "budget_alerts" {
  statement {
    sid       = "BudgetsPublish"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.budget_alerts.arn]
    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:budgets::${local.account_id}:*"]
    }
  }
}

resource "aws_sns_topic_policy" "budget_alerts" {
  arn    = aws_sns_topic.budget_alerts.arn
  policy = data.aws_iam_policy_document.budget_alerts.json
}

resource "aws_budgets_budget" "bedrock_daily" {
  name         = "${var.project}-bedrock-daily"
  budget_type  = "COST"
  limit_amount = var.bedrock_daily_budget_usd
  limit_unit   = "USD"
  time_unit    = "DAILY"

  # Nova (Amazon's own models) is billed under this service. A Claude model bought through
  # AWS Marketplace would be billed under its own Marketplace product: add it here then.
  cost_filter {
    name   = "Service"
    values = ["Amazon Bedrock"]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 50
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.budget_alerts.arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.budget_alerts.arn]
  }

  depends_on = [aws_sns_topic_policy.budget_alerts]
}
