# Phase 0 — Tests Reference

All tests live in `noctua/tests/`. They use **bats** (Bash Automated Testing System).
No Kubernetes cluster is required — tests run against static JSON fixture files.

Run them with: `bats noctua/tests/`
In CI: `make test` (GitHub Actions installs bats via apt).

---

## How bats works

A bats file is a bash script where each test is a function:

```bash
@test "description of what this tests" {
  # any bash code
  # assertions use [ ] or [[ ]]
  # test FAILS if any command returns non-zero
  [[ "$result" == "expected" ]]
}
```

Bats runs each `@test` in isolation. If the final command in the block returns non-zero,
the test fails and bats prints the description + the failing line.

Special variables:
- `$BATS_TEST_FILENAME` — absolute path to the current `.bats` file
- `$output` — stdout captured by the `run` helper command
- `$status` — exit code captured by `run`

---

## Fixtures

Static JSON files in `noctua/tests/fixtures/` that simulate sealed evidence bundles
for different failure scenarios. No kubectl calls are made during tests.

### `crashloop_bundle.json`
Simulates: `ledger-api` pod in CrashLoopBackOff with 5 restarts.
Key content:
- E1 (pod_status): `State: Waiting (CrashLoopBackOff)`, `LastState: Terminated (reason=Error, exitCode=1)`
- E2 (event): `BackOff restarting failed container`
- E3 (log): Python traceback ending in `KeyError: 'DATABASE_URL'`

This fixture triggers **Rule 3** (CrashLoopBackOff + env var) with confidence 0.86.

### `oomkilled_bundle.json`
Simulates: pod OOM-killed and then entering CrashLoopBackOff.
Key content:
- E1 (pod_status): `LastState: Terminated (reason=OOMKilled, exitCode=137)` + `State: Waiting (CrashLoopBackOff)`
- E2 (event): `OOMKilling` event

This fixture triggers **Rule 1** (OOMKilled, 0.90) AND **Rule 3** (CrashLoop, 0.65).
Tests verify that OOMKilled ranks above CrashLoop.

### `imagepull_bundle.json`
Simulates: pod stuck in ImagePullBackOff because the image tag doesn't exist.
Key content:
- E1 (pod_status): `State: Waiting (ImagePullBackOff)`
- E2 (event): `Failed to pull image "...:v9.9.9": not found`

This fixture triggers **Rule 2** (ImagePullBackOff, 0.95).

### `healthy_bundle.json`
Simulates: healthy running pod with no faults.
Key content:
- E1 (pod_status): `Phase: Running`, `State: Running`, `Ready: true`, `RestartCount: 0`
- E2 (event): `Pulled` and `Started` events only

This fixture triggers **no rules** → empty hypotheses array.

---

## `test_bundle.bats` — Testing `seal.sh`

These tests verify the tamper-evidence property of the sealing mechanism.

### Test 1: seal produces 64-char hex sha256
```bash
@test "seal produces 64-char hex sha256" {
  evidence='[{"id":"E1","kind":"log","source":"test","content":"hello","collected_at":"..."}]'
  result=$(echo "$evidence" | bash "$NOCTUA_DIR/seal.sh")
  [[ ${#result} -eq 64 ]]          # bash string length
  [[ "$result" =~ ^[0-9a-f]{64}$ ]] # regex: only hex chars
}
```
**Why:** A sha256 is always exactly 64 hex characters. If this fails, `sha256sum` or `jq`
is not installed, or the pipeline is broken.

### Test 2: seal is deterministic
```bash
@test "seal is deterministic for identical input" {
  h1=$(echo "$evidence" | bash "$NOCTUA_DIR/seal.sh")
  h2=$(echo "$evidence" | bash "$NOCTUA_DIR/seal.sh")
  [[ "$h1" == "$h2" ]]
}
```
**Why:** A seal is only useful as tamper evidence if the same input always produces the
same hash. `jq -cS '.'` sorts keys to guarantee this.

