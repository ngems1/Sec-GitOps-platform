# Retention of the Container Insights log groups (ADR 0011, PR 2).
#
# The EKS add-on amazon-cloudwatch-observability (eks.tf) creates these groups the first time it
# ships a line, with no retention: nothing ever expired. Terraform now manages them:
#
#   application  container stdout of every namespace (what Grafana's CloudWatch Logs reads)
#   dataplane    kubelet, container runtime and kube-proxy logs on the nodes
#   host         the nodes' system logs (/var/log/messages, secure, dmesg)
#   performance  Container Insights metrics as embedded-metric logs. The metrics are extracted
#                at ingestion, so retention doesn't shorten the metrics' own history.
#
# application is at 1 day on purpose, for now: it still holds lines with personal data written
# before fix/no-pii-in-logs (emails, session IDs, card data). CloudWatch deletes events past
# their retention, usually within 72 hours. A follow-up PR sets 14 days.
#
# The other log groups already have a retention in Terraform: the Lambdas' (14 days,
# modules/environment/lambda.tf, slack.tf) and the EKS control plane's (the EKS module's
# default, 90 days: audit, api and authenticator logs).

locals {
  container_insights_prefix = "/aws/containerinsights/${var.project}-eks" # = module.eks.cluster_name
  container_insights_retention = {
    application = 1 # purge of the pre-fix lines; 14 in the follow-up PR
    dataplane   = 14
    host        = 14
    performance = 7
  }
}

# Adopt the groups the add-on already created (it creates them on first use, so on a new
# account or before the add-on has run there is nothing to import, and Terraform creates them).
data "aws_cloudwatch_log_groups" "container_insights" {
  log_group_name_prefix = "${local.container_insights_prefix}/"
}

import {
  for_each = {
    for k in keys(local.container_insights_retention) : k => "${local.container_insights_prefix}/${k}"
    if contains(data.aws_cloudwatch_log_groups.container_insights.log_group_names, "${local.container_insights_prefix}/${k}")
  }
  to = aws_cloudwatch_log_group.container_insights[each.key]
  id = each.value
}

resource "aws_cloudwatch_log_group" "container_insights" {
  for_each          = local.container_insights_retention
  name              = "${local.container_insights_prefix}/${each.key}"
  retention_in_days = each.value

  # An infra destroy leaves the groups (and their lines, until retention removes them) and
  # only forgets them: the logs outlive the cluster (ADR 0011), as before. The next apply adopts
  # them again through the import above.
  skip_destroy = true
}
