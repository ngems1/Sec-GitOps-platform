#!/usr/bin/env bash
# CI test of the resource usage report on testdata/: a Deployment with 2 replicas, a deleted pod
# and an HPA, a StatefulSet pod near its memory limit, a container without data, a container with
# no requests at all (boutique-prod), an extra namespace (kube-system, only in the cluster totals)
# and a finished Job pod (ignored).
set -euo pipefail
out=$(bash "$(dirname "$0")/render.sh" "$(dirname "$0")/testdata")
echo "$out"
fail() { echo "::error::resource usage report: $1"; exit 1; }
row() { grep -E "^$1 " <<<"$out" | tr -s ' '; }
# frontend: HPA 1-4 at 70%: p95 20m x 1.75 / 0.7 = 50m (above p95 x 1.5 = 30m and the max 40m);
# memory max 30 MiB x 1.3 = 39 -> 40
[ "$(row frontend/server)" = "frontend/server 2 1-4@70% 4 20 40 100 500 50 22 30 64 128 40 HPA" ] || fail "frontend row: $(row frontend/server)"
# argo-rollouts: p95 10.000000000000014m x 1.5 rounds up to 15m (not 20m: float noise), above max 12m
row argo-rollouts/argo-rollouts | grep -qE '^argo-rollouts/argo-rollouts 1 - 1 10 12 50 1000 15 ' || fail "argo-rollouts rounding: $(row argo-rollouts/argo-rollouts)"
# tempo: 960 MiB max of a 1 GiB limit; 960 x 1.3 = 1248 above the limit; 6.2 h of data
row tempo/tempo | grep -q 'MEM-OOM MEM-REQ>LIM SHORT-DATA(6.2h)' || fail "tempo flags: $(row tempo/tempo)"
row cartservice/server | grep -q 'NO-DATA$' || fail "cartservice without data"
# boutique-prod: a container with no requests is shown with "-", counted as 0, and does not stop
# the report (main failed here: "null (null) and number (1) cannot be multiplied")
[ "$(row loadgenerator/main)" = "loadgenerator/main 1 - 3 5 8 - - 10 20 24 - - 32 NO-REQUEST" ] || fail "no-request row: $(row loadgenerator/main)"
grep -q '1 container(s) with a request not set, counted as 0' <<<"$out" || fail "no note on the boutique-prod total"
grep -q '^monitoring$' <<<"$out" || fail "the monitoring table is missing"
grep -q 'old-job' <<<"$out" && fail "a finished pod is counted"
# Cluster: 650m requested now (coredns included; the container with no request counts 0); with
# suggestions 435m (cartservice keeps 200m, frontend 2 x 50m, loadgenerator 10m)
row 'requests now' | grep -q '^requests now 650 17% 710 11%$' || fail "cluster now: $(row 'requests now')"
row 'requests with suggestions' | grep -q '^requests with suggestions 435 11% 1566 24%$' || fail "cluster after: $(row 'requests with suggestions')"
echo "resource usage report: fixtures OK"
