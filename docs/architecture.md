# Architecture

A deep-dive companion to the [README](../README.md). It describes the platform as a secure
GitOps **hub-and-spoke**: Amazon EKS is the hub, GKE Autopilot is a governed portable spoke.
Decisions are in [docs/adr/](adr/), notably [0012](adr/0012-image-signing-sbom.md) (SBOM and
signing), [0013](adr/0013-kyverno-image-signatures-audit.md) (Kyverno audit) and
[0014](adr/0014-multicloud-gke-portable-profile.md) (EKS hub, GKE spoke).

- **EKS (hub):** GitHub Actions automation, the Argo CD control plane, the dev and prod
  workloads, the primary observability stack, and the AWS data and event services.
- **GKE Autopilot (spoke):** managed from Argo CD on EKS through keyless EKS-to-GCP federation.
  It runs signed images mirrored from ECR to Artifact Registry.
- **GKE is not active-active production failover today.** It intentionally excludes the
  AWS-specific data and event plane (RDS, EventBridge, SQS, DynamoDB, SES, the order-status
  Lambda), the Bedrock shopping assistant, the inventory flow, the EKS canary implementation
  (an ALB feature here) and the central EKS monitoring stack.

## 1. Platform lifecycle

Every change follows the same loop, from a pull request to self-healing in the cluster.

```mermaid
flowchart LR
    V["Validate<br/>tests, CodeQL, gitleaks,<br/>Checkov, Helm render"] --> A["Approve<br/>PR review,<br/>protected main"]
    A --> B["Build<br/>immutable SHA-tagged<br/>images"]
    B --> S["Scan and sign<br/>ECR scan gate, SBOM,<br/>cosign keyless"]
    S --> D["Deploy progressively<br/>dev, canary, approval,<br/>prod"]
    D --> O["Observe<br/>metrics, traces,<br/>logs, alarms"]
    O --> R["Roll back or self-heal<br/>probes, Argo CD,<br/>canary abort"]
    R -. "fix via a new PR" .-> V
```

## 2. Hub-and-spoke topology

```mermaid
flowchart TB
    user(("Users")) --> ingress

    subgraph GH["GitHub"]
        repo["Repository<br/>main, env/prod"]
        gha["GitHub Actions"]
    end

    gha -- "OIDC token" --> aws_sts["AWS STS<br/>(OIDC roles)"]
    gha -- "OIDC token" --> gcp_wif["GCP Workload Identity<br/>Federation"]

    subgraph AWS["AWS: hub"]
        ecr["ECR<br/>boutique/*"]
        subgraph EKS["EKS cluster"]
            argo["Argo CD<br/>+ Argo Rollouts"]
            subgraph apps["Workloads"]
                dev["namespace boutique-dev"]
                prod["namespace boutique-prod"]
            end
            mon["Monitoring<br/>Prometheus, Grafana,<br/>Tempo, OTel Collector"]
            kyv["Kyverno (audit)"]
        end
        core["Core AWS services<br/>RDS, ElastiCache Redis, DynamoDB,<br/>EventBridge, SQS, Lambda, SES,<br/>Bedrock, CloudWatch"]
        ingress["ALB ingress<br/>HTTPS, Route 53, ACM"]
    end

    subgraph GCP["GCP: portable spoke"]
        ar["Artifact Registry"]
        gke["GKE Autopilot<br/>portable profile"]
        gingress["GKE Ingress<br/>gke.&lt;domain&gt;"]
    end

    repo -- "desired state" --> argo
    aws_sts --> ecr
    gha -- "build, push" --> ecr
    argo --> dev
    argo --> prod
    argo -- "keyless federation" --> gke
    ecr -- "mirror signed images" --> ar
    gcp_wif --> ar
    ar --> gke
    apps --> core
    apps -- "telemetry" --> mon
    ingress --> apps
    gingress --> gke
    user --> gingress
```

## 3. Secure software supply chain

Nothing is signed with a long-lived key; the signing identity is the `deploy.yml` workflow on
`main` (ADR 0012).

```mermaid
flowchart LR
    pr["Pull request"] --> ci["CI checks<br/>unit tests, CodeQL,<br/>gitleaks, Checkov"]
    ci --> merge["Merge to main"]
    merge --> build["Build image<br/>tag = commit SHA<br/>(IMMUTABLE)"]
    build --> ecr["Push to ECR<br/>scan on push"]
    ecr --> gate{"ECR vulnerability gate<br/>CRITICAL = stop"}
    gate -- "fail" --> stop["Deploy stopped"]
    gate -- "pass" --> digest["Resolve digest"]
    digest --> sbom["Syft<br/>SPDX SBOM"]
    sbom --> sign["cosign keyless<br/>sign + attest SBOM<br/>(Fulcio, Rekor)"]
    sign --> verify["cosign verify and<br/>verify-attestation<br/>(same job)"]
    verify --> deploy["Deploy"]
    deploy --> kyv["Kyverno audit<br/>reports unsigned images,<br/>does not block"]
```

## 4. Identity and trust boundaries

There are no static cloud access keys and no static Kubernetes tokens.

