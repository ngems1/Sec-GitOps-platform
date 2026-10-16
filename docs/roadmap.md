# Roadmap

The order of the work after Week 3. Each phase ends with something that can be shown; decisions
are in `docs/adr/`. Updated 2026-10-16.

| Phase | Work | State |
|---|---|---|
| 1 | GitOps with Argo CD (dev from `main`, prod from the `env/prod` promotion branch) and an Argo Rollouts canary of the frontend with automated analysis (ADRs 0001, 0007, 0008) | Done |
| 2 | **AI shopping assistant**: a `/assistant` page answering questions about the catalog through Amazon Bedrock (Nova Lite, read-only tools, cost and safety guardrails; ADR 0009) | In progress (dev for the Monday demo; prod after) |
| 2b | AI incident assistant: the alert in Slack comes with logs, pod events and a short diagnosis citing the RUNBOOK, reusing the Phase 2 Bedrock base | After Phase 2 |
| 3 | OpenTelemetry tracing: the collector exporting to AWS X-Ray, the four services without tracing instrumented, trace context through EventBridge and SQS, Lambda tracing | Planned |
| 4 | Istio ambient mode with waypoints (mTLS, L7 policy); the frontend canary can move from ALB to Istio routing | Planned |
| 5 | Supply chain: Syft SBOMs, cosign signatures, Kyverno admission (signed images from ECR only) | Planned |
| 6 | Multi-cloud through the same Argo CD and Helm chart (Azure AKS, optionally GCP GKE) | Planned |

Earlier ideas that are not scheduled yet (kept, not dropped): transactional outbox and checkout
saga, preview environments per pull request, Karpenter with Graviton and Spot, OpenCost and
Infracost, SLO burn-rate alerts, Renovate, Playwright end-to-end tests, Flyway or Atlas
migrations, three AZs and VPC endpoints, CloudFront and WAF, restore drill and fault injection,
enforcing Pod Security `restricted`.
