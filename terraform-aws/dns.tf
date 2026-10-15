# HTTPS with your own domain (plan §11 "TLS for external traffic").
# Set the GitHub variable DOMAIN_NAME (e.g. example.com) to a public Route 53 hosted
# zone in this account. Empty = no domain: the shop stays on the plain http ALB address.
#
# Terraform creates one ACM certificate for the domain and *.domain (validated through
# DNS records in the zone). The ALBs are created later by Kubernetes, so the deploy
# workflow points the names at them:
#   dev.<domain> -> boutique-dev ALB, shop.<domain> -> boutique-prod ALB,
#   grafana.<domain> -> boutique-monitoring ALB (still limited to MONITORING_ALLOWED_CIDR)
#   argocd.<domain>  -> boutique-argocd ALB (limited to ARGOCD_ALLOWED_CIDR, argocd-install)

locals {
  tls_enabled = var.domain_name != ""
  tls_hosts = {
    dev        = "dev.${var.domain_name}"
    prod       = "shop.${var.domain_name}"
    monitoring = "grafana.${var.domain_name}"
    argocd     = "argocd.${var.domain_name}"
  }
}

data "aws_route53_zone" "main" {
  count        = local.tls_enabled ? 1 : 0
  name         = var.domain_name
  private_zone = false
}

resource "aws_acm_certificate" "main" {
  count                     = local.tls_enabled ? 1 : 0
  domain_name               = var.domain_name
  subject_alternative_names = ["*.${var.domain_name}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# The domain and *.domain share one validation record: allow_overwrite lets both
# entries write it without a conflict.
resource "aws_route53_record" "cert_validation" {
  for_each = local.tls_enabled ? {
    for dvo in aws_acm_certificate.main[0].domain_validation_options : dvo.domain_name => dvo
  } : {}

  zone_id         = data.aws_route53_zone.main[0].zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "main" {
  count                   = local.tls_enabled ? 1 : 0
  certificate_arn         = aws_acm_certificate.main[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}