```mermaid
flowchart TB
    subgraph GH["GitHub (trust root for CI)"]
        oidc["GitHub OIDC token<br/>repo + ref claims"]
    end

    subgraph AWSB["AWS trust boundary"]
        plan["Plan role<br/>read-only, pull requests"]
        deployr["Deploy role<br/>main and environments"]
        podid["EKS Pod Identity<br/>per-service roles"]
        awsres["ECR, RDS, SQS,<br/>DynamoDB, SES, ..."]
    end

    subgraph GCPB["GCP trust boundary"]
        wif["Workload Identity<br/>Federation pool"]
        gsa["Service accounts<br/>(plan / deploy)"]
        gkeapi["GKE control plane"]
    end

    argo["Argo CD on EKS<br/>(Pod Identity)"]

    oidc -- "PRs" --> plan
    oidc -- "main" --> deployr
    oidc --> wif --> gsa
    deployr --> awsres
    podid --> awsres
    argo -- "AWS identity to GCP token<br/>(keyless federation)" --> wif
    gsa --> gkeapi
    argo -- "short-lived credentials" --> gkeapi
```

## 5. EKS deployment and promotion

```mermaid
flowchart LR
    pr["PR"] --> ci["CI"] --> main["main"]
    main --> bss["Immutable build,<br/>scan, sign"]
    bss --> dev["Deploy dev<br/>(Argo CD, boutique-dev)"]
    dev --> dtest["Canary + smoke"]
    dtest --> appr{"Prod approval"}
    appr --> promo["Promote to protected<br/>env/prod branch"]
    promo --> prod["Argo CD syncs<br/>boutique-prod"]
    prod --> ptest["Prod canary, smoke,<br/>dev/prod isolation test"]
```

## 6. Event-driven order flow (EKS only)

```mermaid
flowchart LR
    co["checkoutservice"] --> rds[("RDS<br/>order = PENDING")]
    co -- "OrderCreated" --> eb["EventBridge"]
    eb --> invq["SQS inventory queue"]
    invq -. "after 3 failed receives" .-> invdlq["Inventory DLQ"]
    invq --> inv["inventoryservice"]
    inv --> ddb[("DynamoDB<br/>stock + reservations")]
    inv -- "inventory result" --> res["Result event/queue"]
    res --> lam["Lambda<br/>order update"]
    lam --> rds2[("RDS<br/>CONFIRMED or FAILED")]
    lam --> nq["SQS notification queue"]
    nq -. "retries, then DLQ" .-> ndlq["Notification DLQ"]
    nq --> mail["emailservice"]
    mail --> ses["SES email"]
    mail --> slack["Slack"]
```

- **Retries and DLQs:** failed messages return to the queue and move to a dead-letter queue
  after `maxReceiveCount` (3 for the inventory queue); DLQ depth raises a CloudWatch alarm.
- **Idempotency:** `inventoryservice` creates `RESERVATION#<orderId>` only if it does not
  already exist, so redelivery never reserves stock twice; the email consumer deduplicates
  notifications.

## 7. Automatic recovery and rollback

```mermaid
flowchart TB
    fault(("Fault")) --> kind{"Where?"}
    kind -- "container" --> probes["Liveness/readiness probes<br/>restart or remove from Service"]
    kind -- "load" --> hpa["HPA scales pods"]
    kind -- "cluster drift" --> self["Argo CD self-heal<br/>reverts to Git"]
    kind -- "bad release" --> canary["Argo Rollouts canary<br/>analysis fails, abort"]
    kind -- "failed upgrade" --> helm["Helm rollback<br/>(deploy workflow)"]
    kind -- "bad commit" --> revert["GitOps reversion<br/>git revert, Argo CD syncs"]
    kind -- "poison message" --> sqs["SQS retries,<br/>then DLQ + alarm"]
```

## 8. Observability signal flow (EKS)

```mermaid
flowchart LR
    app["Services<br/>traces, metrics, logs"] --> otel["OTel Collector"]
    otel -- "traces" --> tempo["Tempo"]
    app -- "/metrics" --> prom["Prometheus"]
    otel -- "span metrics" --> prom
    cw["CloudWatch<br/>ALB, SQS, RDS metrics"] --> graf
    tempo --> graf["Grafana"]
    prom --> graf
    prom --> alert["Alertmanager"] --> slack["Slack"]
    cw -- "alarms" --> slack
    graf -. "trace-to-log<br/>correlation (trace ID)" .-> logs["Pod logs"]
```

See ADR [0010](adr/0010-opentelemetry-tracing.md) and
[0011](adr/0011-linking-traces-metrics-logs.md).

## 9. GKE Autopilot admission and drift prevention

GKE Autopilot rewrites Pod requests that fall below its minimums (at least 50m CPU per
container, and at least 1 GiB of memory per vCPU). A rewritten live Pod no longer equals Git,
so Argo CD would show a false `OutOfSync`. PR #88 encoded these constraints in
`helm-chart/values-gcp.yaml` and added a rendered-manifest check to CI.

```mermaid
flowchart LR
    git["Git desired state<br/>values-gcp.yaml"] --> ci["CI renders the GKE profile<br/>and validates requests<br/>(ci.yml)"]
    ci -- "violation" --> fail["PR fails:<br/>raise requests in values"]
    ci -- "compliant" --> req["Autopilot-compliant<br/>CPU/memory requests"]
    req --> adm["GKE admission"]
    adm -- "nothing to mutate" --> live["Live state = Git"]
    live --> sync["Argo CD stays Synced"]
```

Requests that already comply are not mutated, so the live state equals Git and Autopilot bills
the same as before.

## Current boundaries and future evolution

- **Kyverno is in audit mode** (ADR 0013); it reports but does not block. Next: enforce after
  audit reports are clean.
- **No failover:** GKE is a portable spoke, not a second production site. Next: replicate data
  across clouds before any failover is considered.
- **Observability** is a single-cluster stack. Next: durable and highly available storage.
- **Edge:** add a WAF and harden the EKS API endpoint.
- **AIOps:** add safe, bounded automated remediation.
