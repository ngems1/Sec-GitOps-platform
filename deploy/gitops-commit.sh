#!/usr/bin/env bash
# Records an environment's version in Git: gitops/<env>/values.yaml is what Argo CD deploys
# (the names Terraform created for that environment + the image tag). Run by deploy-env.yml,
# from main only. GITOPS_ENV selects the environment (default dev).
#   dev:
#     gitops-commit.sh commit                  write the file from values-terraform.json and $TAG, push to main
#     gitops-commit.sh revert <sha>            revert that commit (rollback) and push to main
#   prod (ADR 0007: Argo CD reads prod from the promotion branch named in
#   deploy/argocd/boutique-prod.yaml, which only this script moves):
#     gitops-commit.sh promote <validated>     refuse if main changed outside gitops/ since
#                                              <validated> (the commit dev was checked at); write
#                                              the file, push to main, then move the promotion
#                                              branch to that main commit (fast-forward)
#     gitops-commit.sh restore <previous> [<sha>]
#                                              put the promotion branch back on <previous> and
#                                              revert <sha> on main (rollback)
# Needs a full checkout of main in ./gitops-repo made with a GitHub App token (the App is
# the bypass actor of the main ruleset), GH_TOKEN (the same token) and APP_SLUG.
# Prints the new head of main (restore: the promotion branch). Step outputs: "commit" (empty
# when nothing changed), "revision" (what Argo CD should sync) and, for promote, "previous"
# (the promotion branch before the move; empty the first time).
set -euo pipefail
mode=${1:?commit, revert, promote or restore}
repo=gitops-repo
env=${GITOPS_ENV:-dev}
file=gitops/${env}/values.yaml

if [ -z "${GH_TOKEN:-}" ] || [ -z "${APP_SLUG:-}" ]; then
  echo "::error::No GitHub App token. Set the ${env} environment variable GITOPS_APP_ID and secret GITOPS_APP_PRIVATE_KEY (docs/week3/ARGOCD.md)." >&2
  exit 1
fi

case "$mode" in
  commit | revert) [ "$env" = dev ] || { echo "::error::${mode} is for dev; prod uses promote/restore." >&2; exit 2; } ;;
  promote | restore)
    [ "$env" = prod ] || { echo "::error::${mode} is for prod only." >&2; exit 2; }
    branch=$(sed -n 's/^ *targetRevision: *//p' deploy/argocd/boutique-prod.yaml)
    [ -n "$branch" ] && [ "$branch" != main ] || { echo "::error::No promotion branch in deploy/argocd/boutique-prod.yaml." >&2; exit 1; }
    ;;
esac

# Commits are made by the App's bot user.
bot_id=$(gh api "users/${APP_SLUG}%5Bbot%5D" --jq .id)
git -C "$repo" config user.name "${APP_SLUG}[bot]"
git -C "$repo" config user.email "${bot_id}+${APP_SLUG}[bot]@users.noreply.github.com"

# Keeps the file's comment header. sesRecipients (people's addresses) stays out of Git.
write_values() {
  {
    sed -n '/^#/p' "$repo/$file"
    jq --arg tag "$TAG" 'del(.emailService.notifications.sesRecipients) | .images.tag = $tag' values-terraform.json
  } > "$repo/$file.new"
  mv "$repo/$file.new" "$repo/$file"
}

# Head of the promotion branch on GitHub (empty when it doesn't exist yet).
branch_head() { git -C "$repo" ls-remote origin "refs/heads/${branch}" | cut -f1; }

previous=""
if [ "$mode" = promote ]; then
  validated=${2:?commit dev was validated at}
  previous=$(branch_head)
fi

commit=""
for attempt in 1 2 3; do
  git -C "$repo" fetch --quiet origin main
  git -C "$repo" reset --quiet --hard origin/main
  case "$mode" in
    commit | promote)
      : "${TAG:?}"
      if [ "$mode" = promote ]; then
        # Prod gets exactly what dev was checked with: nothing but gitops/ may have changed.
        changed=$(git -C "$repo" diff --name-only "$validated" HEAD -- . ':(exclude)gitops/')
        if [ -n "$changed" ]; then
          echo "::error::main changed since dev was checked at ${validated:0:12} (not only gitops/): $(tr '\n' ' ' <<<"$changed"). Deploy again so dev checks it first." >&2
          exit 1
        fi
      fi
      write_values
      if git -C "$repo" diff --quiet -- "$file"; then
        echo "Git already has ${env} at ${TAG}, nothing to commit." >&2
        break
      fi
      git -C "$repo" add "$file"
      git -C "$repo" commit --quiet -m "gitops: ${env} image tag ${TAG} [skip ci]"
      ;;
    revert)
      git -C "$repo" revert --no-edit "${2:?commit to revert}" >/dev/null
      ;;
    restore)
      [ -n "${3:-}" ] || break # nothing was committed: only the branch moves back
      git -C "$repo" revert --no-edit "$3" >/dev/null
      ;;
    *)
      echo "usage: $0 commit | revert <sha> | promote <validated> | restore <previous> [<sha>]" >&2
      exit 2
      ;;
  esac
  if git -C "$repo" push --quiet origin HEAD:main; then
    commit=$(git -C "$repo" rev-parse HEAD)
    echo "Pushed ${commit:0:12} to main." >&2
    break
  fi
  if [ "$attempt" = 3 ]; then
    echo "::error::Could not push to main after 3 tries." >&2
    exit 1
  fi
  echo "main moved, trying again (${attempt}/3)." >&2
  sleep 5
done

revision=$(git -C "$repo" rev-parse HEAD)

case "$mode" in
  promote)
    # Fast-forward only: main only moves forward, so the branch always can.
    git -C "$repo" push --quiet origin "${revision}:refs/heads/${branch}"
    echo "Promotion branch ${branch} moved to ${revision:0:12} (was ${previous:0:12})." >&2
    ;;
  restore)
    target=${2:?previous head of the promotion branch}
    git -C "$repo" fetch --quiet origin "refs/heads/${branch}"
    git -C "$repo" push --quiet --force-with-lease="refs/heads/${branch}:$(git -C "$repo" rev-parse FETCH_HEAD)" \
      origin "${target}:refs/heads/${branch}"
    echo "Promotion branch ${branch} put back on ${target:0:12}." >&2
    revision=$target
    ;;
esac

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  { echo "commit=${commit}"; echo "revision=${revision}"; echo "previous=${previous}"; } >> "$GITHUB_OUTPUT"
fi
echo "$revision"
