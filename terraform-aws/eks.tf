module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "${var.project}-eks"
  cluster_version = var.cluster_version

  # Public endpoint so GitHub-hosted runners and CloudShell can reach the API.
  cluster_endpoint_public_access = true

  # The identity that runs Terraform (the GitHub Actions role) becomes cluster admin.
  enable_cluster_creator_admin_permissions = true

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.private_subnets

  # Every add-on is pinned to an exact version (DESIGN D-16): never most_recent, so neither an
  # apply nor a new cluster after destroy picks up an untested release (the metrics-server
  # add-on broke /openapi/v2 that way, RUNBOOK section 7). Versions = what ran on 2026-10-16
  # (Kubernetes 1.35). Upgrading one is a reviewed PR: RUNBOOK section 11.
  # Not here: aws-guardduty-agent, installed and updated by GuardDuty runtime monitoring of the
  # account's shared detector (ADR 0003), not by this repo.
  cluster_addons = {
    coredns = {
      addon_version = "v1.14.7-eksbuild.11"
      most_recent   = false
    }
    kube-proxy = {
      addon_version = "v1.35.3-eksbuild.52"
      most_recent   = false
    }
    vpc-cni = {
      addon_version  = "v1.23.2-eksbuild.3"
      most_recent    = false
      before_compute = true
      # Enforce Kubernetes NetworkPolicies (blocks traffic between boutique-dev and boutique-prod).
      # Prefix delegation: each node gets /28 IP blocks instead of single IPs, so a
      # t3.medium runs up to 110 pods instead of 17 (the limit behind "Too many pods").
      # EKS sets the nodes' pod limit from this when the node group is created, so it
      # takes effect on a new cluster (infra destroy + apply) or new nodes.
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
    # No metrics-server add-on: its OpenAPI definitions (metrics.k8s.io v1beta1 and the *_v2
    # apimachinery copies) cannot be converted to protobuf, which made /openapi/v2 answer 503
    # to Argo CD and Helm (RUNBOOK section 7). metrics-server is the upstream Helm chart,
    # installed by deploy-env.yml. Its port 10250 is already open from the cluster security
    # group (the module's kubelet rule), so the old 10251/tcp rule is gone too.
    eks-pod-identity-agent = {
      addon_version  = "v1.4.0-eksbuild.4"
      most_recent    = false
      before_compute = true
    }
    # CloudWatch Container Insights: node/pod metrics and container logs.
    amazon-cloudwatch-observability = {
      addon_version = "v6.7.0-eksbuild.1"
      most_recent   = false
      # Container Insights (node/pod metrics, container logs) stays on. Application
      # Signals auto-monitor is turned off: by default it injects an OpenTelemetry
      # agent into every pod, which made the JVM of adservice too slow to start
      # (killed by its liveness probe) and is billed per request/span.
      configuration_values = jsonencode({
        manager = {
          applicationSignals = {
            autoMonitor = {
              monitorAllServices = false
            }
          }
        }
      })
    }
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.node_instance_types
      min_size       = 2
      max_size       = 5
      desired_size   = var.node_desired_size

      iam_role_additional_policies = {
        CloudWatchAgentServerPolicy = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
      }
    }
  }

  # Optional: your own IAM identity gets kubectl admin access.
  access_entries = {
    for name, arn in { admin = var.admin_principal_arn } : name => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    } if arn != ""
  }
}
