# Dev / prod isolation in the shared cluster

Dev and prod share one VPC and one EKS cluster to save cost. They are kept apart by these layers:

| Layer | How | Defined in |
|---|---|---|
| Namespaces | `boutique-dev`, `boutique-prod` | `terraform-aws/environments.tf`, deploy workflow |
| Network | Deny-all NetworkPolicy + one policy per service; a prod service only accepts its callers from `boutique-prod`. Enforced by the VPC CNI | `helm-chart/values-aws.yaml`, `terraform-aws/eks.tf` |
| AWS permissions | One Pod Identity role per service per environment, scoped to that environment's resources, plus a namespace-tag condition (ABAC) | `terraform-aws/modules/environment/pod-identity.tf` |
| Data | Separate RDS, Redis, DynamoDB tables, queues, event bus and KMS key per environment | `terraform-aws/modules/environment/` |
| Entry point | One ALB per environment | `helm-chart/templates/ingress.yaml` |

## The isolation test

`deploy/tests/isolation-test.sh` runs at the end of every deploy (after prod), and on demand from **Actions > isolation-test > Run workflow**. The results table is on the run's Summary page.

| Check | Expected | What it proves |
|---|---|---|
| dev → prod frontend | OPEN | Control: the probe's network works (the frontend is public anyway) |
| dev → prod productcatalog, cart, checkout, currency, payment, inventory | BLOCKED | Prod NetworkPolicies drop traffic from other namespaces |
| dev inventoryservice → dev DynamoDB table | OK | Pod Identity gives the pod its own role |
| dev inventoryservice → prod DynamoDB table | AccessDenied | A dev role can't touch prod data |
| dev → prod Redis without prod's token | REFUSED (NOAUTH) | Redis requires TLS and a per-environment auth token; a dev pod only has the dev token |

The probe pod has its egress fully open, like any dev pod, so a BLOCKED result comes from the **prod** side, not from dev's own deny-all.

## Known gaps (remediation plan)

1. ~~**Prod Redis is reachable from dev**~~ **Fixed:** ElastiCache now requires TLS and an auth
   token per environment. The network still lets a dev pod open a connection (same VPC), but
   without prod's token Redis answers `NOAUTH`; the isolation test checks exactly that.
2. ~~**No resource quotas.**~~ **Implemented, pending first deploy:** a ResourceQuota and LimitRange per namespace, a
   PriorityClass per environment (prod outranks dev and may preempt it; dev never preempts), a
   PodDisruptionBudget and topology spread per service, and a preStop hook for graceful shutdown.
3. **Pod Security labels implemented, pending first deploy: `baseline` enforced.** Privileged pods, host namespaces and hostPath are
   refused; `restricted` is audited and warned. Next: enforce `restricted` once the db-migrate
   Job and the isolation probe run as non-root.
4. **Admin-only cluster access.** Fix: EKS access entries scoped per namespace (edit in dev, view in prod).
5. **The frontend accepts traffic from the whole VPC.** This is needed for the ALB's IP targets, and acceptable because the frontend is public anyway.
