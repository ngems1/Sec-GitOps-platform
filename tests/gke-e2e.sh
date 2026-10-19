#!/usr/bin/env bash
# Smoke tests of the GKE shop through its public entry point (ADR 0014, decision 6):
# https://gke.<domain>, the GKE Ingress, its Google-managed certificate and the portable
# profile behind it. No cloud credential: plain HTTPS, like a shopper.
#
#   bash tests/gke-e2e.sh                     # https://gke.sebngembou-cloud.click
#   GKE_URL=https://gke.example.com bash tests/gke-e2e.sh
#
# Each check prints PASS or FAIL; exit 0 when all pass, 1 otherwise. A page passes on its HTTP
# status AND its content (a 200 can still be the frontend's error page, "Uh, oh"). curl
# verifies the certificate: an invalid or missing one fails every HTTPS check.
set -uo pipefail

url=${GKE_URL:-https://gke.sebngembou-cloud.click}
url=${url%/}
host=${url#https://}
[ "$url" != "$host" ] || { echo "GKE_URL must start with https:// (got ${url})"; exit 1; }

# Products of the catalog (src/productcatalogservice/products.json): id and name.
products=("OLJCESPC7Z Sunglasses" "66VCHSJNUP Tank Top" "1YMWWN1N4O Watch")

failed=0
body=$(mktemp); trap 'rm -f "$body"' EXIT
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1: $2"; failed=$((failed + 1)); }

# GET with retries on network errors only (not on HTTP errors): status in $code, page in $body.
get() {
  code=$(curl -sS -o "$body" -w '%{http_code}' --max-time 20 --retry 2 --retry-connrefused "$1" 2>/dev/null) || code="000"
}

# 1. HTTP -> HTTPS (FrontendConfig): a redirect, to https on the same host.
location=$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 20 --retry 2 "http://${host}/" 2>/dev/null) || location="000 "
code=${location%% *} target=${location#* }
if [[ "$code" =~ ^30[12]$ ]] && [[ "$target" == "https://${host}"* ]]; then
  pass "http://${host}/ redirects to HTTPS (${code})"
else
  fail "http://${host}/ redirects to HTTPS" "got ${code}, Location '${target}'"
fi

# A page: path, what it is, a text it must contain.
page() {
  get "${url}$1"
  if [ "$code" = 000 ]; then
    fail "$2 ($1)" "no HTTPS answer (DNS, connection or certificate error: curl -v ${url}$1)"
  elif [ "$code" != 200 ]; then
    fail "$2 ($1)" "HTTP ${code}, expected 200"
  elif grep -q "Uh, oh" "$body"; then
    fail "$2 ($1)" "HTTP 200 but the frontend's error page"
  elif ! grep -qF "$3" "$body"; then
    fail "$2 ($1)" "HTTP 200 but no '$3' in the page"
  else
    pass "$2 ($1): 200"
  fi
}

# 2. The home page: frontend, catalog, currency, ads, recommendations.
page / "home page" "${products[0]#* }"

# 3. Product pages.
for p in "${products[@]}"; do
  page "/product/${p%% *}" "product ${p#* }" "<h2>${p#* }</h2>"
done

# 4. The cart (cartservice and its Redis); a new visitor's cart is empty.
page /cart "cart page" "Your shopping cart is empty"

echo
if [ "$failed" = 0 ]; then
  echo "All checks passed: ${url}"
  exit 0
fi
echo "${failed} check(s) failed: ${url}"
exit 1
