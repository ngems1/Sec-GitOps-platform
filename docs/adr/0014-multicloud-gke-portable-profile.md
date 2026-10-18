# 0014: A second cluster on GKE, deployed by the same Argo CD (Phase 6, part 1)

Status: proposed. Date: 2026-10-18. Docs only: nothing is implemented by this ADR.

## Context

- **Today:** one EKS cluster runs everything. Argo CD (namespace `argocd`, chart `argo-cd` 10.9.2,
  Argo CD v3.5.3, installed by the `argocd-install` workflow through `deploy/argocd.sh`) deploys
  two Applications from this repository:
  - `boutique-dev` from `main`;
  - `boutique-prod` from the `env/prod` promotion branch (ADR 0007).

  Both use project `boutique`, whose only destinations are the local cluster
  (`https://kubernetes.default.svc`), `boutique-dev` and `boutique-prod`, with no cluster-scoped
  objects. No other cluster is registered, and there is no ApplicationSet. Argo CD reads the
  repository with a read-only deploy key from Secrets Manager.
- **The chart is AWS-bound only through its values:**
  - `values-aws.yaml` adds the ALB Ingress, the Argo Rollouts canary through the ALB (ADR 0008),
    ElastiCache Redis with TLS, and `inventoryservice`;
  - the deploy workflow fills `gitops/<env>/values.yaml` with Terraform names: RDS for the
    catalog and the orders, EventBridge, SQS, DynamoDB, SES, Pod Identity.
- **The base `values.yaml` is stock Online Boutique:** the catalog from `products.json`, carts in
  an in-cluster Redis, no orders database, no notification consumer, no `inventoryservice`, no
  assistant.
- **Keyless everywhere:**
  - GitHub reaches AWS only through OIDC roles (`terraform-bootstrap`);
  - images are signed keyless (ADR 0012);
  - Kyverno audits the signatures on EKS (ADR 0013).
- **The roadmap** lists Phase 6 as "Azure AKS, optionally GCP GKE". This ADR starts with GKE; AKS
  is still open (see "Revisit when").

## Decisions

### 1. Scope: a portable profile on GKE, the rest stays EKS-only

- **GKE runs the stock profile:** the base `values.yaml` plus a new `values-gcp.yaml` (GKE
  Ingress, no canary, guardrails, NetworkPolicies, seccomp). That is:
  - 10 services: ad, cart, checkout, currency, email, frontend, payment, catalog, recommendation,
    shipping;
  - the loadgenerator;
  - an in-cluster `redis-cart`.
- **On EKS only, on purpose, for this phase:**
  - the shopping assistant (Bedrock, ADR 0009);
  - `inventoryservice` and the whole async order flow (EventBridge, SQS, the order-status Lambda,
    the email consumer, DynamoDB, SES);
  - the RDS catalog and orders;
  - the frontend canary (it is an ALB feature in this repo);
  - tracing, Prometheus and Grafana;
  - Kyverno.
- **What that means for GKE:**
  - checkout completes an order, but nothing is stored or emailed;
  - carts live in the pod's Redis;
  - there is no assistant link.
- **Why:**
  - those parts need GCP equivalents (Pub/Sub, Cloud SQL, Vertex AI...), or calls back into AWS
    with cross-cloud credentials. Each is a decision of its own;
  - the stock profile already exists and is tested: it is what `values.yaml` renders today
    without `values-aws.yaml`.
- **Note:** "the 12 services" in the plan include the assistant and `inventoryservice`, so the
  portable profile is 10 services, not 12.
- **Alternatives:**
  - the full app on GKE with cross-cloud calls to AWS (latency, egress, and AWS credentials in
    GKE);
  - GCP-native ports of the async flow now (too much for a first pass).

### 2. GitHub Actions to GCP: Workload Identity Federation, no keys

- **The provider:** one workload identity pool with a GitHub OIDC provider
  (`https://token.actions.githubusercontent.com`). Its attribute condition admits only this
  repository by its immutable IDs (`repository_id`, `repository_owner_id`), like the AWS trust
  in `terraform-bootstrap/main.tf`.
