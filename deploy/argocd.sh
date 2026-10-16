#!/usr/bin/env bash
# Installs or updates Argo CD in namespace "argocd" and points it at this repository:
#   1. the argo-cd Helm chart (deploy/argocd/values.yaml): no Dex, no notifications;
#      the argo-rollouts controller (deploy/argo-rollouts/values.yaml, namespace argo-rollouts);
#      then the UI (deploy/argocd-ui.sh): admin password, HTTPS Ingress at argocd.<domain>
#      limited to ARGOCD_ALLOWED_CIDR (docs/week3/ARGOCD.md)
#   2. the repository credential: a read-only GitHub deploy key, copied from AWS Secrets
#      Manager into a Kubernetes Secret (never in Git, GitHub secrets or Terraform state)
#   3. the project "boutique" and the Application "boutique-dev", once
#      gitops/dev/values.yaml holds an image tag (written by a dev deploy from main)
#   4. the Application "boutique-prod", once the prod promotion branch exists and its
#      gitops/prod/values.yaml holds an image tag (written by an approved prod deploy)
# Needs kubectl + helm on the cluster, a full checkout of main, and:
#   ARGOCD_CHART_VERSION   argo-cd chart version
#   ARGO_ROLLOUTS_CHART_VERSION  argo-rollouts chart version (pinned in argocd-install.yml)
#   REPO_URL               SSH URL of this repository (git@github.com:<owner>/<repo>.git)
#   REPO_KEY_SECRET_ARN    Secrets Manager secret with the deploy key's private half
set -euo pipefail
: "${ARGOCD_CHART_VERSION:?}" "${ARGO_ROLLOUTS_CHART_VERSION:?}" "${REPO_URL:?}" "${REPO_KEY_SECRET_ARN:?}"
NS=argocd
export REPO_URL

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# 1) Argo CD
helm upgrade --install argo-cd argo-cd \
  --repo https://argoproj.github.io/argo-helm --version "$ARGOCD_CHART_VERSION" \
  --namespace "$NS" -f deploy/argocd/values.yaml \
  --rollback-on-failure --timeout 10m
echo "argo-cd: $(helm -n "$NS" list -f '^argo-cd$' -o json | jq -r '.[0].chart + " (Argo CD " + .[0].app_version + ")"')"

# 1a) Argo Rollouts controller and CRDs (frontend canary, ADR 0008), before any Application
#     that contains a Rollout is synced.
helm upgrade --install argo-rollouts argo-rollouts \
  --repo https://argoproj.github.io/argo-helm --version "$ARGO_ROLLOUTS_CHART_VERSION" \
  --namespace argo-rollouts --create-namespace -f deploy/argo-rollouts/values.yaml \
  --rollback-on-failure --timeout 10m
echo "argo-rollouts: $(helm -n argo-rollouts list -f '^argo-rollouts$' -o json | jq -r '.[0].chart + " (Argo Rollouts " + .[0].app_version + ")"')"

# 1b) The UI: admin password and the HTTPS Ingress at argocd.<domain> (both optional).
#     Before the Applications, so the UI works even if a wait below fails.
bash deploy/argocd-ui.sh

# 2) Repository credential: through a private file, never on a command line or in the log.
umask 077
key=$(mktemp)
trap 'rm -f "$key"' EXIT
if ! aws secretsmanager get-secret-value --secret-id "$REPO_KEY_SECRET_ARN" \
     --query SecretString --output text > "$key"; then
  echo "::error::Could not read the deploy key. Store it first (docs/week3/ARGOCD.md, step 2)."
  exit 1
fi
# The key must load as an OpenSSH private key (no passphrase). A key wrapped in JSON
# or with CRLF line endings fails here, not later in Argo CD's repo-server.
# ssh-keygen's own output is discarded, so nothing about the key reaches the log.
if ! ssh-keygen -y -P "" -f "$key" >/dev/null 2>&1; then
  echo "::error::Stored Argo CD deploy key is not a valid OpenSSH private key (check line endings / JSON wrapping / Plaintext tab)"
  exit 1
fi
kubectl -n "$NS" create secret generic repo-boutique \
  --from-literal=type=git --from-literal=url="$REPO_URL" --from-file=sshPrivateKey="$key" \
  --dry-run=client -o yaml \
  | kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
  | kubectl apply -f - >/dev/null
rm -f "$key"
echo "Repository credential ready (read-only deploy key)."

# 3) Project, then the dev Application once Git describes dev. Before the first dev
#    deploy from main the values file is empty, and dev stays on the Helm deploy.
envsubst '${REPO_URL}' < deploy/argocd/project.yaml | kubectl apply -f -
tag=$(sed '/^#/d' gitops/dev/values.yaml | jq -r '.images.tag // empty')
if [ -z "$tag" ]; then
  echo "::notice::gitops/dev/values.yaml has no image tag yet. Run a dev deploy from main, then this workflow again. Until then dev is deployed by Helm."
else
  envsubst '${REPO_URL}' < deploy/argocd/boutique-dev.yaml | kubectl apply -f -
  echo "Application boutique-dev created (image tag ${tag}). From now on dev is deployed by Argo CD."
  bash deploy/argocd-wait.sh boutique-dev "$(git rev-parse HEAD)" .
fi

# 4) The prod Application once the promotion branch describes prod (ADR 0007). The branch
#    is created and moved only by an approved prod deploy from main, so this step never
#    changes what prod runs: Argo CD adopts exactly what Helm last deployed there.
branch=$(sed -n 's/^ *targetRevision: *//p' deploy/argocd/boutique-prod.yaml)
if ! head=$(git ls-remote --exit-code origin "refs/heads/${branch}" | cut -f1); then
  echo "::notice::No promotion branch ${branch} yet. Run an approved prod deploy from main, then this workflow again. Until then prod is deployed by Helm."
  exit 0
fi
git fetch --quiet origin "refs/heads/${branch}"
prod_tag=$(git show "FETCH_HEAD:gitops/prod/values.yaml" 2>/dev/null | sed '/^#/d' | jq -r '.images.tag // empty')
if [ -z "$prod_tag" ]; then
  echo "::notice::gitops/prod/values.yaml on ${branch} has no image tag yet. Until then prod is deployed by Helm."
  exit 0
fi
envsubst '${REPO_URL}' < deploy/argocd/boutique-prod.yaml | kubectl apply -f -
echo "Application boutique-prod created (image tag ${prod_tag}, ${branch} at ${head:0:12}). From now on prod is deployed by Argo CD."
ARGOCD_WAIT_EXACT=1 bash deploy/argocd-wait.sh boutique-prod "$head" .
