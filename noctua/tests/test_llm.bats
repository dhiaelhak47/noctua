#!/usr/bin/env bats
# Tests for analyst/llm.sh and analyst/analyst.sh
# All tests use NOCTUA_LLM_MOCK=1 — no real API call.

NOCTUA_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
FIXTURES="$(dirname "$BATS_TEST_FILENAME")/fixtures"
LLM="$NOCTUA_DIR/analyst/llm.sh"
ANALYST="$NOCTUA_DIR/analyst/analyst.sh"

# ── llm.sh mock mode ──────────────────────────────────────────────────────────

@test "llm mock: returns a JSON array" {
  result=$(NOCTUA_LLM_MOCK=1 bash "$LLM" "$FIXTURES/crashloop_bundle.json")
  count=$(echo "$result" | jq 'type')
  [[ "$count" == '"array"' ]]
}

@test "llm mock: array has at least one hypothesis" {
  result=$(NOCTUA_LLM_MOCK=1 bash "$LLM" "$FIXTURES/crashloop_bundle.json")
  count=$(echo "$result" | jq 'length')
  [[ "$count" -gt 0 ]]
}

@test "llm mock: hypothesis has required fields (rule, description, confidence, rank)" {
  result=$(NOCTUA_LLM_MOCK=1 bash "$LLM" "$FIXTURES/crashloop_bundle.json")
  rule=$(echo "$result" | jq -r '.[0].rule // empty')
  desc=$(echo "$result" | jq -r '.[0].description // empty')
  conf=$(echo "$result" | jq    '.[0].confidence // empty')
  rank=$(echo "$result" | jq    '.[0].rank // empty')
  [[ -n "$rule" ]]
  [[ -n "$desc" ]]
  [[ -n "$conf" ]]
  [[ -n "$rank" ]]
}

@test "llm mock: confidence is between 0.0 and 1.0" {
  result=$(NOCTUA_LLM_MOCK=1 bash "$LLM" "$FIXTURES/crashloop_bundle.json")
  conf=$(echo "$result" | jq '.[0].confidence')
  pass=$(echo "$conf" | awk '{print ($1 >= 0.0 && $1 <= 1.0) ? "yes" : "no"}')
  [[ "$pass" == "yes" ]]
}

@test "llm mock: rank is 1 for first hypothesis" {
  result=$(NOCTUA_LLM_MOCK=1 bash "$LLM" "$FIXTURES/crashloop_bundle.json")
  rank=$(echo "$result" | jq '.[0].rank')
  [[ "$rank" -eq 1 ]]
}

@test "llm mock: works with oomkilled fixture" {
  result=$(NOCTUA_LLM_MOCK=1 bash "$LLM" "$FIXTURES/oomkilled_bundle.json")
  count=$(echo "$result" | jq 'length')
  [[ "$count" -gt 0 ]]
}

@test "llm mock: works with healthy fixture" {
  result=$(NOCTUA_LLM_MOCK=1 bash "$LLM" "$FIXTURES/healthy_bundle.json")
  # Mock always returns one hypothesis regardless of content
  count=$(echo "$result" | jq 'length')
  [[ "$count" -gt 0 ]]
}

@test "llm: exits non-zero when AZURE_OPENAI_ENDPOINT is absent (no mock)" {
  run env -u AZURE_OPENAI_ENDPOINT NOCTUA_LLM_MOCK=0 \
      bash "$LLM" "$FIXTURES/crashloop_bundle.json"
  [[ "$status" -ne 0 ]]
}

# ── analyst.sh dispatcher ─────────────────────────────────────────────────────

@test "analyst --mode rules: returns valid hypothesis array" {
  result=$(bash "$ANALYST" --mode rules "$FIXTURES/crashloop_bundle.json")
  count=$(echo "$result" | jq 'length')
  [[ "$count" -gt 0 ]]
}

@test "analyst --mode llm: mock mode returns valid array" {
  result=$(NOCTUA_LLM_MOCK=1 bash "$ANALYST" --mode llm "$FIXTURES/crashloop_bundle.json")
  count=$(echo "$result" | jq 'length')
  [[ "$count" -gt 0 ]]
}

@test "analyst --mode hybrid: combines rules and llm results" {
  result=$(NOCTUA_LLM_MOCK=1 bash "$ANALYST" --mode hybrid "$FIXTURES/crashloop_bundle.json")
  count=$(echo "$result" | jq 'length')
  # hybrid must return at least as many as rules alone
  rules_count=$(bash "$ANALYST" --mode rules "$FIXTURES/crashloop_bundle.json" | jq 'length')
  [[ "$count" -ge "$rules_count" ]]
}

@test "analyst --mode hybrid: all entries have rank field" {
  result=$(NOCTUA_LLM_MOCK=1 bash "$ANALYST" --mode hybrid "$FIXTURES/crashloop_bundle.json")
  missing=$(echo "$result" | jq '[.[] | select(.rank == null)] | length')
  [[ "$missing" -eq 0 ]]
}

@test "analyst --mode hybrid: sorted by confidence descending" {
  result=$(NOCTUA_LLM_MOCK=1 bash "$ANALYST" --mode hybrid "$FIXTURES/oomkilled_bundle.json")
  count=$(echo "$result" | jq 'length')
  if [[ "$count" -gt 1 ]]; then
    first=$(echo "$result"  | jq '.[0].confidence')
    second=$(echo "$result" | jq '.[1].confidence')
    pass=$(echo "$first $second" | awk '{print ($1 >= $2) ? "yes" : "no"}')
    [[ "$pass" == "yes" ]]
  fi
}

@test "analyst: unknown mode exits non-zero" {
  run bash "$ANALYST" --mode nonexistent "$FIXTURES/crashloop_bundle.json"
  [[ "$status" -ne 0 ]]
}
