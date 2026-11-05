#!/usr/bin/env bash
set -euo pipefail

namespace=$1
pod=$2

pod_json=$(kubectl get pod "$pod" -n "$namespace" -o json 2>&1) || {
  echo "ERROR: failed to get pod ${namespace}/${pod}"
  exit 1
}

phase=$(echo "$pod_json" | jq -r '.status.phase // "Unknown"')
out="Pod: ${namespace}/${pod}"$'\n'"Phase: ${phase}"

count=$(echo "$pod_json" | jq '.status.containerStatuses // [] | length')

for i in $(seq 0 $((count - 1))); do
  cs=$(echo "$pod_json" | jq ".status.containerStatuses[$i]")
  name=$(echo "$cs"    | jq -r '.name')
  ready=$(echo "$cs"   | jq -r '.ready')
  restarts=$(echo "$cs"| jq -r '.restartCount')
  image=$(echo "$cs"   | jq -r '.image')

  out+=$'\n'"Container: ${name}"
  out+=$'\n'"  Ready: ${ready}"
  out+=$'\n'"  RestartCount: ${restarts}"
  out+=$'\n'"  Image: ${image}"

  waiting_reason=$(echo "$cs" | jq -r '.state.waiting.reason  // empty')
  waiting_msg=$(echo "$cs"    | jq -r '.state.waiting.message // empty')
  running_at=$(echo "$cs"     | jq -r '.state.running.startedAt // empty')
  term_reason=$(echo "$cs"    | jq -r '.state.terminated.reason   // empty')
  term_exit=$(echo "$cs"      | jq -r '.state.terminated.exitCode // empty')
  lt_reason=$(echo "$cs"      | jq -r '.lastState.terminated.reason   // empty')
  lt_exit=$(echo "$cs"        | jq -r '.lastState.terminated.exitCode // empty')

  if [[ -n "$waiting_reason" ]]; then
    out+=$'\n'"  State: Waiting (${waiting_reason})"
    [[ -n "$waiting_msg" ]] && out+=$'\n'"  Message: ${waiting_msg}"
  elif [[ -n "$running_at" ]]; then
    out+=$'\n'"  State: Running (started ${running_at})"
  elif [[ -n "$term_reason" ]]; then
    out+=$'\n'"  State: Terminated (reason=${term_reason}, exitCode=${term_exit})"
  fi

  if [[ -n "$lt_reason" ]]; then
    out+=$'\n'"  LastState: Terminated (reason=${lt_reason}, exitCode=${lt_exit})"
  fi
done

echo "$out"
