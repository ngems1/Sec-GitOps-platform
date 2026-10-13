#!/usr/bin/env bash
# Records the dev version in Git: gitops/dev/values.yaml is what Argo CD deploys to
# boutique-dev (the names Terraform created for dev + the image tag). Run by
# deploy-env.yml, from main only.
#   gitops-commit.sh commit         write the file from values-terraform.json and $TAG, push to main
#   gitops-commit.sh revert <sha>   revert that commit (rollback) and push to main
# Needs a full checkout of main in ./gitops-repo made with a GitHub App token (the App is
# the bypass actor of the main ruleset), GH_TOKEN (the same token) and APP_SLUG.
# Prints the new head of main. Step outputs: "commit" (empty when nothing changed) and
# "revision" (head of main).
set -euo pipefail
mode=${1:?commit or revert}
repo=gitops-repo
file=gitops/dev/values.yaml

if [ -z "${GH_TOKEN:-}" ] || [ -z "${APP_SLUG:-}" ]; then
  echo "::error::No GitHub App token. Set the dev environment variable GITOPS_APP_ID and secret GITOPS_APP_PRIVATE_KEY (docs/week3/ARGOCD.md)." >&2
  exit 1
fi

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

commit=""
for attempt in 1 2 3; do
  git -C "$repo" fetch --quiet origin main
  git -C "$repo" reset --quiet --hard origin/main
  case "$mode" in
    commit)
      : "${TAG:?}"
      write_values
      if git -C "$repo" diff --quiet -- "$file"; then
        echo "Git already has dev at ${TAG}, nothing to commit." >&2
        break
      fi
      git -C "$repo" add "$file"
      git -C "$repo" commit --quiet -m "gitops: dev image tag ${TAG} [skip ci]"
      ;;
    revert)
      git -C "$repo" revert --no-edit "${2:?commit to revert}" >/dev/null
      ;;
    *)
      echo "usage: $0 commit | revert <sha>" >&2
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
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  { echo "commit=${commit}"; echo "revision=${revision}"; } >> "$GITHUB_OUTPUT"
fi
echo "$revision"
