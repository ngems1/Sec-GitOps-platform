#!/usr/bin/env bash
# Read-only snapshot of a namespace: why pods aren't ready.
#   diagnose.sh <namespace>
# Pods, recent events (image pulls, scheduling, failed probes), and for every pod
# that isn't fully ready: the end of "describe" and its logs (current + previous).
set -u
ns="${1:?namespace}"

echo "=== ${ns}: pods ==="
kubectl -n "$ns" get pods -o wide 2>&1
echo
echo "=== ${ns}: ingress / services ==="
kubectl -n "$ns" get ingress,svc 2>&1
echo
echo "=== ${ns}: recent events ==="
kubectl -n "$ns" get events --sort-by=.lastTimestamp 2>&1 | tail -40
for pod in $(kubectl -n "$ns" get pods --no-headers 2>/dev/null | awk '$3 != "Completed" {split($2, r, "/")} $3 != "Completed" && (r[1] != r[2] || $3 != "Running") {print $1}'); do
  echo
  echo "=== ${pod}: describe (end) ==="
  kubectl -n "$ns" describe pod "$pod" 2>&1 | tail -25
  echo "=== ${pod}: logs ==="
  kubectl -n "$ns" logs "$pod" --all-containers --tail=40 2>&1
  echo "=== ${pod}: logs before the last restart ==="
  kubectl -n "$ns" logs "$pod" --all-containers --previous --tail=40 2>/dev/null || echo "(none)"
done
echo
echo "=== ${ns}: autoscalers (current/target CPU, replicas) ==="
kubectl -n "$ns" get hpa 2>&1
# A pod can be Ready again after a restart, so the loop above skips it: show why each
# container last stopped (OOMKilled = memory limit, Error/exit 137 + probe events = liveness).
echo
echo "=== ${ns}: containers that restarted (last exit) ==="
kubectl -n "$ns" get pods -o custom-columns='POD:.metadata.name,RESTARTS:.status.containerStatuses[*].restartCount,LAST_REASON:.status.containerStatuses[*].lastState.terminated.reason,EXIT_CODE:.status.containerStatuses[*].lastState.terminated.exitCode,STOPPED_AT:.status.containerStatuses[*].lastState.terminated.finishedAt' 2>&1 | awk 'NR==1 || $2 ~ /[1-9]/'
kubectl -n "$ns" get events --field-selector reason=Unhealthy 2>/dev/null | grep -i liveness | tail -10
# HPAs at <unknown>: is the metrics API answering, and on which port do its pods listen?
if [ "$ns" = kube-system ]; then
  echo
  echo "=== metrics API (used by the HPAs) ==="
  kubectl get apiservice v1beta1.metrics.k8s.io -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}' 2>&1
  kubectl -n kube-system get pods -l app.kubernetes.io/name=metrics-server -o jsonpath='{range .items[*]}{.metadata.name}{" ports="}{.spec.containers[*].ports[*].containerPort}{"\n"}{end}' 2>&1
  kubectl top nodes 2>&1 | head -6
