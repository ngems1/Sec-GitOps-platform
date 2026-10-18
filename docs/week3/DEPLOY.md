# Deploy pipeline

```
push to main ──► build ×12 ──► scan gate ──► deploy dev ──► (approval) ──► deploy prod
                 (parallel)    (ECR scan)    migrate DB                    same images
                                             helm upgrade
                                             smoke test
```

| File | What it does |
|---|---|
| `.github/workflows/deploy.yml` | Picks the image tag, builds and pushes the 12 images, scans them, then calls `deploy-env.yml` for dev and prod |
| `.github/workflows/deploy-env.yml` | Deploys one environment: Load Balancer Controller, DB migrations, Helm, smoke test, rollback |
| `helm-chart/values-aws.yaml` | EKS settings common to dev and prod (service accounts, NetworkPolicies, ALB Ingress, ElastiCache) |
| `helm-chart/values-dev.yaml`, `values-prod.yaml` | What differs between the two environments |
| `helm-chart/templates/ingress.yaml` | The Ingress the controller turns into one ALB per environment |
| `.github/workflows/isolation-test.yml`, `deploy/tests/isolation-test.sh` | After prod: proves dev can't reach prod (network + IAM), see ISOLATION.md |
| `deploy/k8s/db-migrate.yaml` | Job that applies `db/migrations/*.sql` to RDS from inside the cluster |
| `gitops/dev/values.yaml`, `.github/workflows/argocd-install.yml` | dev through Argo CD: see [ARGOCD.md](ARGOCD.md) |

## When it runs

- **Push to `main`** that touches `src/`, `helm-chart/`, `db/`, `deploy/` or the deploy workflows: dev and then prod.
- **Manually** (Actions > deploy > Run workflow):
  - `target = dev-only` stops after dev.
  - `image_tag = <12-character commit SHA>` redeploys images that already exist, with no build. This is the **rollback** button.

Prod always waits for a reviewer on the `prod` environment. If your repo can't have required reviewers (private repo on a free plan), prod deploys straight after dev.

## The steps, and why

1. **Image tag = commit SHA.** ECR tags are immutable, so a tag always means the same code. Prod gets exactly the images that passed in dev.
2. **Scan gate.** ECR scans every image on push. A CRITICAL finding stops the run before anything reaches the cluster. Set the repository variable `SCAN_BLOCKING=false` to only report. ECR's scanner is used instead of a third-party scanner action, so no extra code runs with AWS credentials (see the Trivy GitHub Actions compromise of March 2026, CVE-2026-33634).
   **Then sign.** Each image that passed gets an SPDX SBOM (Syft), a cosign keyless signature and the SBOM as a signed attestation, all by digest, then both are verified with the exact signer identity. A failure stops the run. Values and checks: [IMAGE-SIGNING.md](IMAGE-SIGNING.md), ADR 0012.
3. **Load Balancer Controller.** One copy in `kube-system`, shared by both environments. Its AWS rights come from Pod Identity (Terraform).
4. **Database migrations.** RDS is private, so a Kubernetes Job runs them inside the VPC. The password goes from Secrets Manager to a Secret that is deleted right after. The connection uses TLS with certificate checks. The SQL is safe to run again.
5. **Helm.** `helm upgrade --install --rollback-on-failure`: if the new pods don't become ready within 10 minutes, Helm restores the previous version by itself.
   **dev with Argo CD** (once `argocd-install` has created the Application `boutique-dev`): instead of Helm, the workflow commits the image tag to `gitops/dev/values.yaml` on `main` and waits until Argo CD has synced it (Synced and Healthy). A failed smoke test reverts that commit. Details: [ARGOCD.md](ARGOCD.md).
6. **Smoke test.** It checks that the ALB answers `/`, `/_healthz`, a product page and `/cart`, and that `inventoryservice /stock` returns stock from DynamoDB, which proves Pod Identity works. If the test fails, the workflow rolls back to the previous Helm revision.

