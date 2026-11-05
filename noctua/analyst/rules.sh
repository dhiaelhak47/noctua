#!/usr/bin/env bash
set -euo pipefail
# stdin or file arg: bundle JSON → stdout: hypotheses JSON array

# ── Helpers ───────────────────────────────────────────────────────────────────
_extract_env_var() {
  local text=$1
  local var=""

  # Pattern: KeyError: 'DATABASE_URL'
  var=$(echo "$text" | grep -oE "KeyError: '[A-Z][A-Z0-9_]+'" \
        | sed "s/KeyError: '//;s/'//" | head -1 2>/dev/null) || var=""
  [[ -n "$var" ]] && { echo "$var"; return; }

  # Pattern: $VAR_NAME is not set / unset / undefined / missing
  var=$(echo "$text" | grep -oiE '\$[A-Z][A-Z0-9_]{3,} (is )?(not set|unset|undefined|missing)' \
        | grep -oE '[A-Z][A-Z0-9_]+' | head -1 2>/dev/null) || var=""
  [[ -n "$var" ]] && { echo "$var"; return; }

  # Pattern: missing env var: VAR_NAME  /  environment variable: VAR_NAME
  var=$(echo "$text" | grep -iE 'missing (env var|environment variable)' \
        | grep -oE '[A-Z][A-Z0-9_]{3,}' | tail -1 2>/dev/null) || var=""
  [[ -n "$var" ]] && { echo "$var"; return; }

  echo ""
}

bundle=$(cat "${1:-/dev/stdin}")

ps_content=$(echo "$bundle"  | jq -r '[.evidence[] | select(.kind=="pod_status") | .content] | join("\n")')
log_content=$(echo "$bundle" | jq -r '[.evidence[] | select(.kind=="log")        | .content] | join("\n")')
ev_content=$(echo "$bundle"  | jq -r '[.evidence[] | select(.kind=="event")      | .content] | join("\n")')

ps_ids=$(echo "$bundle"  | jq '[.evidence[] | select(.kind=="pod_status") | .id]')
log_ids=$(echo "$bundle" | jq '[.evidence[] | select(.kind=="log")        | .id]')
ev_ids=$(echo "$bundle"  | jq '[.evidence[] | select(.kind=="event")      | .id]')

hypotheses='[]'

# ── Rule: OOMKilled (high specificity — check before CrashLoop) ───────────────
if echo "$ps_content" | grep -q "OOMKilled"; then
  hypotheses=$(echo "$hypotheses" | jq \
    --argjson ids "$ps_ids" \
    '. + [{
      rank: 0,
      rule: "oomkilled",
      description: "Container was OOM-killed. Memory limit is too low for the current workload.",
      evidence_ids: $ids,
      confidence: 0.90,
      action: "raise memory limit in Helm values and redeploy"
    }]')
fi

# ── Rule: ImagePullBackOff / ErrImagePull ─────────────────────────────────────
combined_ps_ev="${ps_content}"$'\n'"${ev_content}"
if echo "$combined_ps_ev" | grep -qE "ImagePullBackOff|ErrImagePull"; then
  all_ids=$(jq -n --argjson ps "$ps_ids" --argjson ev "$ev_ids" '$ps + $ev | unique')
  hypotheses=$(echo "$hypotheses" | jq \
    --argjson ids "$all_ids" \
    '. + [{
      rank: 0,
      rule: "image_pull_backoff",
      description: "Container image cannot be pulled. The image tag may not exist or registry credentials are missing.",
      evidence_ids: $ids,
      confidence: 0.95,
      action: "verify image tag exists in registry; check imagePullSecrets"
    }]')
fi

# ── Rule: CrashLoopBackOff ± missing env var ──────────────────────────────────
if echo "$ps_content" | grep -q "CrashLoopBackOff"; then
  combined_logs="${log_content}"$'\n'"${ev_content}"
  env_var=$(_extract_env_var "$combined_logs")

  if [[ -n "$env_var" ]]; then
    desc="Container is crash-looping due to missing environment variable '${env_var}'. A recent rollout likely removed or renamed it from the Helm values."
    conf=0.86
  else
    desc="Container is crash-looping. Inspect previous-container logs for startup errors; a missing env var or misconfiguration after a recent rollout is the most common cause."
    conf=0.65
  fi

  all_ids=$(jq -n --argjson ps "$ps_ids" --argjson log "$log_ids" --argjson ev "$ev_ids" '$ps + $log + $ev | unique')
  hypotheses=$(echo "$hypotheses" | jq \
    --arg desc "$desc" \
    --argjson conf "$conf" \
    --argjson ids "$all_ids" \
    '. + [{
      rank: 0,
      rule: "crash_loop_missing_env",
      description: $desc,
      evidence_ids: $ids,
      confidence: $conf,
      action: "rollback Helm values to previous revision or restore missing env var"
    }]')
fi

# Sort by descending confidence and assign 1-based rank
echo "$hypotheses" | jq '[sort_by(-.confidence) | to_entries[] | .value + {rank: (.key + 1)}]'
