#!/usr/bin/env bash
set -euo pipefail

namespace=$1
pod=$2
limit=${3:-50}

events_json=$(kubectl get events \
  -n "$namespace" \
  --field-selector "involvedObject.name=${pod}" \
  --sort-by='.lastTimestamp' \
  -o json 2>&1) || { echo "No events found."; exit 0; }

count=$(echo "$events_json" | jq '.items | length')
if [[ "$count" -eq 0 ]]; then
  echo "No events found."
  exit 0
fi

printf "%-20s %-10s %-25s %s\n" "Last Seen" "Type" "Reason" "Message"
printf "%s\n" "--------------------------------------------------------------------------------"

echo "$events_json" | jq -r --argjson limit "$limit" '
  .items[0:$limit][] |
  [
    (.lastTimestamp // .eventTime // "" | .[0:19]),
    (.type    // ""),
    (.reason  // ""),
    ((.message // "") | .[0:100])
  ] | @tsv
' | while IFS=$'\t' read -r last type reason message; do
  printf "%-20s %-10s %-25s %s\n" "$last" "$type" "$reason" "$message"
done