## Variables used

| Variable | Where | Set by |
|---|---|---|
| `AWS_REGION`, `AWS_DEPLOY_ROLE_ARN`, `TF_STATE_BUCKET` | Repository | You, after the bootstrap (BOOTSTRAP.md) |
| `SCAN_BLOCKING` | Repository, optional | `false` = report vulnerabilities without blocking |

Everything else (registry, cluster, queues, tables, Redis, database) is read from the Terraform state, so nothing is copied by hand.

## Useful commands (CloudShell)

```bash
aws eks update-kubeconfig --name week3-boutique-eks --region us-east-1
kubectl -n boutique-dev get pods,ingress
helm -n boutique-dev history boutique
helm -n boutique-dev rollback boutique <revision>   # manual rollback
kubectl -n boutique-dev logs deploy/inventoryservice
```

## Autoscaling (HPA)

The first stress test (800 shoppers, 15 min, one pod per service) ended with 0 errors
but p95 around 8 s and only ~130 requests/s: the busiest pods were stuck at their CPU
limit while the nodes stayed around 40% CPU. So:

- `helm-chart/templates/hpa.yaml` + `autoscaling` in `values-aws.yaml`: a
  HorizontalPodAutoscaler for frontend, currencyservice (1-4 pods), productcatalogservice,
  cartservice and recommendationservice (1-3 pods). It adds pods above 70% of the CPU
  request and removes them after 2 minutes of lower CPU.
- metrics-server (upstream Helm chart, installed by `deploy-env.yml`; not the EKS add-on, see RUNBOOK section 7) gives the HPA its CPU numbers.
- VPC CNI prefix delegation (`eks.tf`): up to 110 pods per t3.medium instead of 17, so
  the extra replicas are not stuck in "Too many pods". Applies to new nodes, i.e. after
  `infra -> destroy` + `infra -> apply`.
- Higher CPU limits for those five services and more tolerant health checks (5 s
  timeout, 6 failures), so a busy pod is not restarted for answering slowly.

Check: Actions -> cluster-status -> `boutique-dev` ("autoscalers" and "containers that
restarted"), and the Nodes step (`MAX_PODS` 110). In Grafana, "CPU by pod" shows the
extra pods during a stress test.

## HTTPS with our domain

With the GitHub repository variable **`DOMAIN_NAME`** set to a public Route 53 hosted
zone in this account (here `sebngembou-cloud.click`):

| Address | Points at |
|---|---|
| https://dev.<domain> | boutique-dev ALB |
| https://shop.<domain> | boutique-prod ALB |
| https://grafana.<domain> | boutique-monitoring ALB (still only from `MONITORING_ALLOWED_CIDR`) |

- `terraform-aws/dns.tf`: one ACM certificate for `<domain>` and `*.<domain>`, validated
  with DNS records in the zone (free, renewed by AWS).
- The ingresses get an HTTPS listener with that certificate (TLS 1.2+); port 80 only
  redirects to 443.
- The ALBs are created by Kubernetes, so the deploy workflow points the names at them
  (`deploy/dns-record.sh`, alias records). `infra -> destroy` removes the names again.
- The smoke test runs over HTTPS with the real name, so a wrong certificate fails the deploy.

Without `DOMAIN_NAME` everything stays on the plain `http://<alb>` addresses.

## Order emails (Amazon SES)

emailservice sends a real email for every final order status (confirmed / failed) when
the customer's address is a **verified recipient**; every other order (load tests,
`someone@example.com`) stays in log mode. Each email is also logged in DynamoDB.

- `terraform-aws/ses.tf`: the domain identity (sender `orders@<domain>`, DKIM records in
  Route 53, verified automatically) and one identity per address in the GitHub variable
  **`SES_RECIPIENTS`** (comma-separated).
- SES starts in **sandbox** mode: it only delivers to verified addresses. After the infra
  run, each recipient gets an email *"Amazon Web Services – Email Address Verification
  Request"*: click the link once. Check: SES console > Identities (both "Verified").
