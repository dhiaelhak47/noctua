#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
  echo "Usage: investigate.sh [-n namespace] [-o report.md] [--json] <namespace/pod | pod>"
  exit 1
}

namespace="default"
pod=""
output=""
json_out=false

while [[ $# -gt 0 ]]; do
  case $1 in
    -n|--namespace) namespace="$2"; shift 2 ;;
    -o|--output)    output="$2";    shift 2 ;;
    --json)         json_out=true;  shift   ;;
    -*)             usage ;;
    *)
      if [[ "$1" == */* ]]; then
        namespace="${1%%/*}"
        pod="${1#*/}"
      else
        pod="$1"
      fi
      shift
      ;;
  esac
done

[[ -z "$pod" ]] && usage

echo "Noctua investigating ${namespace}/${pod} …" >&2

# ── Bundle init ───────────────────────────────────────────────────────────────
if [[ -f /proc/sys/kernel/random/uuid ]]; then
  bundle_id=$(cat /proc/sys/kernel/random/uuid)
else
  bundle_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
fi
created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

evidence='[]'
idx=1

_add() {
  local kind=$1 source=$2 content=$3
  local item
  item=$(jq -n \
    --arg id      "E${idx}" \
    --arg kind    "$kind" \
    --arg source  "$source" \
    --arg content "$content" \
    --arg ts      "$created_at" \
    '{id:$id, kind:$kind, source:$source, content:$content, collected_at:$ts}')
  evidence=$(echo "$evidence" | jq --argjson item "$item" '. + [$item]')
  idx=$((idx + 1))
}

_warn() { echo "WARN: $*" >&2; }

# ── Collect ───────────────────────────────────────────────────────────────────
content=$("$SCRIPT_DIR/collectors/pod_status.sh" "$namespace" "$pod" 2>&1) || { _warn "pod_status failed"; content="ERROR: collection failed"; }
_add "pod_status" "pod_status" "$content"

content=$("$SCRIPT_DIR/collectors/events.sh" "$namespace" "$pod" 2>&1) || { _warn "events failed"; content="ERROR: collection failed"; }
_add "event" "events" "$content"

content=$("$SCRIPT_DIR/collectors/logs.sh" "$namespace" "$pod" 2>&1) || { _warn "logs failed"; content="No previous container logs available."; }
_add "log" "previous_container_logs" "$content"

content=$("$SCRIPT_DIR/collectors/rollout.sh" "$namespace" "$pod" 2>&1) || true
[[ -n "$content" ]] && _add "rollout" "rollout_history" "$content"

# ── Seal ──────────────────────────────────────────────────────────────────────
sha=$(echo "$evidence" | "$SCRIPT_DIR/seal.sh")

bundle=$(jq -n \
  --arg  bid "$bundle_id" \
  --arg  ns  "$namespace" \
  --arg  pod "$pod" \
  --arg  ts  "$created_at" \
  --arg  sha "$sha" \
  --argjson ev "$evidence" \
  '{
    bundle_id:      $bid,
    schema_version: "0.1",
    created_at:     $ts,
    namespace:      $ns,
    pod:            $pod,
    sha256:         $sha,
    evidence:       $ev,
    hypotheses:     []
  }')

# ── Analyse ───────────────────────────────────────────────────────────────────
hypotheses=$(echo "$bundle" | "$SCRIPT_DIR/analyst/rules.sh")
bundle=$(echo "$bundle" | jq --argjson h "$hypotheses" '.hypotheses = $h')

# ── Report ────────────────────────────────────────────────────────────────────
report=$(echo "$bundle" | "$SCRIPT_DIR/report.sh")

if [[ -n "$output" ]]; then
  echo "$report" > "$output"
  echo "Report → ${output}" >&2
  if $json_out; then
    json_path="${output%.md}.json"
    echo "$bundle" > "$json_path"
    echo "Bundle → ${json_path}" >&2
  fi
else
  echo "$report"
fi
