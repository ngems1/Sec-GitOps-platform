# CloudWatch alarms -> SNS (one topic per environment) -> slack-alerts Lambda -> Slack.
# GuardDuty findings reach the same Lambda through EventBridge (security-alerts.tf).
#
# Alarms go to their own Slack channel (e.g. #boutique-alerts), separate from the
# pipeline messages (#boutique-deploys), through their own incoming webhook.
# The webhook URL lives in a Secrets Manager secret: Terraform creates the empty
# secret, and the infra workflow writes the value from the GitHub secret
# SLACK_ALERTS_WEBHOOK_URL after each apply. So the URL is never in code, in the Terraform
# state, or in the Lambda's settings. No value stored = alarms are only logged.
#
# (Amazon Q Developer in chat applications, the AWS-managed Slack integration,
# isn't used: it needs chatbot:* console permissions this account doesn't grant.)

resource "aws_secretsmanager_secret" "slack_webhook" {
  name        = "${var.project}/slack-webhook-url"
  description = "Slack incoming webhook URL of the alerts channel. Value written by the infra workflow."

  # Deleted at once on destroy, so the next apply can recreate the same name.
  recovery_window_in_days = 0
}

data "archive_file" "slack_alerts" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/slack_alerts"
  output_path = "${path.module}/.build/slack_alerts.zip"
  excludes    = ["test_app.py", "__pycache__"]
}

resource "aws_iam_role" "slack_alerts" {
  name = "${var.project}-slack-alerts"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Least privilege: write its own logs, read this one secret. Nothing else.
resource "aws_iam_role_policy" "slack_alerts" {
  name = "slack-alerts"
  role = aws_iam_role.slack_alerts.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.slack_alerts.arn}:*"
      },
      {
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = aws_secretsmanager_secret.slack_webhook.arn
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "slack_alerts" {
  name              = "/aws/lambda/${var.project}-slack-alerts"
  retention_in_days = 14
}

resource "aws_lambda_function" "slack_alerts" {
  function_name    = "${var.project}-slack-alerts"
  role             = aws_iam_role.slack_alerts.arn
  runtime          = "python3.12"
  handler          = "app.handler"
  filename         = data.archive_file.slack_alerts.output_path
  source_code_hash = data.archive_file.slack_alerts.output_base64sha256
  timeout          = 15
  memory_size      = 128

  environment {
    variables = {
      SLACK_SECRET_ARN = aws_secretsmanager_secret.slack_webhook.arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.slack_alerts, aws_iam_role_policy.slack_alerts]
}

# Each environment's alarm topic (dev, prod) invokes the Lambda.
resource "aws_lambda_permission" "slack_alerts" {
  for_each = module.env

  statement_id  = "sns-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.slack_alerts.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = each.value.settings.alerts_topic_arn
}

resource "aws_sns_topic_subscription" "slack_alerts" {
  for_each = module.env

  topic_arn = each.value.settings.alerts_topic_arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.slack_alerts.arn

  depends_on = [aws_lambda_permission.slack_alerts]
}

# Bedrock daily budget (terraform-bootstrap, ADR 0009): AWS Budgets publishes to a topic that
# the bootstrap owns (it is never destroyed); this Lambda subscribes to it once the GitHub
# variable BUDGET_ALERTS_TOPIC_ARN holds its ARN. Empty = no subscription, so this apply
# never depends on the bootstrap having run first.
resource "aws_lambda_permission" "budget_alerts" {
  count = var.budget_alerts_topic_arn == "" ? 0 : 1

  statement_id  = "sns-budget"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.slack_alerts.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = var.budget_alerts_topic_arn
}

resource "aws_sns_topic_subscription" "budget_alerts" {
  count = var.budget_alerts_topic_arn == "" ? 0 : 1

  topic_arn = var.budget_alerts_topic_arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.slack_alerts.arn

  depends_on = [aws_lambda_permission.budget_alerts]
}