- emailservice may only send as `orders@<domain>` (IAM condition `ses:FromAddress`).
- If SES refuses an email, the DynamoDB row is removed and the message retried
  (3 tries, then the DLQ alarm in Slack), so no email is silently lost.

Test: in the dev shop, check out with your verified address in the email field.

## Rollback demo (acceptance test step 12)

Every deploy builds all images with the commit SHA as tag (immutable in ECR), and the
shop's footer shows that SHA as **Version**. A rollback is a redeploy of an older tag,
without building anything:

1. Note the version in the footer (and in the Slack "Deployed `<sha>`" message): **v1**.
2. Merge any change that deploys: the footer now shows **v2**.
3. Actions > deploy > Run workflow: `image_tag` = the v1 SHA, `target` = `dev-only`.
   The setup job checks that all 12 images exist with that tag, then Helm deploys them.
4. Reload the shop: the footer shows **v1** again.
5. Evidence: Actions > cluster-status > `boutique-dev`, step "Helm history": one revision
   per deploy, the last one running the v1 image.

Automatic rollback also exists: an upgrade whose pods don't become ready within 10 min is
rolled back by Helm (`--rollback-on-failure`), and a failed smoke test redeploys the
previous revision.

## Chaos tests (break it on purpose, in dev)

Actions > chaos > Run workflow. Only touches `boutique-dev`, and puts everything back at
the end, even if the run fails halfway. Results on the run's Summary page.

| Scenario | What happens | What to watch |
|---|---|---|
| `pod-failure` | Deletes the pod of the chosen service | New pod Ready after a few seconds; shop checked every 2 s through the ALB (a single replica gives a short gap) |
| `consumer-failure` | inventoryservice at 0 replicas for 3/8/12 min while 4 simulated shoppers order | Grafana > Event flow: inventory-q grows; with 8+ min the backlog alarm goes 🔴 to #boutique-alerts; after the restart the queue empties, orders become CONFIRMED (order-flow), alarm 🟢, DLQs stay at 0 |

## Follow an order through the event flow

1. Place an order in the shop (dev or prod link from the deploy run's Summary). To see the failure path in dev, order 3 mugs: dev only has 2.
2. **Actions > order-flow > Run workflow**, then pick the environment.
3. The run's Summary shows:
   - **Orders (RDS MySQL):** the order moves from `PENDING` to `CONFIRMED`, or `FAILED` with reason `INSUFFICIENT_STOCK`
   - **Reservations (DynamoDB):** `RESERVED` or `FAILED` for each order, plus the current stock
   - **Queues:** messages waiting or in flight. A dead-letter queue above 0 means a consumer is failing.
   - **Lambda logs:** each status change, with its order ID
   - **Notifications:** the email emailservice sent for each final status (one row per order and status, recipient masked). In log mode the email itself is in emailservice's log: search `email sent` in CloudWatch Logs Insights.

## Catalog: database and cache path

productcatalogservice reads the products from RDS MySQL (`products` table) with Redis (ElastiCache) in front:
a request is answered from Redis when the cached catalog is there (**hit**); otherwise (**miss**) it reads MySQL
and caches the result for 5 minutes. If Redis is down it reads MySQL directly; if MySQL is down it serves the
last catalog it read, then the built-in `products.json`. The shop never stops because of the data layer.

**Actions > catalog > Run workflow** shows the prices in MySQL and the service's catalog log lines
(`catalog cache miss: loaded 9 products from MySQL`, and once a minute `catalog cache stats: N hits, M misses`).

To watch the cache at work, run it with a product and a **new price** (e.g. Sunglasses, `15.00`):
the shop keeps the old price while the cached catalog is valid (up to 5 minutes), then shows the new one.
Run it again with `19.99` to put the price back.

For pods and events, use **Actions > cluster-status**.