- **Two service accounts, mirroring the AWS roles:**
  - `gha-plan`: read-only, pull requests;
  - `gha-deploy`: apply and deploy, only from `main` or the protected `dev`/`prod`
    environments.
- **No keys:** no service account key exists anywhere, and the organization or project policy
  `iam.disableServiceAccountKeyCreation` is enforced.
- **In workflows:** `google-github-actions/auth` with `workload_identity_provider` and
  `service_account`, and `id-token: write` (already granted in the deploy workflows).
- **Why:** the same model as AWS OIDC and cosign keyless. Nothing to rotate, and nothing to
  leak in a public repository.
- **Alternatives:** a JSON key in a GitHub secret (rejected: long-lived, exfiltratable); direct
  principal access without service accounts (fewer moving parts, but GKE RBAC and some APIs
  still expect a service account; revisit later).

### 3. Two Terraform roots: `terraform-gcp-bootstrap` and `terraform-gcp`

- **`terraform-gcp-bootstrap`** (rarely changed, never destroyed), like `terraform-bootstrap` for
  AWS:
  - the APIs to enable;
  - the GCS state bucket (versioned, uniform access, public access prevention);
  - the workload identity pool and provider, and the two service accounts with their IAM
    bindings;
  - the project-level IAM and policies, and the billing budget (decision 7).
  - **First run:** by a person with project-owner rights and `gcloud`, starting with local
    state, then moved into the bucket. That's the same pattern as the AWS bootstrap
    (BOOTSTRAP.md).
- **`terraform-gcp`** (destroyable, like `terraform-aws`): the VPC and subnet, Cloud NAT if
  needed, the GKE cluster, the Artifact Registry repository (decision 5), the global static IP of
  the Ingress, and the IAM for Argo CD (decision 4). Its own `infra-gcp` workflow does plans on
  pull requests, and plan, apply or destroy by hand from `main` (a merge applies nothing).
- **Why:** destroying the cluster to save money must never remove the way back in (the
  federation, the state bucket) or the budget alarms.
- **Alternatives:** one root (a destroy removes the login path); a GCP module inside
  `terraform-aws` (mixes two providers' blast radius and state).

### 4. Argo CD reaches GKE without a static token

- **Mechanism:** Kubernetes-to-GCP federation from EKS.
  1. A second workload identity pool provider trusts the EKS cluster's OIDC issuer. EKS
     publishes it at a public URL.
  2. Argo CD's `argocd-application-controller` (and `argocd-server`, for the UI's live view)
     get a projected service-account token with that provider as audience. A credential
     configuration file (`external_account`, `credential_source.file`) points Google's default
     credentials at it.
  3. The provider's condition admits only
     `system:serviceaccount:argocd:argocd-application-controller` and
     `system:serviceaccount:argocd:argocd-server`, on this cluster's issuer.
  4. They impersonate a GCP service account `argocd-hub`, which holds
     `roles/container.clusterViewer` on the GKE cluster. Inside GKE, Kubernetes RBAC gives that
     identity only what the shop needs, in namespace `boutique-gke` (no cluster-admin).
  5. The Argo CD cluster Secret (`argocd.argoproj.io/secret-type: cluster`) holds the API
     server URL, its CA (public) and an `execProviderConfig` running `argocd-k8s-auth gcp`. It
     holds no token; tokens are minted on demand and last an hour. A workflow writes it from
     the `terraform-gcp` outputs, like the repository credential.
