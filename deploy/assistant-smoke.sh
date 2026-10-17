#!/usr/bin/env bash
# One-off smoke test of the AI shopping assistant (ADR 0009, RUNBOOK section 15), after a deploy:
#
#   deploy/assistant-smoke.sh <shop URL> <namespace>
#   e.g. deploy/assistant-smoke.sh https://shop.example.com boutique-prod
#
# 1. Asks one question through the shop's /assistant page, as a shopper would (session cookie,
#    form post). Passes when the page answers with at least one link to a real catalog product
#    (src/productcatalogservice/products.json): the answer comes from the catalog tools.
# 2. Reads the frontend's and the assistant's logs since the question and fails if the question
#    text appears in them (RUNBOOK section 14: no question or answer text in the logs).
#
# Cost: one question, about USD 0.0004, one of the day's capped questions. Prints only the
# outcome and the product IDs it found (catalog data), never the answer or any log line: the
# repo is public, so Actions logs are public.
set -euo pipefail

url=${1:?shop URL}; url=${url%/}
ns=${2:?namespace}
cd "$(dirname "$0")/.."

marker="smoke-$(date +%s)-${RANDOM}"
question="Which products would you suggest for a picnic? (${marker})"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
since=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# A session cookie first (the frontend rate-limits per session), then the question.
curl -sS --max-time 20 -c "$work/jar" -b "$work/jar" -o /dev/null "${url}/assistant"
code=$(curl -sS --max-time 40 -c "$work/jar" -b "$work/jar" -o "$work/page.html" -w '%{http_code}' \
  --data-urlencode "question=${question}" "${url}/assistant")
[ "$code" = "200" ] || { echo "FAIL: POST /assistant answered HTTP ${code} (429: rate limit or daily cap; see RUNBOOK 15)"; exit 1; }

catalog=$(jq -r '.products[].id' src/productcatalogservice/products.json)
found=$(grep -oE '/product/[A-Z0-9]{10}' "$work/page.html" | cut -d/ -f3 | sort -u | grep -Fxf <(echo "$catalog") || true)
if [ -z "$found" ]; then
  echo "FAIL: the answer links no catalog product (not grounded, or the assistant answered with an error, pause or give-up message)"
  exit 1
fi
echo "OK: answer grounded in the catalog, products: $(echo "$found" | tr '\n' ' ')"

# The question must not be in any log line since it was asked (frontend pods include the
# canary's; all containers).
sleep 5
hits=0
for app in frontend shoppingassistantservice; do
  # A failed read must fail the test, not count as "no hits".
  kubectl -n "$ns" logs -l "app=${app}" --all-containers --since-time="$since" --tail=-1 --max-log-requests=10 \
    > "$work/${app}.log" 2>/dev/null \
    || { echo "FAIL: could not read the ${app} logs in ${ns}"; exit 1; }
  n=$(grep -cF "$marker" "$work/${app}.log" || true)
  echo "logs of ${app} since ${since}: ${n} line(s) with the question"
  hits=$((hits + n))
done
[ "$hits" -eq 0 ] || { echo "FAIL: the question text is in the logs (RUNBOOK section 14)"; exit 1; }
echo "OK: no question text in the frontend or assistant logs"
