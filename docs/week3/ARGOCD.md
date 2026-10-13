# Argo CD (dev)

dev is deployed by Argo CD from Git. prod is still deployed by Helm from the
workflow (Day 4 moves it). Decision record: [ADR-0001](../adr/0001-argo-cd-gitops.md).

```
merge to main ──► deploy: build, scan, DB migrations
                        └─► commit image tag to gitops/dev/values.yaml (GitHub App)
                                   │
           Argo CD (in the cluster) ◄── pulls main ──► syncs boutique-dev
                        └─► deploy waits for Synced + Healthy ──► smoke test
                                                                   └─ fails: revert the commit
```

| File | What it does |
|---|---|
| `.github/workflows/argocd-install.yml` | Manual. Installs or updates Argo CD, the repository credential, the project and the dev Application |
| `deploy/argocd.sh` | The install steps (called by the workflow) |
| `deploy/argocd/values.yaml` | Argo CD settings: no Dex, no notifications, UI without a public address |
| `deploy/argocd/project.yaml` | Project `boutique`: only this repository, only `boutique-dev`, no cluster-wide objects |
| `deploy/argocd/boutique-dev.yaml` | Application `boutique-dev`: `helm-chart/` with `values-aws.yaml`, `values-dev.yaml`, `gitops/dev/values.yaml`; automated sync with prune and self-heal |
| `gitops/dev/values.yaml` | The names Terraform created for dev and the image tag. Written by the deploy workflow only |
| `deploy/gitops-commit.sh`, `deploy/argocd-wait.sh` | Commit or revert the tag; wait for the sync (called by `deploy-env.yml`) |
| `terraform-aws/argocd.tf` | The empty Secrets Manager secret for the deploy key (dev KMS key) |

## One-time setup (in this order)

1. **Terraform.** Run Actions > infra (apply). It creates the secret
   `week3-boutique/argocd-repo-deploy-key` (output `argocd_repo_key_secret_arn`).
2. **Deploy key (read-only).** In CloudShell:

   ```bash
   ssh-keygen -t ed25519 -N "" -C argocd-sec-gitops -f argocd_deploy_key
   aws secretsmanager put-secret-value --secret-id week3-boutique/argocd-repo-deploy-key \
     --secret-string file://argocd_deploy_key
   cat argocd_deploy_key.pub   # paste this into GitHub, see below
   rm -f argocd_deploy_key argocd_deploy_key.pub
   ```

   GitHub: Settings > Deploy keys > Add deploy key. Paste the `.pub` line and leave
   **Allow write access** unticked. The private key exists only in Secrets Manager
   and, after step 6, in the cluster.
3. **GitHub App (commits the image tag).** Settings > Developer settings > GitHub Apps > New:
   no webhook, repository permission **Contents: Read and write**, nothing else.
   Install it on this repository only. Generate a private key.
   Settings > Environments > `dev`: variable `GITOPS_APP_ID` (the App ID), secret
   `GITOPS_APP_PRIVATE_KEY` (the `.pem` content).
4. **Ruleset on `main`.** Add the App to the bypass list ("Always allow"). It is the
   only actor that can push to `main` without a pull request, and it only touches
   `gitops/dev/values.yaml`. Its commits end in `[skip ci]`.
5. **A dev deploy from `main`** (merge, or Actions > deploy > Run workflow). There is
   no Application yet, so Helm deploys dev as before. After the smoke test passes,
   the workflow commits the tag and the Terraform names to `gitops/dev/values.yaml`.
6. **Actions > argocd-install > Run workflow** (from `main`). It installs Argo CD,
   creates the repository credential, the project and the Application, and waits
   until `boutique-dev` is Synced and Healthy. Argo CD adopts the running objects in
   place, with the same values, so nothing restarts.

From then on every dev deploy is a commit plus an Argo CD sync. The deploy log says
which one ran ("dev is deployed by: Argo CD" or "Helm").

## Who owns what in boutique-dev

| Argo CD (from Git) | The deploy workflow |
|---|---|
| Everything rendered from `helm-chart/`: Deployments, Services, ServiceAccounts, NetworkPolicies, HPAs, Ingress, OpenTelemetry Collector | Namespace `boutique-dev` and its readiness-gate label; Secrets `redis-auth`, `emailservice-slack`; DB migration Job, ConfigMap and short-lived Secret; AWS Load Balancer Controller (`kube-system`); namespace `monitoring` |

Prune only deletes objects Argo CD created (it tracks them with an annotation), so the
workflow's Secrets and Job are never removed.

## UI (no public address)

```bash
kubectl -n argocd port-forward svc/argo-cd-argocd-server 8080:443
# https://localhost:8080, user admin. First login password:
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

Change the password in the UI (User info), then delete `argocd-initial-admin-secret`.

## Rollback

- **Automatic:** a failed sync or smoke test makes the deploy revert its own tag
  commit; Argo CD syncs the previous version back.
- **Manual:** Actions > deploy > Run workflow with `image_tag` = an older commit SHA and
  `target = dev-only`: it commits that tag. Or revert a `gitops: dev image tag` commit
  on `main`.
- **Back to Helm (emergency):** `kubectl -n argocd delete application boutique-dev`.
  The Application has no resources finalizer, so the shop keeps running, and the next
  deploy uses the Helm steps again.

## Good to know

- `sesRecipients` (people's email addresses) is not written to Git. Under Argo CD, dev's
  emailservice therefore sends no SES order emails; prod is unchanged.
- A chart change merged to `main` is synced by Argo CD right away, before the deploy
  workflow has built images or run migrations.
- Argo CD renders the chart with its own built-in Helm, not the workflow's Helm 4.
