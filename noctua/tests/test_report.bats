#!/usr/bin/env bats
# Tests for report.sh — no cluster required

NOCTUA_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
FIXTURES="$(dirname "$BATS_TEST_FILENAME")/fixtures"
ANALYST="$NOCTUA_DIR/analyst/rules.sh"
REPORT="$NOCTUA_DIR/report.sh"

# Build a bundle with hypotheses from the analyst
_with_hypotheses() {
  local fixture=$1
  local bundle hypotheses
  bundle=$(cat "$fixture")
  hypotheses=$(bash "$ANALYST" "$fixture")
  echo "$bundle" | jq --argjson h "$hypotheses" '.hypotheses = $h'
}

@test "report: contains bundle_id" {
  bundle=$(_with_hypotheses "$FIXTURES/crashloop_bundle.json")
  bid=$(echo "$bundle" | jq -r '.bundle_id')
  report=$(echo "$bundle" | bash "$REPORT")
  [[ "$report" == *"$bid"* ]]
}

@test "report: contains DATABASE_URL in hypothesis section" {
  bundle=$(_with_hypotheses "$FIXTURES/crashloop_bundle.json")
  report=$(echo "$bundle" | bash "$REPORT")
  [[ "$report" == *"DATABASE_URL"* ]]
}

@test "report: contains evidence ids E1 E2 E3" {
  bundle=$(_with_hypotheses "$FIXTURES/crashloop_bundle.json")
  report=$(echo "$bundle" | bash "$REPORT")
  [[ "$report" == *"E1"* ]]
  [[ "$report" == *"E2"* ]]
  [[ "$report" == *"E3"* ]]
}

@test "report: contains evidence content (CrashLoopBackOff and DATABASE_URL)" {
  bundle=$(_with_hypotheses "$FIXTURES/crashloop_bundle.json")
  report=$(echo "$bundle" | bash "$REPORT")
  [[ "$report" == *"CrashLoopBackOff"* ]]
  [[ "$report" == *"DATABASE_URL"* ]]
}

@test "report: contains sha256 seal (first 16 chars)" {
  bundle=$(_with_hypotheses "$FIXTURES/crashloop_bundle.json")
  sha=$(echo "$bundle" | jq -r '.sha256')
  report=$(echo "$bundle" | bash "$REPORT")
  [[ "$report" == *"${sha:0:16}"* ]]
}

@test "report: healthy pod shows manual investigation message" {
  bundle=$(_with_hypotheses "$FIXTURES/healthy_bundle.json")
  report=$(echo "$bundle" | bash "$REPORT")
  [[ "$report" == *"Manual investigation required"* ]]
}

@test "report: hypothesis section has confidence percentage" {
  bundle=$(_with_hypotheses "$FIXTURES/imagepull_bundle.json")
  report=$(echo "$bundle" | bash "$REPORT")
  [[ "$report" == *"95%"* ]]
}

@test "report: hypothesis has suggested action" {
  bundle=$(_with_hypotheses "$FIXTURES/crashloop_bundle.json")
  report=$(echo "$bundle" | bash "$REPORT")
  [[ "$report" == *"Suggested action"* ]]
}
