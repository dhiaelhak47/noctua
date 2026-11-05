#!/usr/bin/env bash
set -euo pipefail

namespace=$1
pod=$2

pod_json=$(kubectl get pod "$pod" -n "$namespace" -o json 2>/dev/null) || { exit 0; }

rs_name=$(echo "$pod_json" | jq -r '
  .metadata.ownerReferences // []
  | map(select(.kind == "ReplicaSet"))
  | .[0].name // empty')

if [[ -z "$rs_name" ]]; then
  echo "Pod has no ReplicaSet owner (not managed by a Deployment)."
  exit 0
fi

rs_json=$(kubectl get rs "$rs_name" -n "$namespace" -o json 2>/dev/null) || { exit 0; }

dep_name=$(echo "$rs_json" | jq -r '
  .metadata.ownerReferences // []
  | map(select(.kind == "Deployment"))
  | .[0].name // empty')

if [[ -z "$dep_name" ]]; then
  echo "ReplicaSet ${rs_name} has no Deployment owner."
  exit 0
fi

dep_json=$(kubectl get deployment "$dep_name" -n "$namespace" -o json 2>/dev/null) || { exit 0; }

ready=$(echo "$dep_json" | jq -r '.status.readyReplicas // 0')
total=$(echo "$dep_json" | jq -r '.status.replicas     // 0')

label_sel=$(echo "$dep_json" | jq -r '
  .spec.selector.matchLabels
  | to_entries
  | map("\(.key)=\(.value)")
  | join(",")')

rs_list=$(kubectl get rs -n "$namespace" -l "$label_sel" -o json 2>/dev/null) || rs_list='{"items":[]}'

echo "Deployment: ${namespace}/${dep_name}"
echo "Ready replicas: ${ready}/${total}"
echo ""
printf "%-6s %-45s %s\n" "Rev" "ReplicaSet" "Image"
printf "%s\n" "------------------------------------------------------------------------------------------"

echo "$rs_list" | jq -r --arg current "$rs_name" '
  .items[]
  | select(.metadata.annotations["deployment.kubernetes.io/revision"] != null)
  | [
      (.metadata.annotations["deployment.kubernetes.io/revision"] | tonumber),
      .metadata.name,
      (.spec.template.spec.containers[0].image // "unknown"),
      (if .metadata.name == $current then " ← current" else "" end)
    ]
  | @tsv
' | sort -n | while IFS=$'\t' read -r rev rs_n image marker; do
  printf "%-6s %-45s %s%s\n" "$rev" "$rs_n" "$image" "$marker"
done
