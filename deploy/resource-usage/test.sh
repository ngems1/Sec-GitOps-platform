#!/usr/bin/env bash
# CI test of the resource usage report on testdata/: a Deployment with 2 replicas and a deleted
# pod, a StatefulSet pod near its memory limit, a container without data, an extra namespace
# (kube-system, only in the cluster totals) and a finished Job pod (ignored).
set -euo pipefail
out=$(bash "$(dirname "$0")/render.sh" "$(dirname "$0")/testdata")
echo "$out"
fail() { echo "::error::resource usage report: $1"; exit 1; }
row() { grep -E "^$1 " <<<"$out" | tr -s ' '; }
# frontend: p95 20m x 1.5 = 30m, but never below the max (40m); memory max 30 MiB x 1.3 = 39 -> 40
[ "$(row frontend/server)" = "frontend/server 2 4 20 40 100 500 40 22 30 64 128 40 " ] || fail "frontend row: $(row frontend/server)"
# argo-rollouts: p95 10.000000000000014m x 1.5 rounds up to 15m (not 20m: float noise), above max 12m
row argo-rollouts/argo-rollouts | grep -qE '^argo-rollouts/argo-rollouts 1 1 10 12 50 1000 15 ' || fail "argo-rollouts rounding: $(row argo-rollouts/argo-rollouts)"
# tempo: 960 MiB max of a 1 GiB limit; 960 x 1.3 = 1248 above the limit; 6.2 h of data
row tempo/tempo | grep -q 'MEM-OOM MEM-REQ>LIM SHORT-DATA(6.2h)' || fail "tempo flags: $(row tempo/tempo)"
row cartservice/server | grep -q 'NO-DATA$' || fail "cartservice without data"
grep -q 'old-job' <<<"$out" && fail "a finished pod is counted"
# Cluster: 650m requested now (coredns included); with suggestions 405m (cartservice keeps 200m)
row 'requests now' | grep -q '^requests now 650 17% 710 11%$' || fail "cluster now: $(row 'requests now')"
row 'requests with suggestions' | grep -q '^requests with suggestions 405 10% 1534 23%$' || fail "cluster after: $(row 'requests with suggestions')"
echo "resource usage report: fixtures OK"