### Test 3: seal changes on content change
```bash
@test "seal changes when content changes" {
  ev1='[{..."content":"hello"...}]'
  ev2='[{..."content":"world"...}]'
  h1=$(echo "$ev1" | bash "$NOCTUA_DIR/seal.sh")
  h2=$(echo "$ev2" | bash "$NOCTUA_DIR/seal.sh")
  [[ "$h1" != "$h2" ]]
}
```
**Why:** If two different inputs produced the same hash, evidence could be modified without
detection. This confirms the hash is sensitive to content.

### Test 4: seal is order-independent
```bash
@test "seal is order-independent (key sorting)" {
  ev1='[{"content":"hello","id":"E1","kind":"log",...}]'  # keys in different order
  ev2='[{"id":"E1","kind":"log","source":"test","content":"hello",...}]'
  h1=$(echo "$ev1" | bash "$NOCTUA_DIR/seal.sh")
  h2=$(echo "$ev2" | bash "$NOCTUA_DIR/seal.sh")
  [[ "$h1" == "$h2" ]]
}
```
**Why:** Different JSON serializers may output keys in different orders. The `-S` flag in
`jq -cS '.'` sorts all keys before hashing, so the same data always seals to the same value.

---

## `test_analyst.bats` — Testing `analyst/rules.sh`

### Setup pattern

Each test loads a fixture directly into the analyst:
```bash
ANALYST="$NOCTUA_DIR/analyst/rules.sh"
result=$(bash "$ANALYST" "$FIXTURES/crashloop_bundle.json")
```
The analyst reads the bundle, applies rules, and outputs a JSON hypotheses array.

### CrashLoop tests

**Test: rule name present**
```bash
@test "crashloop: detects crash_loop_missing_env rule" {
  [[ "$result" == *"crash_loop_missing_env"* ]]
}
```
`*...*` in `[[ ]]` is a glob pattern match (not regex). Checks the rule name appears in output.

**Test: env var extracted**
```bash
@test "crashloop: extracts DATABASE_URL from KeyError in logs" {
  [[ "$result" == *"DATABASE_URL"* ]]
}
```
Verifies the `_extract_env_var()` helper successfully parsed the Python `KeyError: 'DATABASE_URL'`
from the log evidence.

**Test: confidence >= 0.80**
```bash
@test "crashloop: confidence >= 0.80 when env var identified" {
  conf=$(echo "$result" | jq '[.[] | select(.rule=="crash_loop_missing_env")] | .[0].confidence')
  pass=$(echo "$conf" | awk '{print ($1 >= 0.80) ? "yes" : "no"}')
  [[ "$pass" == "yes" ]]
}
```
Bash cannot compare floats natively (`[[ 0.86 -ge 0.80 ]]` fails).
`awk` handles floating-point: reads `$conf` from stdin, prints "yes" or "no".

**Test: evidence IDs included**
```bash
@test "crashloop: hypothesis references evidence ids E1 E2 E3" {
  ids=$(echo "$result" | jq -r '.[0].evidence_ids | join(" ")')
  [[ "$ids" == *"E1"* ]]
  [[ "$ids" == *"E3"* ]]
}
```
Verifies the analyst correctly links hypotheses to the evidence items that justify them.

### OOMKilled tests

**Test: OOMKilled is rank 1**
```bash
@test "oomkilled: oomkilled is rank 1 (highest confidence)" {
  top_rule=$(echo "$result" | jq -r '.[0].rule')
  [[ "$top_rule" == "oomkilled" ]]
}
```
OOMKilled (0.90) > CrashLoop-without-var (0.65). This confirms the sort-by-confidence
ranking works: when both rules fire, OOMKilled must be rank 1.

### ImagePullBackOff tests

**Test: confidence is 0.95**
```bash
@test "imagepull: confidence is 0.95" {
  conf=$(echo "$result" | jq '[.[] | select(.rule=="image_pull_backoff")] | .[0].confidence')
  pass=$(echo "$conf" | awk '{print ($1 >= 0.94 && $1 <= 0.96) ? "yes" : "no"}')
  [[ "$pass" == "yes" ]]
}
```
Uses a ±0.01 tolerance band instead of exact equality, in case floating-point serialization
introduces tiny rounding differences.

