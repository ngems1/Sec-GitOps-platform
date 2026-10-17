# Resource usage report (deploy/resource-usage.sh). Inputs (--slurpfile, each an array of one doc):
#   $cpu_avg $cpu_p95 $cpu_max $mem_p95 $mem_max $hours  Prometheus query results (per pod/container)
#   $pods      kubectl get pods -A -o json        (current requests and limits, replicas)
#   $workloads kubectl get deploy,sts,ds,job,rollouts -A -o json (names, to map pods to workloads)
#   $nodes     kubectl get nodes -o json          (allocatable)
#   $hpa       kubectl get hpa -A -o json         (min/max replicas and CPU target per workload)
# Output: tab-separated lines for `column`; "#" lines are headings.
# CPU in millicores (m), memory in MiB.

# Quantities: a value that cannot be parsed is treated as not set (null), never an error.
def cpu_m: if . == null then null else try (
  if test("m$") then (.[:-1] | tonumber)
  elif test("u$") then (.[:-1] | tonumber / 1000)
  elif test("n$") then (.[:-1] | tonumber / 1000000)
  else (tonumber * 1000) end) catch null end;
def mem_mi: if . == null or (tostring | test("^[0-9.]+[A-Za-z]*$") | not) then null else
  (capture("^(?<n>[0-9.]+)(?<u>[A-Za-z]*)$") as $q | ($q.n | tonumber) *
    ({"": 1, "Ki": 1024, "Mi": 1048576, "Gi": 1073741824, "Ti": 1099511627776,
      "k": 1000, "M": 1000000, "G": 1000000000, "T": 1000000000000}[$q.u] // 1) / 1048576) end;
# Rounds up to a multiple of $step, ignoring float noise (10.000000000000014 x 1.5 -> 15, not 20).
def ceil_to($step): if . == null then null else (((. / $step) - 0.000001) | ceil) * $step end;
def fmt: if . == null then "-" else (. | round | tostring) end;
def fmt1: if . == null then "-" else ((. * 10 | round) / 10 | tostring) end;

# Workload names per namespace (Deployments, StatefulSets, DaemonSets, Jobs, Rollouts).
def names: [$workloads[0].items[] | {ns: .metadata.namespace, name: .metadata.name}]
  | group_by(.ns) | map({key: .[0].ns, value: ([.[].name] | unique | sort_by(-length))}) | from_entries;
# A pod's workload: the longest workload name it starts with ("frontend-7d9f8c6b5d-abcde" ->
# frontend), also for pods deleted since; otherwise its name without the generated suffixes.
def workload($names; $ns; $pod):
  ([($names[$ns] // [])[] | select(. as $w | $pod | startswith($w + "-"))] | first)
  // ($pod | sub("-[a-z0-9]{5}$"; "") | sub("-[a-z0-9]{8,10}$"; ""));

names as $names
| def series($r; $scale): [$r[0].data.result[] | select(.value[1] != "NaN")
    | {key: "\(.metric.namespace)|\(workload($names; .metric.namespace; .metric.pod))|\(.metric.container)",
       v: ((.value[1] | tonumber) * $scale)}];
  def by_key(f): group_by(.key) | map({key: .[0].key, value: ([.[].v] | f)}) | from_entries;
  (series($cpu_avg; 1000) | by_key(add / length)) as $cavg
| (series($cpu_p95; 1000) | by_key(max)) as $cp95
| (series($cpu_max; 1000) | by_key(max)) as $cmax
| (series($mem_p95; 1 / 1048576) | by_key(max)) as $mp95
| (series($mem_max; 1 / 1048576) | by_key(max)) as $mmax
| (series($hours; 1) | by_key(max)) as $hrs
# HPAs by target workload (autoscaling/v2): min (1 when unset), max, CPU target %.
| ([$hpa[0].items[] | {key: "\(.metadata.namespace)|\(.spec.scaleTargetRef.name)",
     value: {min: (.spec.minReplicas // 1), max: .spec.maxReplicas,
             target: ([.spec.metrics[]? | select(.type == "Resource" and .resource.name == "cpu")
                       | .resource.target.averageUtilization] | first)}}] | from_entries) as $hpas
# Current containers of non-finished pods (init containers excluded: they do not run alongside).
# A request or limit that is not set stays null: shown as "-", counted as 0 in the totals.
| [$pods[0].items[] | select(.status.phase == "Running" or .status.phase == "Pending")
    | .metadata.namespace as $ns | .metadata.name as $pod
    | .spec.containers[]
    | {ns: $ns, wl: "\($ns)|\(workload($names; $ns; $pod))", key: "\($ns)|\(workload($names; $ns; $pod))|\(.name)",
       creq: (.resources.requests.cpu? | cpu_m), clim: (.resources.limits.cpu? | cpu_m),
       mreq: (.resources.requests.memory? | mem_mi), mlim: (.resources.limits.memory? | mem_mi)}] as $running
| ($running | map(select(.ns | IN("boutique-dev", "boutique-prod", "monitoring", "argo-rollouts")))) as $measured
| ($measured | group_by(.key) | map(.[0] + {replicas: length})
   | map(. as $c | $c + {
       cavg: $cavg[$c.key], cp95: $cp95[$c.key], cmax: $cmax[$c.key],
       mp95: $mp95[$c.key], mmax: $mmax[$c.key], hours: $hrs[$c.key], hpa: $hpas[$c.wl]})
   | map(. + {
       # Suggested request: CPU p95 x 1.5 (min 10m), memory max x 1.3 (min 32Mi), never below the
       # max seen. With a CPU HPA, also p95 / (target / 1.75): at 70% that is p95 / 0.4, so the HPA
       # target is reached only at about 1.75x today's p95 (a smaller request scales out sooner).
       csug: (if .cp95 == null then null else
                ([.cp95 * 1.5, 10, .cmax]
                 + (if .hpa.target != null then [.cp95 * 1.75 / (.hpa.target / 100)] else [] end)
                 | max | ceil_to(5)) end),
       msug: (if .mmax == null then null else ([.mmax * 1.3, 32] | max | ceil_to(8)) end)})
   | map(. + {flags: ([
       (if .hpa != null then "HPA" else empty end),
       (if .creq == null or .mreq == null then "NO-REQUEST" else empty end),
       (if .clim != null and .cmax != null and .cmax >= 0.9 * .clim then "CPU-THROTTLE" else empty end),
       (if .mlim != null and .mmax != null and .mmax >= 0.9 * .mlim then "MEM-OOM" else empty end),
       (if .clim != null and .csug != null and .csug > .clim then "CPU-REQ>LIM" else empty end),
       (if .mlim != null and .msug != null and .msug > .mlim then "MEM-REQ>LIM" else empty end),
       (if .cp95 == null then "NO-DATA" elif (.hours // 0) < 12 then "SHORT-DATA(\(.hours | fmt1)h)" else empty end)
     ] | join(" "))})) as $rows
| def mul($a; $b): if $a == null or $b == null then null else $a * $b end;
  def total(f): (map(f // 0) | add // 0);
  # Totals count every replica; a request that is not set counts as 0. Suggested falls back to
  # the current request without data.
  def totals: {cnow: total(mul(.creq; .replicas)), csug: total(mul(.csug // .creq; .replicas)),
               mnow: total(mul(.mreq; .replicas)), msug: total(mul(.msug // .mreq; .replicas)),
               unset: (map(select(.creq == null or .mreq == null)) | length)};
  def hpa_cell: if .hpa == null then "-" else "\(.hpa.min)-\(.hpa.max)@\(.hpa.target // "?")%" end;
  ($rows | group_by(.ns)) as $byns
# One namespace failing (an unexpected value) never stops the others: its error is printed instead.
| ($byns[] | .[0].ns as $ns |
    "# \($ns)",
    (try (
      (["WORKLOAD/CONTAINER", "REPL", "HPA", "CPU(m) avg", "p95", "max", "req", "lim", "SUGGEST",
        "MEM(Mi) p95", "max", "req", "lim", "SUGGEST", "FLAGS"] | join("\t")),
      (sort_by(.key)[] | [(.key | split("|") | "\(.[1])/\(.[2])"), (.replicas | tostring), hpa_cell,
        (.cavg | fmt), (.cp95 | fmt), (.cmax | fmt), (.creq | fmt), (.clim | fmt), (.csug | fmt),
        (.mp95 | fmt), (.mmax | fmt), (.mreq | fmt), (.mlim | fmt), (.msug | fmt), .flags] | join("\t")),
      (totals | "TOTAL (all replicas)\t\t\t\t\t\t\(.cnow | fmt)\t\t\(.csug | fmt)\t\t\t\(.mnow | fmt)\t\t\(.msug | fmt)\t"
        + (if .unset > 0 then "\(.unset) container(s) with a request not set, counted as 0" else "" end))
    ) catch "ERROR\tthis namespace could not be reported: \(.)"),
    "")
, ( "# Cluster (all namespaces, \($nodes[0].items | length) nodes)",
    (try (
      ([$nodes[0].items[].status.allocatable | {c: (.cpu | cpu_m), m: (.memory | mem_mi)}]) as $alloc
      | ($alloc | map(.c) | add) as $acpu | ($alloc | map(.m) | add) as $amem
      | ($running | total(.creq)) as $call | ($running | total(.mreq)) as $mall
      | ($rows | totals) as $t
      | ($call - $t.cnow + $t.csug) as $cafter | ($mall - $t.mnow + $t.msug) as $mafter
      | (["", "CPU (m)", "% of allocatable", "MEMORY (Mi)", "% of allocatable"] | join("\t")),
        (["allocatable", ($acpu | fmt), "100%", ($amem | fmt), "100%"] | join("\t")),
        (["requests now", ($call | fmt), "\($call / $acpu * 100 | round)%", ($mall | fmt), "\($mall / $amem * 100 | round)%"] | join("\t")),
        (["requests with suggestions", ($cafter | fmt), "\($cafter / $acpu * 100 | round)%", ($mafter | fmt), "\($mafter / $amem * 100 | round)%"] | join("\t")),
        (["headroom now", ($acpu - $call | fmt), "", ($amem - $mall | fmt), ""] | join("\t")),
        (["headroom with suggestions", ($acpu - $cafter | fmt), "", ($amem - $mafter | fmt), ""] | join("\t"))
    ) catch "ERROR\tthe cluster totals could not be computed: \(.)"))
