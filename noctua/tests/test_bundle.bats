#!/usr/bin/env bats
# Tests for seal.sh — no cluster required

NOCTUA_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

@test "seal produces 64-char hex sha256" {
  evidence='[{"id":"E1","kind":"log","source":"test","content":"hello","collected_at":"2026-11-05T10:00:00Z"}]'
  result=$(echo "$evidence" | bash "$NOCTUA_DIR/seal.sh")
  [[ ${#result} -eq 64 ]]
  [[ "$result" =~ ^[0-9a-f]{64}$ ]]
}

@test "seal is deterministic for identical input" {
  evidence='[{"id":"E1","kind":"log","source":"test","content":"hello","collected_at":"2026-11-05T10:00:00Z"}]'
  h1=$(echo "$evidence" | bash "$NOCTUA_DIR/seal.sh")
  h2=$(echo "$evidence" | bash "$NOCTUA_DIR/seal.sh")
  [[ "$h1" == "$h2" ]]
}

@test "seal changes when content changes" {
  ev1='[{"id":"E1","kind":"log","source":"test","content":"hello","collected_at":"2026-11-05T10:00:00Z"}]'
  ev2='[{"id":"E1","kind":"log","source":"test","content":"world","collected_at":"2026-11-05T10:00:00Z"}]'
  h1=$(echo "$ev1" | bash "$NOCTUA_DIR/seal.sh")
  h2=$(echo "$ev2" | bash "$NOCTUA_DIR/seal.sh")
  [[ "$h1" != "$h2" ]]
}

@test "seal is order-independent (key sorting)" {
  ev1='[{"content":"hello","id":"E1","kind":"log","source":"test","collected_at":"2026-11-05T10:00:00Z"}]'
  ev2='[{"id":"E1","kind":"log","source":"test","content":"hello","collected_at":"2026-11-05T10:00:00Z"}]'
  h1=$(echo "$ev1" | bash "$NOCTUA_DIR/seal.sh")
  h2=$(echo "$ev2" | bash "$NOCTUA_DIR/seal.sh")
  [[ "$h1" == "$h2" ]]
}
