#!/usr/bin/env bash
# Installs or updates Argo CD in namespace "argocd" and points it at this repository:
#   1. the argo-cd Helm chart (deploy/argocd/values.yaml): no Dex, no notifications,
#      the UI only inside the cluster (kubectl port-forward, see docs/week3/ARGOCD.md)
#   2. the repository credential: a read-only GitHub deploy key, copied from AWS Secrets
#      Manager into a Kubernetes Secret (never in Git, GitHub secrets or Terraform state)
#   3. the project "boutique" and the Application "boutique-dev", once
#      gitops/dev/values.yaml holds an image tag (written by a dev deploy from main)
# Needs kubectl + helm on the cluster, a full checkout of main, and:
#   ARGOCD_CHART_VERSION   argo-cd chart version
#   REPO_URL               SSH URL of this repository (git@github.com:<owner>/<repo>.git)
#   REPO_KEY_SECRET_ARN    Secrets Manager secret with the deploy key's private half
set -euo pipefail
: "${ARGOCD_CHART_VERSION:?}" "${REPO_URL:?}" "${REPO_KEY_SECRET_ARN:?}"
NS=argocd
export REPO_URL

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# 1) Argo CD
helm upgrade --install argo-cd argo-cd \
  --repo https://argoproj.github.io/argo-helm --version "$ARGOCD_CHART_VERSION" \
  --namespace "$NS" -f deploy/argocd/values.yaml \
  --rollback-on-failure --timeout 10m
echo "argo-cd: $(helm -n "$NS" list -f '^argo-cd$' -o json | jq -r '.[0].chart + " (Argo CD " + .[0].app_version + ")"')"

# 2) Repository credential: through a private file, never on a command line or in the log.
umask 077
key=$(mktemp)
trap 'rm -f "$key"' EXIT
if ! aws secretsmanager get-secret-value --secret-id "$REPO_KEY_SECRET_ARN" \
     --query SecretString --output text > "$key"; then
  echo "::error::Could not read the deploy key. Store it first (docs/week3/ARGOCD.md, step 2)."
  exit 1
fi
grep -q "PRIVATE KEY" "$key" || {
  echo "::error::The deploy key secret does not hold a private key (docs/week3/ARGOCD.md, step 2)."
  exit 1
}
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
  exit 0
fi
envsubst '${REPO_URL}' < deploy/argocd/boutique-dev.yaml | kubectl apply -f -
echo "Application boutique-dev created (image tag ${tag}). From now on dev is deployed by Argo CD."
bash deploy/argocd-wait.sh boutique-dev "$(git rev-parse HEAD)" .
