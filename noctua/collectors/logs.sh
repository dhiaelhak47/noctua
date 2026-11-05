#!/usr/bin/env bash
set -euo pipefail

namespace=$1
pod=$2
tail_lines=${3:-50}

output=$(kubectl logs "$pod" -n "$namespace" --previous --tail="$tail_lines" 2>&1) || true

if [[ -z "$output" ]] || echo "$output" | grep -qiE "no previous (terminated|container)|not found"; then
  echo "No previous container logs available."
elif echo "$output" | grep -q "^error:"; then
  echo "No previous container logs available."
else
  echo "$output"
fi
