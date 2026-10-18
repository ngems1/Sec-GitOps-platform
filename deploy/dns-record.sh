#!/usr/bin/env bash
# Points a name of our Route 53 zone at a load balancer, or removes it.
#   dns-record.sh upsert   <name> <alb-hostname>   an ALB created by Kubernetes (alias record)
#                                                  e.g. upsert dev.example.com boutique-dev-123.us-east-1.elb.amazonaws.com
#   dns-record.sh upsert-a <name> <ipv4>           a fixed IPv4 outside AWS: the GKE Ingress's
#                                                  static IP (ADR 0014), e.g. upsert-a gke.example.com 203.0.113.10
#   dns-record.sh delete   <name>                  either kind
# Needs DNS_ZONE_ID (Terraform output tls.zone_id) and AWS credentials.
set -euo pipefail
: "${DNS_ZONE_ID:?}"
action=${1:?upsert|upsert-a|delete}
name=${2:?record name}
name=${name%.}

case "$action" in
  upsert)
    alb=${3:?ALB hostname}
    # Alias record: free, follows the ALB's IPs, no TTL to wait for.
    canonical=$(aws elbv2 describe-load-balancers \
      --query "LoadBalancers[?DNSName=='${alb}'].CanonicalHostedZoneId | [0]" --output text)
    [ -n "$canonical" ] && [ "$canonical" != None ] || { echo "::error::no load balancer named ${alb}"; exit 1; }
    jq -n --arg name "$name" --arg alb "$alb" --arg zone "$canonical" '{
      Comment: "week3: points at an ALB created by Kubernetes",
      Changes: [{ Action: "UPSERT", ResourceRecordSet: {
        Name: $name, Type: "A",
        AliasTarget: { HostedZoneId: $zone, DNSName: ("dualstack." + $alb), EvaluateTargetHealth: false }
      } }]
    }' > dns-change.json
    aws route53 change-resource-record-sets --hosted-zone-id "$DNS_ZONE_ID" \
      --change-batch file://dns-change.json --query 'ChangeInfo.Status' --output text
    rm -f dns-change.json
    echo "${name} -> ${alb}"
    ;;
  upsert-a)
    ip=${3:?IPv4 address}
    # Exactly one public IPv4: no alias exists for an address outside AWS.
    if ! [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] \
       || (( BASH_REMATCH[1] > 255 || BASH_REMATCH[2] > 255 || BASH_REMATCH[3] > 255 || BASH_REMATCH[4] > 255 )); then
      echo "::error::${ip}: not an IPv4 address"; exit 1
    fi
    # TTL 300: a new address (terraform-gcp rebuilt) is followed within minutes.
    jq -n --arg name "$name" --arg ip "$ip" '{
      Comment: "points at the GKE Ingress static IP (terraform-gcp)",
      Changes: [{ Action: "UPSERT", ResourceRecordSet: {
        Name: $name, Type: "A", TTL: 300, ResourceRecords: [{ Value: $ip }]
      } }]
    }' > dns-change.json
    aws route53 change-resource-record-sets --hosted-zone-id "$DNS_ZONE_ID" \
      --change-batch file://dns-change.json --query 'ChangeInfo.Status' --output text
    rm -f dns-change.json
    echo "${name} -> ${ip}"
    ;;
  delete)
    # Remove the record exactly as it is (Route 53 needs the current values to delete it).
    aws route53 list-resource-record-sets --hosted-zone-id "$DNS_ZONE_ID" \
      --query "ResourceRecordSets[?Name=='${name}.' && Type=='A']" --output json > dns-current.json
    if [ "$(jq length dns-current.json)" = 0 ]; then
      echo "${name}: no record"
    else
      jq '{Changes: [.[] | {Action: "DELETE", ResourceRecordSet: .}]}' dns-current.json > dns-change.json
      aws route53 change-resource-record-sets --hosted-zone-id "$DNS_ZONE_ID" \
        --change-batch file://dns-change.json --query 'ChangeInfo.Status' --output text
      echo "${name}: deleted"
    fi
    rm -f dns-current.json dns-change.json
    ;;
  *) echo "usage: $0 upsert <name> <alb-hostname> | upsert-a <name> <ipv4> | delete <name>"; exit 1 ;;
esac
