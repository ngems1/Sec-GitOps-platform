# dev and prod share the VPC and the EKS cluster, and get everything else
# separately: database, Redis, DynamoDB tables, event bus, queues, Lambda, IAM roles.

locals {
  environments = {
    dev = {
      db_multi_az              = false
      db_backup_retention_days = 1
    }
    prod = {
      db_multi_az              = true # standby in a second AZ, automatic failover
      db_backup_retention_days = 7
    }
  }
}

module "env" {
  source   = "./modules/environment"
  for_each = local.environments

  env         = each.key
  name_prefix = "${var.project}-${each.key}"
  namespace   = "boutique-${each.key}"

  cluster_name       = module.eks.cluster_name
  vpc_id             = module.vpc.vpc_id
  vpc_cidr           = var.vpc_cidr
  private_subnet_ids = module.vpc.private_subnets

  db_instance_class        = var.db_instance_class
  db_multi_az              = each.value.db_multi_az
  db_backup_retention_days = each.value.db_backup_retention_days

  lambda_source_dir = "${path.module}/lambda/order_status"

  # Order emails (ses.tf): emailservice may send as this address only.
  ses_from_address  = local.ses_from
  ses_identity_arns = concat(aws_sesv2_email_identity.domain[*].arn, [for r in aws_sesv2_email_identity.recipient : r.arn])

  # AI shopping assistant (ADR 0009): its role may invoke this one Bedrock model only.
  shopping_assistant = {
    model_id              = var.shopping_assistant_model_id
    use_inference_profile = var.shopping_assistant_use_inference_profile
    region                = var.region
    account_id            = data.aws_caller_identity.current.account_id
  }
}