fi
# Grafana runs even when a plugin fails to load, so its pod looks healthy:
# show its plugin messages and the container setup (read-only disk, mounted folders).
if [ "$ns" = monitoring ]; then
  gpod=$(kubectl -n "$ns" get pods -l app.kubernetes.io/name=grafana -o name 2>/dev/null | head -1)
  if [ -n "$gpod" ]; then
    echo
    echo "=== ${gpod}: grafana container (security context, mounts) ==="
    kubectl -n "$ns" get "$gpod" -o jsonpath='{range .spec.containers[?(@.name=="grafana")]}securityContext: {.securityContext}{"\n"}{range .volumeMounts[*]}mount: {.mountPath}{" ro="}{.readOnly}{"\n"}{end}{end}' 2>&1
    echo "=== ${gpod}: plugin / error messages ==="
    kubectl -n "$ns" logs "$gpod" -c grafana 2>&1 | grep -iE 'plugin|prometheus|level=(error|warn)' | grep -v 'level=debug' | head -60
    # Which AWS identity Grafana's CloudWatch data source uses (ADR 0011): its Pod Identity role,
    # not the node role. Read-only; prints the role name and variable names, never values.
    #   1. the Pod Identity association of monitoring/grafana and its role;
    #   2. the Grafana pod has the Pod Identity variables (the AWS SDK's default chain uses them
    #      before the node's instance metadata);
    #   3. the pod started after the association (the variables are injected at pod creation).
    echo "=== Grafana's AWS identity (CloudWatch data source, Pod Identity) ==="
    cluster=$(kubectl config current-context 2>/dev/null | sed 's#.*/##')
    assoc=$(aws eks list-pod-identity-associations --cluster-name "$cluster" --namespace "$ns" \
              --service-account grafana --query 'associations[0].associationId' --output text 2>&1)
    if [ -z "$assoc" ] || [ "$assoc" = "None" ] || [[ "$assoc" == *rror* ]]; then
      echo "  NO Pod Identity association for ${ns}/grafana: Grafana would fall back to the node role (${assoc})"
    else
      read -r role created < <(aws eks describe-pod-identity-association --cluster-name "$cluster" \
        --association-id "$assoc" --query 'association.[roleArn, createdAt]' --output text 2>&1)
      echo "  association ${assoc}: role ${role##*/} (created ${created})"
      [ "${role##*/}" = "week3-boutique-grafana-cloudwatch" ] || echo "  WARNING: expected role week3-boutique-grafana-cloudwatch"
      envnames=$(kubectl -n "$ns" get "$gpod" -o jsonpath='{range .spec.containers[?(@.name=="grafana")].env[*]}{.name}{"\n"}{end}' 2>/dev/null)
      for v in AWS_CONTAINER_CREDENTIALS_FULL_URI AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE; do
        if grep -qx "$v" <<< "$envnames"; then echo "  pod env: ${v} set"; else echo "  pod env: ${v} MISSING (restart Grafana)"; fi
      done
      started=$(kubectl -n "$ns" get "$gpod" -o jsonpath='{.metadata.creationTimestamp}')
      if [ "$(date -u -d "$started" +%s 2>/dev/null || echo 0)" -ge "$(date -u -d "$created" +%s 2>/dev/null || echo 0)" ]; then
        echo "  pod created ${started}, after the association: uses the role above"
      else
        echo "  pod created ${started}, BEFORE the association: restart Grafana to pick up the role"
      fi
    fi
    # CloudWatch panels empty? Same queries as the dashboard, straight to AWS (workflow role):
    # series found here but not in Grafana = a Grafana problem; none here = no data in AWS.
    # Search terms are unquoted token matches (a quoted term must equal a whole dimension value;
    # RUNBOOK section 5). Each query prints its series, CloudWatch's messages (errors, partial
    # data), or "NO series" when CloudWatch matched nothing and reported no error.
    echo "=== CloudWatch: dashboard queries run directly against AWS (last hour) ==="
    end=$(date -u +%Y-%m-%dT%H:%M:%SZ); start=$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)
    for q in \
      "rds_cpu|SEARCH('{AWS/RDS,DBInstanceIdentifier} MetricName=\"CPUUtilization\" week3-boutique', 'Average', 300)" \
      "sqs_waiting|SEARCH('{AWS/SQS,QueueName} MetricName=\"ApproximateNumberOfMessagesVisible\" week3-boutique', 'Maximum', 60)" \
      "alb_requests_dev|SEARCH('{AWS/ApplicationELB,LoadBalancer} MetricName=\"RequestCount\" boutique-dev', 'Sum', 60)" \
      "alb_requests_prod|SEARCH('{AWS/ApplicationELB,LoadBalancer} MetricName=\"RequestCount\" boutique-prod', 'Sum', 60)"; do
      id=${q%%|*}; expr=${q#*|}
      jq -n --arg id "$id" --arg e "$expr" '[{Id: $id, Expression: $e, ReturnData: true}]' > cw-q.json
      if ! out=$(aws cloudwatch get-metric-data --metric-data-queries file://cw-q.json \
                   --start-time "$start" --end-time "$end" --output json 2>&1); then
        echo "  ${id}: ERROR (aws cli): $(printf '%s' "$out" | tail -1)"
        continue
      fi
      printf '%s' "$out" | jq -r --arg id "$id" '
        ([.Messages[]? | "  \($id): ERROR (CloudWatch): \(.Code // "") \(.Value // "")"]) as $top
        | ([.MetricDataResults[]? | "  \($id): \(.Label) \(.Values | length) points (\(.StatusCode))"
              + ([.Messages[]? | " [\(.Code // ""): \(.Value // "")]"] | join(""))]) as $series
        | ($top + $series) as $lines
        | if ($lines | length) == 0 then "  \($id): NO series (no metric matched, no error)" else $lines[] end'
    done
    rm -f cw-q.json
    # Grafana's CloudWatch plugin logs (last 40 lines).
    echo "=== ${gpod}: CloudWatch plugin messages (latest) ==="
    kubectl -n "$ns" logs "$gpod" -c grafana 2>&1 | grep -iE 'cloudwatch|tsdb\.|aws' | tail -40
  fi
fi
exit 0
