# Slack notifications

Two kinds of messages, in **two separate channels**, each with its own incoming webhook:

| Channel | What | From | GitHub secret |
|---|---|---|---|
| `#boutique-deploys` | **Pipeline:** build, dev deployed, prod waiting for approval, prod deployed, isolation test, infra apply/destroy | GitHub Actions, `deploy/notify-slack.sh` | `SLACK_WEBHOOK_URL` |
| `#boutique-alerts` | **AWS alarms** (dev and prod): a dead-letter queue has messages, a queue is backing up, the order-status Lambda fails; **GuardDuty findings** with severity >= 7 | CloudWatch → SNS → `slack-alerts` Lambda (`terraform-aws/slack.tf`); GuardDuty → EventBridge → the same Lambda (`terraform-aws/security-alerts.tf`) | `SLACK_ALERTS_WEBHOOK_URL` |

Both are optional. Until a secret is set, its messages aren't sent and nothing fails.

## 1. Create the channels and webhooks (10 minutes)

1. Slack: create two channels, `#boutique-deploys` and `#boutique-alerts`. In `#boutique-alerts`, click the channel name → **Notifications → All new messages**, so alarms reach your phone.
2. Go to **api.slack.com/apps → Create New App → From scratch**, give it a name (e.g. `Boutique Bot`) and pick your workspace.
3. **Incoming Webhooks** → **On** → **Add New Webhook** → choose `#boutique-deploys` → **Allow**. Copy the URL.
4. **Add New Webhook** again → choose `#boutique-alerts` → **Allow**. Copy that second URL.
5. GitHub: **Settings → Secrets and variables → Actions → Secrets → New repository secret**, twice:
   - `SLACK_WEBHOOK_URL` = the `#boutique-deploys` URL
   - `SLACK_ALERTS_WEBHOOK_URL` = the `#boutique-alerts` URL

The URLs are secrets: anyone with one can post to that channel. If one leaks, remove it on the app's Incoming Webhooks page and add a new one.

## 2. How the alarms reach `#boutique-alerts`

```
CloudWatch alarm -> SNS topic (dev / prod) -> week3-boutique-slack-alerts Lambda -> Slack
```

- Terraform creates the Lambda, an **empty** Secrets Manager secret `week3-boutique/slack-webhook-url`, and subscribes the Lambda to both environments' alarm topics.
- After every `infra` apply, the workflow step **Store the Slack webhook for alarms** copies the `SLACK_ALERTS_WEBHOOK_URL` GitHub secret into that Secrets Manager secret (only when it changed). The URL is never in the code, the Terraform state or the Lambda's settings.
- So: set the GitHub secret, run **infra → apply** once (or merge any Terraform change). It keeps working after every destroy / apply.

Messages: :red_circle: **ALARM** when an alarm fires, :large_green_circle: **OK** when it recovers, with the environment, the reason and a link to the alarm in CloudWatch.

| Alarm | Fires when |
|---|---|
| `week3-boutique-<env>-<flow>-dlq-not-empty` | A message failed 3 times and is in a dead-letter queue |
| `week3-boutique-<env>-<flow>-backlog` | A queue is backing up |
| `week3-boutique-<env>-order-status-lambda-errors` | The order-status Lambda itself crashes (timeout, out of memory, bad deployment). A message it can't process is not a crash: it is reported back to SQS, retried, and ends in the DLQ (alarm above) |

Why not Amazon Q Developer in chat applications (AWS Chatbot)? Its one-time Slack authorization needs `chatbot:*` permissions in the console, which this account's IAM user doesn't have. The Lambda route needs only what the pipeline already has.

### Test an alarm (console only)

Send an order that doesn't exist: **EventBridge → Event buses → Send events**, bus `week3-boutique-dev-events`, source `boutique.checkout`, detail type `OrderCreated`, detail:

```json
{"version":"1","orderId":"console-test-001","email":"someone@example.com","items":[{"productId":"OLJCESPC7Z","quantity":1}]}
```

inventoryservice reserves it, the order-status Lambda can't find it in MySQL and fails 3 times, the message lands in `week3-boutique-dev-order-status-dlq`. `#boutique-alerts` then shows **ALARM** for `...-order-status-dlq-not-empty`. Expect **5 to 15 minutes**: 3 attempts 60 s apart, then SQS starts publishing metrics for a queue that was idle (it pauses them after 6 idle hours), then the alarm evaluates.

Clean up: **SQS → order-status-dlq → Purge** (the alarm goes back to OK and Slack shows it), then in DynamoDB set `PRODUCT#OLJCESPC7Z` stock back and delete `RESERVATION#console-test-001`.

If nothing arrives: **Lambda → week3-boutique-slack-alerts → Monitor → View CloudWatch logs**. `no Slack webhook stored` means the `SLACK_ALERTS_WEBHOOK_URL` secret is missing or infra wasn't applied after adding it.

## Security notes

- The webhook URLs are stored as GitHub **secrets**, never in the code.
- The `slack-alerts` Lambda's role can only write its own logs and read that one secret. The webhook URL is copied into Secrets Manager by the workflow, so it is never in the Terraform state.
- A Slack failure never fails a deployment (`notify-slack.sh` always exits 0).

## Order notifications in Slack (#boutique-orders)

emailservice handles every final order status (CONFIRMED / FAILED, from notification-q).
Besides the email (log mode) and the DynamoDB notifications row, it can post one line per
order to a third channel:

> :white_check_mark: Order `7a42cfc3` confirmed [dev]: 2 product(s) reserved, ready to ship.
> :x: Order `52d8abb4` failed [dev]: out of stock. Customer notified, payment refunded.

Setup (once):
1. Slack: create the channel `#boutique-orders`, then in the Slack app
   *Boutique-Microservice* > Incoming Webhooks > **Add New Webhook** > `#boutique-orders`.
2. GitHub: repository secret **`SLACK_ORDERS_WEBHOOK_URL`** = that webhook URL.
3. Run deploy: the workflow stores it as the Kubernetes Secret `emailservice-slack`.

Safeguards: posted after the duplicate check (a repeated event never posts twice), at most
one message every 5 seconds (a load test places thousands of orders: the next message
says how many were not shown), and a Slack error never blocks or fails an order.
Remove the GitHub secret to switch it off.
