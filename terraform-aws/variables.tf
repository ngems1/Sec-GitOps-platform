variable "region" {
  description = "AWS region for every resource."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Name prefix used for all resources."
  type        = string
  default     = "week3-boutique"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "cluster_version" {
  description = "EKS Kubernetes version. Use a version in STANDARD support (check the EKS console); older versions cost 6x more."
  type        = string
  default     = "1.35"
}

variable "node_instance_types" {
  description = "EC2 instance types for the managed node group."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_desired_size" {
  description = "Number of worker nodes. With VPC CNI prefix delegation (eks.tf) a t3.medium runs up to 110 pods, so CPU/memory, not the pod count, is the limit: 4 nodes fit both environments with autoscaling, monitoring and a load test."
  type        = number
  default     = 4
}

variable "admin_principal_arn" {
  description = "Your IAM user or role ARN, given cluster-admin so you can run kubectl from CloudShell. Empty = skip."
  type        = string
  default     = ""
}

variable "db_instance_class" {
  description = "RDS MySQL instance size for both environments (prod adds a Multi-AZ standby)."
  type        = string
  # db.t3.micro (Intel): AWS had no Multi-AZ capacity for db.t4g.micro (Graviton)
  # in us-east-1 on 2026-10-03 (InsufficientDBInstanceCapacity). Same size and price.
  default = "db.t3.micro"
}

variable "ecr_prefix" {
  description = "ECR repositories are created as <ecr_prefix>/<service>."
  type        = string
  default     = "boutique"
}

variable "services" {
  description = "Online Boutique services that get an ECR repository."
  type        = list(string)
  default = [
    "adservice",
    "cartservice",
    "checkoutservice",
    "currencyservice",
    "emailservice",
    "frontend",
    "inventoryservice",
    "loadgenerator",
    "paymentservice",
    "productcatalogservice",
    "recommendationservice",
    "shippingservice",
  ]
}

variable "lbc_version" {
  description = "AWS Load Balancer Controller release whose IAM policy is used. Keep in step with the Helm chart version in the deploy workflow."
  type        = string
  default     = "v2.13.0"
}

variable "domain_name" {
  description = "Public Route 53 hosted zone in this account for HTTPS (dev./shop./grafana.<domain>). Empty = plain http ALB addresses. Set through the GitHub variable DOMAIN_NAME."
  type        = string
  default     = ""
}

variable "ses_recipients" {
  description = "SES sandbox: comma-separated addresses allowed to receive order emails (each gets a verification link from AWS). Set through the GitHub variable SES_RECIPIENTS. Needs domain_name."
  type        = string
  default     = ""
}

variable "guardduty_alert_min_severity" {
  description = "GuardDuty findings at or above this severity go to Slack (7 = high, 9 = critical; the detector is a shared account service, not managed here)."
  type        = number
  default     = 7
}
