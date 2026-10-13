output "region" {
  value = var.region
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "vpc_id" {
  description = "Passed to the AWS Load Balancer Controller Helm chart."
  value       = module.vpc.vpc_id
}

output "vpc_cidr" {
  description = "Allowed into the frontend pods (the ALB sends traffic from inside the VPC)."
  value       = module.vpc.vpc_cidr_block
}

output "ecr_registry" {
  description = "Helm value images.repository (registry + prefix)."
  value       = "${split("/", aws_ecr_repository.svc["frontend"].repository_url)[0]}/${var.ecr_prefix}"
}

output "environments" {
  description = "Per-environment settings for the Helm values: terraform output -json environments"
  value       = { for name, env in module.env : name => env.settings }
}

output "redis_auth_tokens" {
  description = "Redis auth token per environment, read by the deploy workflow (never printed)."
  value       = { for name, env in module.env : name => env.redis_auth_token }
  sensitive   = true
}

output "slack_webhook_secret_arn" {
  description = "Secrets Manager secret the infra workflow writes the Slack webhook URL into (read by the slack-alerts Lambda)."
  value       = aws_secretsmanager_secret.slack_webhook.arn
}

output "tls" {
  description = "HTTPS settings read by the deploy workflow (null when no domain is set)."
  value = local.tls_enabled ? {
    domain          = var.domain_name
    certificate_arn = aws_acm_certificate_validation.main[0].certificate_arn
    zone_id         = data.aws_route53_zone.main[0].zone_id
    hosts           = local.tls_hosts
  } : null
}

output "ses" {
  description = "Order emails (emailservice): sender and the verified recipients (null without a domain)."
  value = local.ses_enabled ? {
    from_address = local.ses_from
    recipients   = sort(tolist(local.ses_recipients))
  } : null
}

output "argocd_repo_key_secret_arn" {
  description = "Secrets Manager secret holding Argo CD's deploy key (read by the argocd-install workflow)."
  value       = aws_secretsmanager_secret.argocd_repo_key.arn
}
