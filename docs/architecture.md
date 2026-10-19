# Architecture

> Companion to the [README](../README.md) and the [executive summary](../README-EXECUTIVE.md).
> Decisions are recorded in [docs/adr/](adr/).

This document explains **how the platform is built**, in five views:

1. [Context — who and what](#1-context)
2. [Hub-and-spoke control plane](#2-hub-and-spoke-control-plane)
3. [AWS hub — runtime architecture](#3-aws-hub--runtime-architecture)
4. [GKE spoke — runtime architecture](#4-gke-spoke--runtime-architecture)
5. [Security architecture](#5-security-architecture)
6. [Deployment architecture](#6-deployment-architecture)
7. [Recovery and self-healing](#7-recovery-and-self-healing)
8. [Observability architecture](#8-observability-architecture)
9. [Design decisions and trade-offs](#9-design-decisions-and-trade-offs)
10. [Evolution path](#10-evolution-path)

---

## 1. Context

```mermaid
flowchart LR
    eng([Engineer]) -->|pull request| gh[GitHub<br/>repo · rulesets · environments]
    appr([Prod approver]) -->|approve| gh
    shopper([Shopper]) -->|HTTPS| shop[shop. / dev. / gke.<br/>sebngembou-cloud.click]
    op([Operator]) -->|allow-listed IP| graf[Grafana]
    gh --> gha[GitHub Actions]
    gha --> aws[(AWS account)]
    gha --> gcp[(GCP project)]
    aws --> slack([Slack])
    shop --- aws & gcp
```

| Actor | Interaction |
|---|---|
| Engineer | Proposes every change through a pull request; no direct cluster access is needed for delivery |
| Prod approver | Approves the `prod` GitHub Environment after dev verification |
| Shopper | Uses `shop.` (EKS prod), `dev.` (EKS dev) or `gke.` (GKE spoke) |
| Operator | Reads Grafana from allow-listed IPs; receives alarms in Slack |

---

## 2. Hub-and-spoke control plane

Hub-and-spoke here means **centralized platform governance with distributed runtime environments**,
not only VPC routing.

```mermaid
flowchart TB
    repo[GitHub repository<br/>main · env/prod · gitops/*]
    subgraph ci[GitHub Actions + OIDC]
        tfa[Terraform AWS]
        tfg[Terraform GCP]
        rel[Build · scan · SBOM · sign · verify]
        mir[Mirror signed images]
    end
    repo --> ci

    subgraph hub[AWS EKS — HUB]
        direction TB
        argo[Argo CD<br/>namespace argocd]
        rollouts[Argo Rollouts]
        kyv[Kyverno — audit]
        mon[Prometheus · Grafana · Tempo · OTel]
        dev[boutique-dev]
        prod[boutique-prod]
    end

    subgraph spoke[GKE Autopilot — SPOKE]
        direction TB
        gke[boutique-gke<br/>10 services + loadgenerator + redis-cart]
        gmp[Google Managed Prometheus]
        ing[GKE Ingress + managed TLS<br/>global static IP]
    end

    ecr[(ECR<br/>source of truth for images)]
    ar[(Artifact Registry<br/>mirror)]

    tfa --> hub
    tfg --> spoke
    rel --> ecr
    mir --> ar
    ecr --> mir

    argo -- "main" --> dev
    argo -- "env/prod" --> prod
    argo == "keyless K8s→GCP federation<br/>no kubeconfig · no static token" ==> gke
    repo -. "Git desired state" .-> argo
```

### Responsibilities

| Concern | Hub (AWS EKS) | Spoke (GKE Autopilot) |
|---|---|---|
| GitOps control plane | Argo CD runs here | Target cluster only |
| Release process | GitHub approvals, promotion branch | Inherits the same process |
| Artifact provenance | ECR images, cosign signatures, SBOM attestations | Mirrored signed images in Artifact Registry |
| Configuration | Helm chart + `values-aws.yaml`, `gitops/<env>/values.yaml` | `values-gcp.yaml` |
| Identity | GitHub OIDC → IAM roles; EKS Pod Identity | Workload Identity Federation; RBAC scoped to `boutique-gke` |
| Network | VPC 10.0.0.0/16, 2 AZs, ALBs | Own VPC + subnet, Cloud NAT, GKE Ingress |
| Observability | Prometheus, Grafana, Tempo, OTel Collector, CloudWatch | Managed Service for Prometheus, Cloud Monitoring |
| Runtime constraints | EKS defaults + guardrails | Autopilot minimum requests, enforced in CI (PR #88) |
| Endpoint | `shop.` / `dev.` | `gke.` |

### What is *not* on the spoke (by design)

| EKS-only capability | Why it stays on the hub for now |
|---|---|
| Bedrock shopping assistant | Would need Vertex AI or cross-cloud AWS credentials |
| Inventory, EventBridge, SQS, Lambda, SES, DynamoDB | Async flow needs a GCP-native port (Pub/Sub…) |
| RDS catalog and order history | Needs Cloud SQL and a data-replication decision |
| Argo Rollouts canary | Implemented through the ALB in this repo |
| Tempo tracing, Kyverno | Spoke uses managed monitoring; admission policy not yet extended |

There is **no active-active routing or cross-cloud failover**. Before that is possible: data
replication, order consistency, cross-cloud identity, event replication, stateful failover,
observability and incident ownership, and the cost of complexity must all be solved.

---

## 3. AWS hub — runtime architecture

```mermaid
flowchart TB
    user([Shoppers]) -->|HTTPS TLS 1.2+| r53[Route 53 + ACM wildcard]
    r53 --> albp[ALB prod] & albd[ALB dev]
    admin([Allow-listed IP]) --> albm[ALB Grafana]

    subgraph vpc[VPC 10.0.0.0/16 · 2 Availability Zones]
        subgraph pub[Public subnets]
            albp
            albd
            albm
            nat[NAT gateway ×1]
        end
        subgraph priv[Private subnets]
            subgraph eks[EKS cluster · managed node group 2–5]
                subgraph prod[boutique-prod]
                    fp[frontend Rollout<br/>stable + canary] --> sp[11 services · gRPC]
                end
                subgraph dev[boutique-dev]
                    fd[frontend Rollout] --> sd[11 services · gRPC]
                end
                subgraph platform[argocd · monitoring · kyverno]
                    a[Argo CD]
                    m[Prometheus · Grafana · Tempo · OTel]
                    k[Kyverno]
                end
            end
            subgraph data[Per-environment data · KMS key per env]
                rds[(RDS MySQL 8.4<br/>prod Multi-AZ · dev single-AZ)]
                redis[(ElastiCache Redis<br/>TLS + auth token)]
                ddb[(DynamoDB<br/>stock · email log)]
            end
            lam[order-status Lambda]
        end
    end

    albp --> fp
    albd --> fd
    albm --> m
    sp & sd --> rds & redis & ddb
    sp & sd <--> eb[EventBridge + SQS + DLQs]
    eb <--> lam --> rds
    sp & sd --> ses[Amazon SES]
    sp --> br[Amazon Bedrock]
    ecr[(ECR)] -.-> eks
    m -.-> cw[CloudWatch] -.-> sns[SNS] -.-> sl[slack-alerts Lambda] -.-> slack([Slack])
```

**Dev/prod in one cluster** is a cost decision ([ADR 0003](adr/0003-single-account-hardening.md)).
Separation is enforced at five layers:

| Layer | Mechanism |
|---|---|
| Namespace | `boutique-dev`, `boutique-prod` |
| Network | Deny-all NetworkPolicy + one allow rule per call; prod accepts only prod callers |
| IAM | One Pod Identity role per service per env, with a namespace condition |
| Data | Separate RDS, Redis, DynamoDB tables, queues, event bus, KMS key |
| Entry | One ALB and hostname per environment |

Proven by `isolation-test` after every prod deploy.

---

## 4. GKE spoke — runtime architecture

```mermaid
flowchart TB
    user([Shoppers]) -->|HTTPS| ip[Global static IP<br/>gke.domain]
    ip --> ing[GKE Ingress<br/>Google-managed certificate<br/>HTTP → HTTPS]
    subgraph gcpvpc[GCP VPC + subnet]
        subgraph auto[GKE Autopilot cluster]
            subgraph ns[boutique-gke]
                fe[frontend] --> svc[9 services · gRPC]
                svc --> rc[(redis-cart<br/>in-cluster)]
                lg[loadgenerator]
            end
        end
        nat[Cloud NAT]
    end
    ing --> fe
    ar[(Artifact Registry<br/>mirrored signed images)] -.-> auto
    auto -.-> gmp[Managed Prometheus<br/>Cloud Monitoring]
    budget[GCP budget] -.-> gmp
```

**Autopilot contract.** Autopilot raises requests below its minimums at admission. Because that
creates permanent Argo CD drift, `values-gcp.yaml` declares compliant values and CI renders the GKE
release and fails if any container would be mutated (PR #88).

```mermaid
flowchart LR
    v[values-gcp.yaml] --> r[helm template<br/>GKE release]
    r --> c{Every container ≥<br/>Autopilot minimum<br/>and valid CPU:memory?}
    c -- yes --> ok[ci-ok ✓<br/>Git = live state]
    c -- no --> fail[CI fails ✗<br/>drift caught before deploy]
```

---

## 5. Security architecture

### 5.1 Defense in depth

```mermaid
flowchart TB
    subgraph L1[1 · Source]
        a1[Branch ruleset · PR + ci-ok · CODEOWNERS]
        a2[CodeQL SAST · gitleaks]
    end
    subgraph L2[2 · Infrastructure]
        b1[Terraform plan review]
        b2[Checkov — soft-fail]
    end
    subgraph L3[3 · Artifact]
        c1[Immutable SHA tags]
        c2[ECR scan gate — CRITICAL blocks]
        c3[Syft SBOM · cosign keyless sign · verify]
    end
    subgraph L4[4 · Identity]
        d1[GitHub OIDC · plan vs deploy roles]
        d2[Permission boundaries · Pod Identity · WIF]
    end
    subgraph L5[5 · Cluster]
        e1[Kyverno signature + SBOM audit]
        e2[NetworkPolicies · PSS · quotas · non-root · RO FS]
    end
    subgraph L6[6 · Data & edge]
        f1[KMS per env · TLS to RDS/Redis · HTTPS only]
        f2[Private subnets · Grafana IP allow-list]
    end
    L1 --> L2 --> L3 --> L4 --> L5 --> L6
```

### 5.2 Software supply chain

```mermaid
sequenceDiagram
    autonumber
    participant GH as GitHub Actions (deploy)
    participant ECR as Amazon ECR
    participant SG as Sigstore (Fulcio/Rekor)
    participant GO as gitops/ values
    participant AR as Argo CD
    participant K as Kyverno
    GH->>GH: docker buildx build (tag = commit SHA)
    GH->>ECR: push immutable tag
    ECR->>ECR: scan on push
    ECR-->>GH: findings — stop if CRITICAL
    GH->>GH: Syft → SPDX SBOM
    GH->>SG: OIDC token → short-lived cert
    GH->>ECR: cosign sign digest + attest SBOM
    GH->>ECR: cosign verify (identity + issuer)
    GH->>GO: commit image tag (GitHub App)
    AR->>GO: detect change
    AR->>AR: sync to cluster
    K->>ECR: verify signature + attestation
    K-->>K: policy report (audit, fail-open)
```

### 5.3 Identity map

```mermaid
flowchart LR
    subgraph github[GitHub]
        pr[PR workflows]
        main[main / env workflows]
        app[GitHub App]
    end
    subgraph awsid[AWS IAM]
        plan[plan role<br/>read-only]
        deploy[deploy role<br/>+ permission boundary]
        pi[Pod Identity roles<br/>per service · per env]
    end
    subgraph gcpid[GCP IAM]
        gp[gha-plan SA]
        gd[gha-deploy SA]
        fed[Argo CD federation<br/>RBAC: boutique-gke]
    end
    pr -->|OIDC| plan
    pr -->|WIF| gp
    main -->|OIDC| deploy
    main -->|WIF| gd
    app -->|writes| gitops[gitops/ values only]
    pods[EKS Pods] --> pi
    argo[Argo CD on EKS] --> fed
```

| Principle | Result |
|---|---|
| No stored cloud keys | OIDC / WIF everywhere; no service-account keys exist |
| Separation of duties | PRs can only plan; only `main` / approved environments can deploy |
| Least privilege at runtime | Each service gets only DynamoDB / SQS / EventBridge / SES / Secrets Manager / CloudWatch / Bedrock actions it needs |
| Environment boundary | Namespace condition stops dev Pods from assuming prod roles |

### 5.4 Kyverno: audit → enforce

| Step | Exit criterion |
|---|---|
| 1 | Dedicated Pod Identity role for Kyverno ECR reads |
| 2 | Zero `fail` / `error` reports through deploys, a canary and a rollback |
| 3 | Multiple admission replicas with a PDB |
| 4 | Explicit fail-open vs fail-closed decision |
| 5 | Digest pinning validated with Argo CD + Rollouts ownership |
| 6 | Third-party images pinned by digest or allow-listed |

---

## 6. Deployment architecture

### 6.1 End-to-end release

```mermaid
flowchart TB
    pr[Pull request] --> ci{ci-ok<br/>tests · CodeQL · gitleaks<br/>Helm render · Terraform plan}
    ci -- fail --> stop1[Blocked]
    ci -- pass --> merge[Squash merge → main]
    merge --> build[Build changed images · SHA tag]
    build --> scan{ECR scan<br/>CRITICAL?}
    scan -- yes --> stop2[Release stopped]
    scan -- no --> sign[SBOM + sign + verify]
    sign --> gdev[Commit dev image tag<br/>gitops/dev]
    gdev --> sdev[Argo CD sync dev]
    sdev --> cdev{Canary + smoke OK?}
    cdev -- no --> rbdev[Abort / GitOps revert]
    cdev -- yes --> gate{{prod approval}}
    gate --> promote[Update env/prod<br/>same image SHA]
    promote --> sprod[Argo CD sync prod]
    sprod --> cprod{Canary + smoke OK?}
    cprod -- no --> rbprod[Abort / restore env/prod]
    cprod -- yes --> iso[Isolation test] --> done[Released ✓ + Slack]
```

### 6.2 Canary analysis (frontend)

```mermaid
flowchart LR
    s0[Stable 100%] --> s1[Canary 20%]
    s1 --> a1{Analysis<br/>volume · success rate · p95}
    a1 -- pass --> s2[Canary 50%]
    s2 --> a2{Analysis}
    a2 -- pass --> s3[Promote 100%]
    a1 -- fail --> ab[Abort → stable 100%]
    a2 -- fail --> ab
```

### 6.3 Branches and promotion

```mermaid
gitGraph
    commit id: "main"
    branch feature/x
    commit id: "change"
    checkout main
    merge feature/x id: "squash → dev"
    commit id: "gitops: dev tag"
    branch env/prod
    commit id: "promote SHA (after approval)"
    checkout main
    branch ops/gke-autopilot
    commit id: "PR #88"
    checkout main
    merge ops/gke-autopilot id: "squash"
```

### 6.4 Environment lifecycle

```mermaid
stateDiagram-v2
    [*] --> Bootstrapped: bootstrap (once)
    Bootstrapped --> Running: infra apply + argocd-install
    Running --> Running: PR → dev → approve → prod
    Running --> Destroyed: infra destroy (cost)
    Destroyed --> Running: infra apply (next session)
```

---

## 7. Recovery and self-healing

```mermaid
flowchart TB
    f[Failure] --> t{Type}
    t -->|process crash| k1[Kubernetes restart / reschedule]
    t -->|not ready| k2[Readiness removes from traffic]
    t -->|load| k3[HPA scale-out]
    t -->|bad release| d1[Rollouts abort / Helm rollback / GitOps revert]
    t -->|manual drift| g1[Argo CD self-heal]
    t -->|consumer failure| e1[SQS retry → DLQ + alarm]
    t -->|duplicate event| e2[Idempotent consumer]
    t -->|DB · IAM · node · design| h[Human: alert → runbook → fix]
```

| Layer | Automatic today | Still human |
|---|---|---|
| Workload | Restart, reschedule, readiness, HPA | Capacity planning |
| Deployment | Canary abort, Helm and GitOps rollback | Root cause of the bad change |
| Configuration | Drift correction | Policy design |
| Events | Retries, DLQ, idempotency | DLQ redrive decision |
| Infrastructure / data | Alarms to Slack | RDS, Redis, IAM, node remediation; DR |

---

## 8. Observability architecture

```mermaid
flowchart LR
    subgraph apps[Services · Go · Python · Java · Node · .NET]
        sdk[OpenTelemetry SDKs]
        met[/metrics/]
        logs[JSON logs<br/>trace_id · span_id]
    end
    sdk --> col[OTel Collector<br/>filter health checks<br/>span metrics + service graph from ALL spans<br/>tail sampling]
    col -->|dev 100% · errors · slow · 10% prod| tempo[(Tempo · 24 h)]
    col -->|span metrics| prom[(Prometheus)]
    met --> prom
    logs --> cwl[(CloudWatch Logs)]
    prom --> graf[Grafana]
    tempo --> graf
    cwl --> graf
    prom --> ana[Rollouts analysis]
    cwa[CloudWatch alarms] --> slack([Slack])
```

Investigation path: **p95 alert → Grafana panel → exemplar → Tempo trace → correlated log lines →
the dependency responsible.** No PII, session IDs, payloads, card data or AI prompts/responses are
collected.

---

## 9. Design decisions and trade-offs

| Decision | Benefit | Accepted cost / risk | ADR |
|---|---|---|---|
| Argo CD GitOps | Auditable desired state, drift repair | Another control plane to secure | [0001](adr/0001-argo-cd-gitops.md) |
| Single account, hardened | Lower cost, simpler | Shared-fate risk | [0003](adr/0003-single-account-hardening.md) |
| PriorityClass owned by deploy workflow | Prod preempts dev | Ordering coupling | [0006](adr/0006-priorityclass-owned-by-deploy-workflow.md) |
| `env/prod` promotion branch | Explicit prod changes | Extra promotion step | [0007](adr/0007-argocd-prod-promotion-branch.md) |
| ALB canary with Argo Rollouts | Measured releases | Frontend only | [0008](adr/0008-argo-rollouts-alb-canary.md) |
| Guardrailed Bedrock assistant | Safe, bounded AI | Feature limits | [0009](adr/0009-shopping-assistant-bedrock.md) |
| OTel + Tempo, tail sampling | Unbiased metrics, low cost | Single collector, 24 h traces | [0010](adr/0010-opentelemetry-tracing.md), [0011](adr/0011-linking-traces-metrics-logs.md) |
| Keyless signing + SBOM | Provable provenance | Attestations use ECR lifecycle slots | [0012](adr/0012-image-signing-sbom.md) |
| Kyverno in audit | Safe adoption | Not yet a hard control | [0013](adr/0013-kyverno-image-signatures-audit.md) |
| GKE portable profile | Portability proof | Not a failover target | [0014](adr/0014-multicloud-gke-portable-profile.md) |
| One NAT gateway | Cost | Non-HA egress | — |
| ECR scan, not Trivy action | No third-party code with AWS creds | Scan after push, not before | — |

---

## 10. Evolution path

```mermaid
flowchart LR
    now[Today<br/>Safe delivery<br/>self-healing at workload,<br/>deploy, config, events] --> n1[Enforce<br/>Kyverno enforce · Checkov blocking<br/>WAF · private EKS API]
    n1 --> n2[Harden<br/>Multi-account · OTel HA<br/>durable Tempo · DR drills]
    n2 --> n3[Independent spokes<br/>data + event replication<br/>only when required]
    n3 --> n4[Safe AIOps<br/>diagnosis · runbook recommendations<br/>human-approved recovery]
```

> **Next-phase question:** how do we evolve a centralized GitOps hub into a resilient multi-cloud
> platform where each spoke can operate independently, while policy, provenance, observability and
> recovery remain consistent?