### Healthy pod test

```bash
@test "healthy: produces empty hypotheses array" {
  count=$(echo "$result" | jq 'length')
  [[ "$count" -eq 0 ]]
}
```
No fault signatures in the healthy bundle → no rules fire → empty array.
`jq 'length'` on `[]` returns `0`.

### Ranking tests

**Test: sorted by confidence descending**
```bash
@test "ranking: hypotheses sorted by confidence descending" {
  count=$(echo "$result" | jq 'length')
  if [[ "$count" -gt 1 ]]; then
    first=$(echo "$result"  | jq '.[0].confidence')
    second=$(echo "$result" | jq '.[1].confidence')
    pass=$(echo "$first $second" | awk '{print ($1 >= $2) ? "yes" : "no"}')
    [[ "$pass" == "yes" ]]
  fi
}
```
The `if` guard handles the case where only one hypothesis is generated — sorting is
trivially correct for a single-element array.

**Test: 1-based rank field**
```bash
@test "ranking: rank field is 1-based sequential" {
  first_rank=$(echo "$result" | jq '.[0].rank')
  [[ "$first_rank" -eq 1 ]]
}
```
The `to_entries[] | .key + 1` jq pattern in rules.sh produces 1, 2, 3... not 0, 1, 2.

---

## `test_report.bats` — Testing `report.sh`

### Helper function

```bash
_with_hypotheses() {
  local fixture=$1
  local bundle hypotheses
  bundle=$(cat "$fixture")                       # load the fixture
  hypotheses=$(bash "$ANALYST" "$fixture")        # run analyst to get hypotheses
  echo "$bundle" | jq --argjson h "$hypotheses" '.hypotheses = $h'
  # merge hypotheses into bundle — simulates what investigate.sh does
}
```

This is called at the top of each test:
```bash
bundle=$(_with_hypotheses "$FIXTURES/crashloop_bundle.json")
report=$(echo "$bundle" | bash "$REPORT")
```

### Test: bundle_id in report
```bash
@test "report: contains bundle_id" {
  bid=$(echo "$bundle" | jq -r '.bundle_id')   # extract expected value
  [[ "$report" == *"$bid"* ]]                  # confirm it appears in output
}
```

### Test: confidence as percentage
```bash
@test "report: hypothesis section has confidence percentage" {
  # imagepull fixture → 0.95 → should display as "95%"
  [[ "$report" == *"95%"* ]]
}
```
Verifies that `report.sh` converts `0.95` → `95%` via `jq '(.confidence * 100 | round)'`.

### Test: manual investigation message
```bash
@test "report: healthy pod shows manual investigation message" {
  bundle=$(_with_hypotheses "$FIXTURES/healthy_bundle.json")
  report=$(echo "$bundle" | bash "$REPORT")
  [[ "$report" == *"Manual investigation required"* ]]
}
```
When `hypotheses` is empty, `report.sh` prints the fallback message instead of the
hypothesis section — this test verifies that fallback.

### Test: suggested action
```bash
@test "report: hypothesis has suggested action" {
  [[ "$report" == *"Suggested action"* ]]
}
```
Verifies that `report.sh` renders the `action` field from the hypothesis.
In `report.sh`: `[[ -n "$action" ]] && echo "- **Suggested action:** ${action}"`.

---

## Running tests locally

```bash
# Install bats (Linux)
git clone --depth 1 https://github.com/bats-core/bats-core /tmp/bats
sudo /tmp/bats/install.sh /usr/local

# Install jq
sudo apt-get install -y jq   # or brew install jq on macOS

# Run all tests
bats noctua/tests/

# Run one file
bats noctua/tests/test_analyst.bats

# Run with verbose output (see each @test name)
bats --verbose-run noctua/tests/
```

In CI (GitHub Actions, ubuntu-latest), all dependencies are installed automatically
in the `Install dependencies` step and tests run as part of the `test` job.
