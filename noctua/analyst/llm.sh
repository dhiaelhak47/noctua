#!/usr/bin/env bash
set -euo pipefail
# stdin: bundle JSON → stdout: hypotheses JSON array (same schema as rules.sh)
#
# Requires env vars:
#   AZURE_OPENAI_ENDPOINT    e.g. https://my-resource.openai.azure.com
#   AZURE_OPENAI_API_KEY
# Optional:
#   AZURE_OPENAI_DEPLOYMENT  default: gpt-4o-mini
#   AZURE_OPENAI_API_VERSION default: 2024-10-21
#   NOCTUA_LLM_MOCK          set to "1" to skip API call (used in tests)

bundle=$(cat "${1:-/dev/stdin}")

# ── Mock mode — no real API call (for tests and offline demos) ────────────────
if [[ "${NOCTUA_LLM_MOCK:-0}" == "1" ]]; then
  namespace=$(echo "$bundle" | jq -r '.namespace')
  pod=$(echo "$bundle"       | jq -r '.pod')
  # Return one plausible mock hypothesis so callers get a valid schema
  jq -n \
    --arg ns  "$namespace" \
    --arg pod "$pod" \
    '[{
      "rank":         1,
      "rule":         "llm_hypothesis",
      "description":  ("LLM mock response for " + $ns + "/" + $pod),
      "confidence":   0.80,
      "evidence_ids": ["E1"],
      "action":       "review pod configuration and recent rollout changes"
    }]'
  exit 0
fi

# ── Validate credentials ───────────────────────────────────────────────────────
: "${AZURE_OPENAI_ENDPOINT:?AZURE_OPENAI_ENDPOINT not set (e.g. https://my-resource.openai.azure.com)}"
: "${AZURE_OPENAI_API_KEY:?AZURE_OPENAI_API_KEY not set}"

deployment="${AZURE_OPENAI_DEPLOYMENT:-gpt-4o-mini}"
api_version="${AZURE_OPENAI_API_VERSION:-2024-10-21}"

# ── Build prompt ──────────────────────────────────────────────────────────────
namespace=$(echo "$bundle" | jq -r '.namespace')
pod=$(echo "$bundle"       | jq -r '.pod')
created_at=$(echo "$bundle" | jq -r '.created_at')

evidence_text=$(echo "$bundle" | jq -r '
  .evidence[] |
  "=== \(.id) [kind:\(.kind)  source:\(.source)] ===\n\(.content)\n"
')

system_prompt='You are NOCTUA, an expert Kubernetes incident analyst.
Given evidence collected from a Kubernetes cluster, analyse the incident and
return a JSON object with key "hypotheses" containing an array of ranked hypotheses.

Each hypothesis object must contain exactly these fields:
  rule         — snake_case string identifier (prefix with "llm_")
  description  — clear, actionable explanation for a human operator
  confidence   — float between 0.0 and 1.0
  evidence_ids — JSON array of evidence IDs that support this hypothesis (e.g. ["E1","E3"])
  action       — specific remediation step

Sort by confidence descending. Output ONLY valid JSON, no markdown fences.'

user_prompt="Namespace: ${namespace}
Pod: ${pod}
Collected at: ${created_at}

Evidence:
${evidence_text}

Analyse the incident. Return a JSON object: {\"hypotheses\": [...]}"

# ── Call Azure OpenAI ─────────────────────────────────────────────────────────
payload=$(jq -n \
  --arg sys "$system_prompt" \
  --arg usr "$user_prompt" \
  '{
    messages: [
      {role: "system", content: $sys},
      {role: "user",   content: $usr}
    ],
    temperature: 0,
    max_tokens:  1500,
    response_format: {type: "json_object"}
  }')

url="${AZURE_OPENAI_ENDPOINT%/}/openai/deployments/${deployment}/chat/completions?api-version=${api_version}"

response=$(curl -sS --max-time 30 \
  "$url" \
  -H "Content-Type: application/json" \
  -H "api-key: ${AZURE_OPENAI_API_KEY}" \
  -d "$payload") || {
    echo "ERROR: curl failed — check network and AZURE_OPENAI_ENDPOINT" >&2
    echo "[]"
    exit 0
  }

# ── Check for API-level errors ────────────────────────────────────────────────
error_msg=$(echo "$response" | jq -r '.error.message // empty')
if [[ -n "$error_msg" ]]; then
  echo "ERROR: Azure OpenAI API error: ${error_msg}" >&2
  echo "[]"
  exit 0
fi

content=$(echo "$response" | jq -r '.choices[0].message.content // empty')
if [[ -z "$content" ]]; then
  echo "ERROR: empty response from LLM (check deployment name and API version)" >&2
  echo "[]"
  exit 0
fi

# ── Normalise to hypotheses schema ────────────────────────────────────────────
# The model returns {"hypotheses": [...]} due to response_format: json_object.
# Tolerate both {"hypotheses":[...]} and a bare array.
echo "$content" | jq '
  (if type == "object" then (.hypotheses // []) else . end) |
  if type != "array" then [] else . end |
  sort_by(-.confidence) |
  to_entries |
  map(.value + {
    rank:         (.key + 1),
    rule:         (.value.rule         // "llm_hypothesis"),
    description:  (.value.description  // ""),
    confidence:   ((.value.confidence  // 0.5) | if . > 1 then 1.0 elif . < 0 then 0.0 else . end),
    evidence_ids: (.value.evidence_ids // []),
    action:       (.value.action       // "")
  })
' 2>/dev/null || {
  echo "ERROR: failed to parse LLM JSON response" >&2
  echo "[]"
}
