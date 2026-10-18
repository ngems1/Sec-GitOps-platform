# The project's monthly budget (ADR 0014, decision 7), like the Bedrock budget in
# terraform-bootstrap/budgets.tf: here, so it outlives terraform-gcp. It only alerts (Cloud
# Billing updates the spend a few times a day), it never stops spending.
#
# Alerts at 50% and 100% of the actual spend go by email to the billing account's
# administrators and users (the default recipients): no address in the repository. Slack
# (Pub/Sub -> #boutique-alerts) can come later, like the AWS budget's SNS topic.

resource "google_billing_budget" "project" {
  billing_account = var.billing_account_id
  display_name    = "week3-boutique ${var.project_id} monthly"

  budget_filter {
    projects               = ["projects/${data.google_project.this.number}"]
    calendar_period        = "MONTH"
    credit_types_treatment = "INCLUDE_ALL_CREDITS"
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(floor(var.monthly_budget_usd))
      nanos         = floor((var.monthly_budget_usd - floor(var.monthly_budget_usd)) * 1000000000)
    }
  }

  threshold_rules {
    threshold_percent = 0.5
    spend_basis       = "CURRENT_SPEND"
  }
  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "CURRENT_SPEND"
  }

  # No all_updates_rule: with none, Cloud Billing emails the billing account's admins and users
  # at each threshold. A rule is only needed for Pub/Sub or Monitoring channels (Slack, later).

  depends_on = [google_project_service.apis]
}

# Re-runs from the workflow manage the budget as gha-bootstrap: it needs Billing Account Costs
# Manager on the billing account. Granted here on the first run (a billing account
# administrator runs it, README.md).
resource "google_billing_account_iam_member" "bootstrap_budgets" {
  count = var.grant_bootstrap_billing ? 1 : 0

  billing_account_id = var.billing_account_id
  role               = "roles/billing.costsManager"
  member             = google_service_account.gha["bootstrap"].member
}
