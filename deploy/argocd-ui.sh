#!/usr/bin/env bash
# Makes the Argo CD UI usable without kubectl (called by deploy/argocd.sh after the install):
#   1. admin password from ARGOCD_ADMIN_PASSWORD (GitHub secret), bcrypt-hashed into
#      argocd-secret (admin.password, admin.passwordMtime); argocd-initial-admin-secret is
#      deleted. Unchanged when the stored hash already matches (sessions stay valid).
#   2. the Ingress at argocd.<domain> (deploy/argocd/ingress.yaml): HTTPS only, reachable
#      only from ARGOCD_ALLOWED_CIDR, plus its Route 53 record.
# The repository is public, so its Actions logs are too: the password, its hash and the
# allowed address are masked and never printed.
# Optional (empty = that part is skipped, and without both the UI is not exposed):
#   ARGOCD_ADMIN_PASSWORD  ARGOCD_ALLOWED_CIDR (e.g. 203.0.113.7/32)
# From the Terraform outputs (tls): ARGOCD_HOST, CERT_ARN, DNS_ZONE_ID.
set -euo pipefail
NS=argocd
ARGOCD_ADMIN_PASSWORD=${ARGOCD_ADMIN_PASSWORD:-}
ARGOCD_ALLOWED_CIDR=${ARGOCD_ALLOWED_CIDR:-}
[ -z "$ARGOCD_ADMIN_PASSWORD" ] || echo "::add-mask::${ARGOCD_ADMIN_PASSWORD}"
[ -z "$ARGOCD_ALLOWED_CIDR" ] || echo "::add-mask::${ARGOCD_ALLOWED_CIDR}"

# 1) Admin password ---------------------------------------------------------------------
if [ -z "$ARGOCD_ADMIN_PASSWORD" ]; then
  echo "::notice::No ARGOCD_ADMIN_PASSWORD secret: the admin password is not managed, and the UI is not exposed."
else
  # bcrypt in a throwaway virtualenv (the runner's system Python refuses pip installs).
  venv=$(mktemp -d)
  python3 -m venv "$venv"
  "$venv/bin/pip" install --quiet --disable-pip-version-check bcrypt==4.2.1
  # Current hash (empty on a fresh install). Only kept in a variable, never printed.
  CURRENT_HASH=$(kubectl -n "$NS" get secret argocd-secret -o jsonpath='{.data.admin\.password}' | base64 -d)
  # The password and hashes reach Python through the environment, never a command line.
  new_hash=$(CURRENT_HASH="$CURRENT_HASH" "$venv/bin/python" -I - <<'PY'
import os, bcrypt
pw = os.environ["ARGOCD_ADMIN_PASSWORD"].encode()
cur = os.environ.get("CURRENT_HASH", "").encode()
try:
    same = bool(cur) and bcrypt.checkpw(pw, cur)
except ValueError:  # not a bcrypt hash
    same = False
print("" if same else bcrypt.hashpw(pw, bcrypt.gensalt(rounds=10)).decode())
PY
  )
  rm -rf "$venv"
  if [ -z "$new_hash" ]; then
    echo "Admin password already up to date."
  else
    echo "::add-mask::${new_hash}"
    umask 077
    patch=$(mktemp)
    HASH="$new_hash" MTIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      jq -n '{stringData: {"admin.password": env.HASH, "admin.passwordMtime": env.MTIME}}' > "$patch"
    kubectl -n "$NS" patch secret argocd-secret --type merge --patch-file "$patch" >/dev/null
    rm -f "$patch"
    echo "Admin password set from ARGOCD_ADMIN_PASSWORD (existing sessions are logged out)."
  fi
  kubectl -n "$NS" delete secret argocd-initial-admin-secret --ignore-not-found >/dev/null
fi

# 2) Ingress (HTTPS only, allowed address only) -----------------------------------------
unexpose() { kubectl -n "$NS" delete ingress argocd-server --ignore-not-found >/dev/null; }
if [ -z "$ARGOCD_ALLOWED_CIDR" ] || [ -z "$ARGOCD_ADMIN_PASSWORD" ]; then
  unexpose
  echo "::notice::Argo CD UI not exposed: set the repository variable ARGOCD_ALLOWED_CIDR (your-ip/32) and the secret ARGOCD_ADMIN_PASSWORD."
  exit 0
fi
if [ -z "${ARGOCD_HOST:-}" ] || [ -z "${CERT_ARN:-}" ] || [ -z "${DNS_ZONE_ID:-}" ]; then
  unexpose
  echo "::notice::Argo CD UI not exposed: it needs the domain (GitHub variable DOMAIN_NAME, then infra apply) for HTTPS."
  exit 0
fi
if ! [[ "$ARGOCD_ALLOWED_CIDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}(,([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2})*$ ]]; then
  echo "::error::ARGOCD_ALLOWED_CIDR must be one or more IPv4 CIDRs, e.g. 203.0.113.7/32"; exit 1
fi
if [[ ",$ARGOCD_ALLOWED_CIDR," == *",0.0.0.0/0,"* ]]; then
  echo "::error::ARGOCD_ALLOWED_CIDR may not be 0.0.0.0/0: the Argo CD UI must not be open to the whole internet"; exit 1
fi

export ARGOCD_ALLOWED_CIDR ARGOCD_HOST CERT_ARN
envsubst '${ARGOCD_ALLOWED_CIDR} ${ARGOCD_HOST} ${CERT_ARN}' < deploy/argocd/ingress.yaml | kubectl apply -f - >/dev/null
echo "Ingress argocd-server applied."

alb=""
for _ in $(seq 1 30); do
  alb=$(kubectl -n "$NS" get ingress argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [ -n "$alb" ] && break
  sleep 10
done
if [ -z "$alb" ]; then
  echo "::warning::The Argo CD ALB has no address yet. Check: kubectl -n kube-system logs deploy/aws-load-balancer-controller"
  exit 0
fi
bash deploy/dns-record.sh upsert "$ARGOCD_HOST" "$alb"
{
  echo "### Argo CD UI"
  echo "- https://${ARGOCD_HOST} (user \`admin\`, password = the ARGOCD_ADMIN_PASSWORD secret)"
  echo "- Reachable only from ARGOCD_ALLOWED_CIDR. A new ALB needs 2-3 minutes before it answers."
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
