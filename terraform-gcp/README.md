# terraform-gcp

The destroyable GCP side of ADR 0014, the twin of `terraform-aws`. It runs the portable
profile only: 10 services, the loadgenerator and an in-cluster Redis.

| Resource | Why |
|---|---|
| VPC `boutique-gke`, one subnet in `us-east1` | Nodes `10.20.0.0/22`, Pods `10.24.0.0/17`, Services `10.28.0.0/22` (no overlap with the EKS VPC, `10.0.0.0/16`). Private Google Access on (`network.tf`) |
| Cloud NAT | Outbound only, this subnet only: `redis-cart` and the loadgenerator's init container pull from Docker Hub. `cloud_nat = false` once they are mirrored too |
| GKE Autopilot `boutique-gke` | Regional (Autopilot has no zonal option), `REGULAR` channel, private nodes, nodes as the bootstrap's `gke-nodes` service account, control plane closed to all but `control_plane_authorized_cidrs` (empty for now), no deletion protection (`gke.tf`) |
| Artifact Registry `boutique` | Docker, immutable tags, keeps the last 20 builds (60 versions: image, `.sig`, `.att`) like ECR. Target of the `cosign copy` mirror (a later PR) (`registry.tf`) |

**No service accounts or IAM here:** `terraform-gcp-bootstrap` creates them, and the infra-gcp
workflow fails if this root declares any. `gha-deploy` only needs its existing roles.

## Before the first apply

1. **Re-run bootstrap-gcp** (plan, then apply) after this PR is merged. It enables the Compute
   Engine, GKE and Artifact Registry APIs (`gha-deploy` can't) and creates `gke-nodes`.
2. **Add the repository variable `GCP_GKE_NODE_SA`** from the bootstrap output
   (`terraform output -raw GCP_GKE_NODE_SA`).

## Running it

Actions > **infra-gcp** > Run workflow, on `main`:

- **plan:** shows which resources change, never values. First apply: 6 resources (network,
  subnet, router, NAT, cluster, registry).
- **apply:** applies that plan. About 10-15 minutes for the cluster.
- **destroy:** removes everything here, the registry's images included. The bootstrap root
  (federation, state, budget) stays.

Pull requests that touch `terraform-gcp/` get the tests and a plan as `gha-plan`. A merge
applies nothing. State: the bootstrap bucket, prefix `gcp-infra`.

On a laptop, without GCP access: `terraform init -backend=false && terraform test`.

## Cost

An estimate, from list prices, not a quote. Check the
[pricing calculator](https://cloud.google.com/products/calculator) before leaving it up.

- **Cluster fee:** $0.10/hour (about $73/month). It's covered by GKE's free tier credit
  ($74.40/month per billing account), only if this is the billing account's only Autopilot or
  zonal cluster.
- **Pods:** Autopilot bills the Pods' requests, after raising them to its minimums: 50m CPU,
  52 MiB, and at least 1 GiB of memory per vCPU. The profile's requests come to about 1.57 vCPU
  and 1.81 GiB, about **$58/month running all day** (us-central1 rates, $0.0445 per vCPU-hour,
  $0.0049225 per GiB-hour). The loadgenerator is about $11 of that.
- **Cloud NAT:** about $3/month for a few nodes, plus $0.045/GiB processed (image pulls only).
- **Later PRs:** the Ingress's load balancer, roughly $18/month.

That's above the project's **$50/month budget** if left running all month. Destroy it between
uses: 8 hours a day on weekdays is about $15/month.