- **Argo CD side:**
  - a new project `boutique-gcp`, with destination GKE / `boutique-gke` only and no
    cluster-scoped objects;
  - an Application `boutique-gke` from `main`: `values.yaml`, `values-gcp.yaml` and
    `gitops/gke/values.yaml` (image tag and registry, written by the deploy workflow like
    dev's).
- **Network:** the GKE control plane keeps its public endpoint, restricted with authorized
  networks to the EKS NAT gateway's egress IPs (plus the GitHub runners while bootstrapping).
- **To verify in the implementation PR:** `argocd-k8s-auth gcp` with an `external_account` file
  credential, end to end. The fallback is the same federation with `gke-gcloud-auth-plugin` as
  the exec provider.
- **As implemented (2026-10-18, argocd-gke):**
  - `argocd-k8s-auth gcp` (v3.5.3) only calls Google's Application Default Credentials, which
    read an `external_account` file (golang.org/x/oauth2 v0.36.0). The credential path is
    unchanged; the IAM role and the endpoint differ from the plan above:
  - **The control plane:** the DNS-based endpoint instead of authorized networks. The EKS NAT
    address changes with every terraform-aws rebuild, and the DNS endpoint has a Google-signed
    certificate, so there's no CA in the cluster Secret.
  - **The IAM role:** that endpoint needs `container.clusters.connect`, which
    `roles/container.clusterViewer` doesn't hold. `argocd-hub` gets a custom role with
    `container.clusters.get` and `container.clusters.connect` only. All Kubernetes access is
    RBAC.
  - **The issuer changes with every EKS rebuild:** it comes from the GitHub variable
    `EKS_OIDC_ISSUER`, and bootstrap-gcp is re-run after a rebuild
    (`terraform-gcp-bootstrap/README.md`).
  - **Proof of the connection:** Argo CD reports a cluster that no Application uses as
    "Unknown". A throwaway probe Application with nothing to deploy got Argo CD's own status
    until the real one existed. It was removed with the portable profile (below).
- **The portable profile, as implemented (ops/gke-portable-profile):**
  - **What deploys it:** Application `boutique-gke` (project `boutique-gcp`,
    `deploy/argocd/gke/`): `helm-chart` with `values-gcp.yaml` and `gitops/gke/values.yaml`, plain
    automated sync, no canary. `deploy/argocd-gke.sh` creates the namespace, `argocd-hub`'s Role
    there and the PriorityClass as `gha-deploy`; Argo CD gets nothing cluster-wide.
  - **Images:** all from the Artifact Registry mirror, redis and busybox included (chart
    values, defaults unchanged for EKS). The registry path is an Application parameter, outside
    Git (it holds the project ID).
  - **The tag in `gitops/gke/values.yaml` is set by hand after each mirror-images-gcp run** (no
    automatic update yet).
  - **Nothing is public:** no Ingress or LoadBalancer. It's checked through a port-forward. The
    `gke.` name, its certificate and the load balancer are a later decision.
  - **Cloud NAT stays** until a real run shows no pod pulls from outside Artifact Registry
    (`argocd-gke` reports it).
- **Why:** no long-lived kubeconfig or service-account token exists to steal. Access is revoked
  by removing one IAM binding.
- **Alternatives:**
  - a long-lived Kubernetes service-account token in the cluster Secret (rejected);
  - a second Argo CD on GKE (simpler auth, but two control planes to keep in sync, against the
    hub pattern);
  - Connect Gateway / Fleet (Google-managed proxy, more GCP surface; a later option).

### 5. Images: mirror the signed ECR images to Artifact Registry

- **What:** after `build` signs and verifies an image (ADR 0012), a new deploy step copies it by
  digest, with its `.sig` and `.att`, to Artifact Registry
  (`<region>-docker.pkg.dev/<project>/boutique/<service>`): `cosign copy`, through workload
  identity federation.
- **The digest is unchanged, so the signatures stay valid.** The same identity, issuer and SBOM
  type verify in both registries; `cosign verify` and the rollback signing (`sign-rollback`)
  check the mirror too.
- **The repository:** tags immutable, cleanup policies matching the ECR rule (about 20 builds).
- **GKE pulls from Artifact Registry with its node service account** (reader on that repository
  only). No AWS credential is ever in GKE.
- **When Kyverno comes to GKE:** the same policy file with `${ECR_REGISTRY}` replaced by the
  Artifact Registry path, and `credentials.providers: [google]`.
- **Why:** GKE's ability to start pods doesn't depend on ECR or on AWS credentials in GCP, the
  pulls stay inside Google's network (no ECR internet egress per pull), and one signing
  identity covers both.
- **Alternatives:** cross-cloud pull from ECR (rejected: ECR tokens expire every 12 hours, so
  GKE would need an AWS identity and a token refresher; AWS egress on every pull; an AWS outage
  stops GKE scaling); building twice (two different digests, double signing).

### 6. DNS: a separate name in Route 53, no failover yet

- **The name:** `gke.<domain>` in the existing Route 53 zone, an A record to the GKE Ingress's
  global static IP. The deploy workflow writes it with `deploy/dns-record.sh` (an A-record mode
  added there), like `dev.` and `shop.`, so no `terraform-aws` change.
- **TLS:** a Google-managed certificate (ManagedCertificate) for `gke.<domain>`. The ACM
  wildcard can't leave AWS.
- **No traffic sharing:** `shop.<domain>` keeps going only to EKS prod. Weighted or failover
  routing between clouds is a later decision: it needs the same data on both sides, which the
  portable profile doesn't have.
- **Alternatives:** Cloud DNS for a delegated subdomain (two DNS providers for no gain now);
  failover now (rejected: the two sides serve different features and data).

### 7. Cost: GKE Autopilot, with its own budget

- **Autopilot:** pay for the pods' requests, with no nodes to size, patch or scale. That suits
  about 12 small pods that may be destroyed nightly.
  - Hardened defaults: Workload Identity, Shielded nodes, Dataplane V2, which enforces the
    chart's NetworkPolicies.
  - One zonal or Autopilot cluster fee is covered by GKE's free tier credit.
  - Autopilot raises small requests to its minimums (50m CPU per pod today). So expect a few
    tens of USD a month running all day, plus the load balancer; check the pricing calculator
    in the implementation PR.
- **Budget:** a Cloud Billing budget on the project (`terraform-gcp-bootstrap`), alerting at 50%
  and 100%. It goes to email first, then to `#boutique-alerts` through Pub/Sub, like the AWS
  Budgets for Bedrock (`terraform-bootstrap/budgets.tf`).
  - Labels on the cluster and node resources (`project=week3-boutique`, `env=gke`).
- **Alternatives:** Standard with one small node pool (cheaper per vCPU at scale, but node
  management and idle capacity); Standard with Spot nodes (cheaper still, with evictions; later,
  for the loadgenerator).

## Consequences

- **A second cloud account to secure and pay for.** Every access is keyless (WIF for GitHub,
  Kubernetes-to-GCP federation for Argo CD), and nothing in either cloud holds a static
  credential for the other.
- **The EKS cluster is the hub.**
  - If EKS or its Argo CD is down, GKE keeps serving what it runs, but nothing new reaches it.
  - Destroying `terraform-aws` stops GKE deployments too.
- **The GKE environment is visibly smaller:** no assistant, no order history, no emails, no
  canary, no traces. It is a demo of portability, not a second prod.
- **New workflow pieces:**
  - `infra-gcp`;
  - an Argo CD cluster registration step in `argocd-install`;
  - the Artifact Registry copy in `deploy`;
  - the `gke.` DNS record.

  CI must render the GCP profile (`values.yaml` + `values-gcp.yaml`) like it renders dev and
  prod.

## Implementation order (each a small PR)

1. `terraform-gcp-bootstrap`: APIs, state bucket, WIF for GitHub, service accounts, budget.
2. `terraform-gcp` and `infra-gcp`: VPC, Autopilot cluster, Artifact Registry, static IP.
3. Images: the `cosign copy` mirror step in `deploy` (and in `sign-rollback`).
4. Chart: `values-gcp.yaml`, with CI rendering it. Check the chart without Argo Rollouts CRDs
   (canary off) and with Dataplane V2 NetworkPolicies.
5. Argo CD: the EKS-issuer federation, the cluster Secret, project `boutique-gcp`, Application
   `boutique-gke`, and the `gke.` record with its certificate.
6. Operations: a cluster-status equivalent for GKE, and the RUNBOOK section.

## Revisit when

- The async flow or the assistant must run on GKE: GCP equivalents (Pub/Sub, Cloud SQL, Vertex
  AI) or cross-cloud calls, each with its own ADR.
- Traffic should be shared or failed over between clouds: data replication first.
- Observability across clouds (ADR 0010 and ADR 0011: a collector per cluster, a central Tempo,
  one log view).
- Kyverno on GKE (decision 5 covers its registry).
- AKS, the roadmap's other Phase 6 target: the same hub pattern with Microsoft Entra workload
  identity federation.
