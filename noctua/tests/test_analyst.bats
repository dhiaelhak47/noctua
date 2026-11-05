#!/usr/bin/env bats
# Tests for analyst/rules.sh — no cluster required

NOCTUA_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
FIXTURES="$(dirname "$BATS_TEST_FILENAME")/fixtures"
ANALYST="$NOCTUA_DIR/analyst/rules.sh"

# ── CrashLoopBackOff + missing env var ────────────────────────────────────────

@test "crashloop: detects crash_loop_missing_env rule" {
  result=$(bash "$ANALYST" "$FIXTURES/crashloop_bundle.json")
  [[ "$result" == *"crash_loop_missing_env"* ]]
}

@test "crashloop: extracts DATABASE_URL from KeyError in logs" {
  result=$(bash "$ANALYST" "$FIXTURES/crashloop_bundle.json")
  [[ "$result" == *"DATABASE_URL"* ]]
}

@test "crashloop: confidence >= 0.80 when env var identified" {
  result=$(bash "$ANALYST" "$FIXTURES/crashloop_bundle.json")
  conf=$(echo "$result" | jq '[.[] | select(.rule=="crash_loop_missing_env")] | .[0].confidence')
  pass=$(echo "$conf" | awk '{print ($1 >= 0.80) ? "yes" : "no"}')
  [[ "$pass" == "yes" ]]
}

@test "crashloop: hypothesis references evidence ids E1 E2 E3" {
  result=$(bash "$ANALYST" "$FIXTURES/crashloop_bundle.json")
  ids=$(echo "$result" | jq -r '.[0].evidence_ids | join(" ")')
  [[ "$ids" == *"E1"* ]]
  [[ "$ids" == *"E3"* ]]
}

# ── OOMKilled ─────────────────────────────────────────────────────────────────

@test "oomkilled: detects oomkilled rule" {
  result=$(bash "$ANALYST" "$FIXTURES/oomkilled_bundle.json")
  [[ "$result" == *"oomkilled"* ]]
}

@test "oomkilled: confidence is 0.90" {
  result=$(bash "$ANALYST" "$FIXTURES/oomkilled_bundle.json")
  conf=$(echo "$result" | jq '[.[] | select(.rule=="oomkilled")] | .[0].confidence')
  pass=$(echo "$conf" | awk '{print ($1 >= 0.89 && $1 <= 0.91) ? "yes" : "no"}')
  [[ "$pass" == "yes" ]]
}

@test "oomkilled: oomkilled is rank 1 (highest confidence)" {
  result=$(bash "$ANALYST" "$FIXTURES/oomkilled_bundle.json")
  top_rule=$(echo "$result" | jq -r '.[0].rule')
  [[ "$top_rule" == "oomkilled" ]]
}

# ── ImagePullBackOff ──────────────────────────────────────────────────────────

@test "imagepull: detects image_pull_backoff rule" {
  result=$(bash "$ANALYST" "$FIXTURES/imagepull_bundle.json")
  [[ "$result" == *"image_pull_backoff"* ]]
}

@test "imagepull: confidence is 0.95" {
  result=$(bash "$ANALYST" "$FIXTURES/imagepull_bundle.json")
  conf=$(echo "$result" | jq '[.[] | select(.rule=="image_pull_backoff")] | .[0].confidence')
  pass=$(echo "$conf" | awk '{print ($1 >= 0.94 && $1 <= 0.96) ? "yes" : "no"}')
  [[ "$pass" == "yes" ]]
}

# ── Healthy pod ───────────────────────────────────────────────────────────────

@test "healthy: produces empty hypotheses array" {
  result=$(bash "$ANALYST" "$FIXTURES/healthy_bundle.json")
  count=$(echo "$result" | jq 'length')
  [[ "$count" -eq 0 ]]
}

# ── Ranking ───────────────────────────────────────────────────────────────────

@test "ranking: hypotheses sorted by confidence descending" {
  result=$(bash "$ANALYST" "$FIXTURES/oomkilled_bundle.json")
  count=$(echo "$result" | jq 'length')
  if [[ "$count" -gt 1 ]]; then
    first=$(echo "$result"  | jq '.[0].confidence')
    second=$(echo "$result" | jq '.[1].confidence')
    pass=$(echo "$first $second" | awk '{print ($1 >= $2) ? "yes" : "no"}')
    [[ "$pass" == "yes" ]]
  fi
}

@test "ranking: rank field is 1-based sequential" {
  result=$(bash "$ANALYST" "$FIXTURES/oomkilled_bundle.json")
  first_rank=$(echo "$result" | jq '.[0].rank')
  [[ "$first_rank" -eq 1 ]]
}
