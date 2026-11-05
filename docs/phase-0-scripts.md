# Phase 0 — Shell Scripts Reference

All scripts live in `noctua/`. They require `bash`, `jq`, `kubectl`, and `sha256sum`
(GNU coreutils — standard on Linux and Git Bash on Windows).

---

## `noctua/noctua` — CLI dispatcher

```bash
#!/usr/bin/env bash
set -euo pipefail           # -e exit on error, -u error on unset var, -o pipefail
```

`SCRIPT_DIR` resolves to the directory containing this script regardless of where you
call it from:
```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
```

The `case` block maps sub-commands to scripts:
```bash
case "${1:-help}" in         # default to "help" if no argument given
  investigate) shift; exec "$SCRIPT_DIR/investigate.sh" "$@" ;;
  # `shift` removes "investigate" from $@, then exec replaces the shell process
  version)  echo "noctua 0.1.0" ;;
  help|--help|-h) ... ;;
  *) echo "Unknown command: ${1}." >&2; exit 1 ;;
esac
```

Usage:
```
noctua investigate estate/ledger-api-abc-123
noctua investigate -n estate -o report.md ledger-api-abc-123
noctua version
```

---

## `noctua/investigate.sh` — Orchestrator

This script ties everything together:
**parse args → init bundle → collect → seal → analyse → report**

### Argument parsing

```bash
while [[ $# -gt 0 ]]; do
  case $1 in
    -n|--namespace) namespace="$2"; shift 2 ;;   # consume flag + value
    -o|--output)    output="$2";    shift 2 ;;
    --json)         json_out=true;  shift   ;;    # boolean flag, no value
    -*)             usage ;;                      # unknown flag → error
    *)
      if [[ "$1" == */* ]]; then         # "estate/ledger-api" → split on /
        namespace="${1%%/*}"             # everything before first /
        pod="${1#*/}"                    # everything after first /
      else
        pod="$1"                         # bare pod name, use -n namespace
      fi
      shift
      ;;
  esac
done
```

### UUID generation

```bash
if [[ -f /proc/sys/kernel/random/uuid ]]; then
  bundle_id=$(cat /proc/sys/kernel/random/uuid)   # Linux kernel RNG (fast)
else
  bundle_id=$(uuidgen | tr '[:upper:]' '[:lower:]')  # macOS fallback
fi
```

### Evidence array builder

```bash
evidence='[]'    # start with empty JSON array
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
  # '. + [$item]' appends $item to the array
  idx=$((idx + 1))
}
```

Each collector is called, its output captured, and added to the evidence array:
```bash
content=$("$SCRIPT_DIR/collectors/pod_status.sh" "$namespace" "$pod" 2>&1) \
  || { _warn "pod_status failed"; content="ERROR: collection failed"; }
_add "pod_status" "pod_status" "$content"
```

The `|| { ... }` pattern handles collector failure gracefully — the bundle is still
created with an error marker rather than the whole script aborting.

### Sealing

```bash
sha=$(echo "$evidence" | "$SCRIPT_DIR/seal.sh")
# passes the JSON array via stdin → returns 64-char hex sha256
```

### Bundle assembly

```bash
bundle=$(jq -n \
  --arg  bid "$bundle_id" \
  --arg  ns  "$namespace" \
  --arg  pod "$pod" \
  --arg  ts  "$created_at" \
  --arg  sha "$sha" \
  --argjson ev "$evidence" \   # --argjson treats the value as parsed JSON (not a string)
  '{ bundle_id: $bid, schema_version: "0.1", ... }')
```

`--arg` passes a shell variable as a JSON string.
`--argjson` passes a shell variable as parsed JSON (the evidence array).

### Analysis and output

```bash
hypotheses=$(echo "$bundle" | "$SCRIPT_DIR/analyst/rules.sh")
bundle=$(echo "$bundle" | jq --argjson h "$hypotheses" '.hypotheses = $h')
# replace the empty hypotheses[] with the analyst output

report=$(echo "$bundle" | "$SCRIPT_DIR/report.sh")

if [[ -n "$output" ]]; then
  echo "$report" > "$output"             # write to file
  if $json_out; then
    echo "$bundle" > "${output%.md}.json"  # %.md strips .md suffix → .json
  fi
else
  echo "$report"                         # print to stdout
fi
```

---

## `noctua/seal.sh` — Tamper-evident SHA-256

```bash
jq -cS '.' | sha256sum | awk '{print $1}'
```

Three commands piped:

1. `jq -cS '.'` — reads JSON from stdin, outputs **compact** (`-c`) with **sorted keys**
   (`-S`). Sorted keys make the hash deterministic regardless of insertion order.
2. `sha256sum` — hashes the compact JSON. Outputs `<hash>  -` (hash + filename).
3. `awk '{print $1}'` — extracts just the 64-character hex hash.

Example:
```
input:  [{"content":"hello","id":"E1","kind":"log",...}]
after jq -cS: [{"collected_at":"...","content":"hello","id":"E1","kind":"log",...}]
output: a3f1b2c4...  (64 hex chars)
```

---

## `noctua/redact.sh` — PII/secret scrubbing

Reads from stdin, writes cleaned text to stdout using `sed` with multiple `-e` patterns:

```bash
sed \
  -e 's/[A-Za-z0-9._%+-]\+@[A-Za-z0-9.-]\+\.[A-Za-z]\{2,\}/[REDACTED_EMAIL]/g' \
  # matches: user.name+tag@domain.co.uk
  -e 's/\b[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\b/[REDACTED_IP]/g' \
  # matches: 10.0.1.42  192.168.0.1
  -e 's/Bearer [A-Za-z0-9._-]\+/Bearer [REDACTED_TOKEN]/g' \
  # matches: Bearer eyJhbGciOiJSUzI1NiJ9...
  -e 's/password[[:space:]]*=[[:space:]]*[^[:space:]]\+/password=[REDACTED]/gi' \
  -e 's/secret[[:space:]]*=[[:space:]]*[^[:space:]]\+/secret=[REDACTED]/gi' \
  -e 's/token[[:space:]]*=[[:space:]]*[^[:space:]]\+/token=[REDACTED]/gi'
  # all three above: case-insensitive (i flag), match KEY = VALUE patterns
```

The `\+` is a POSIX ERE quantifier for "one or more" in GNU sed BRE mode.

---

## `noctua/report.sh` — Bundle → Markdown

Reads bundle JSON (from stdin or a file argument), prints a human-readable Markdown report.

### Reading the bundle

```bash
bundle=$(cat "${1:-/dev/stdin}")
# If a file argument is given, read that; otherwise read stdin.
# "${1:-/dev/stdin}" means "use $1 if set, else /dev/stdin"
```

### Extracting fields

```bash
bundle_id=$(echo "$bundle" | jq -r '.bundle_id')
# -r = raw output (no JSON quotes around strings)
sha256=$(echo "$bundle"    | jq -r '.sha256')
```

### Confidence as percentage

```bash
conf=$(echo "$hyp" | jq '(.confidence * 100 | round)')
# 0.95 → 95  (jq's round() function)
```

### Iterating hypotheses

```bash
while IFS= read -r hyp; do
  # process one hypothesis JSON object per line
done < <(echo "$bundle" | jq -c '.hypotheses[]')
# jq -c outputs each array element on its own line (compact)
# <(...) is process substitution — feeds output of jq as stdin to while
```

### Seal display (first 16 chars only)

```bash
echo "**Seal:** \`${sha256:0:16}…\`"
# bash substring: ${var:start:length}
# shows just enough to visually identify the bundle without the full hash
```

---

## `noctua/collectors/pod_status.sh`

Collects pod phase and per-container state from the Kubernetes API.

```bash
pod_json=$(kubectl get pod "$pod" -n "$namespace" -o json 2>&1)
# -o json  → full pod object as JSON
# 2>&1     → capture stderr too (error messages end up in evidence)
```

```bash
for i in $(seq 0 $((count - 1))); do   # iterate container indices
  cs=$(echo "$pod_json" | jq ".status.containerStatuses[$i]")
```

State logic — only one of waiting/running/terminated is ever set at a time:
```bash
if [[ -n "$waiting_reason" ]]; then
  out+=$'\n'"  State: Waiting (${waiting_reason})"
  # CrashLoopBackOff, ImagePullBackOff, etc.
elif [[ -n "$running_at" ]]; then
  out+=$'\n'"  State: Running (started ${running_at})"
elif [[ -n "$term_reason" ]]; then
  out+=$'\n'"  State: Terminated (reason=${term_reason}, exitCode=${term_exit})"
  # OOMKilled, Error, Completed
fi

if [[ -n "$lt_reason" ]]; then
  out+=$'\n'"  LastState: Terminated (reason=${lt_reason}, exitCode=${lt_exit})"
  # Previous container run — OOMKilled shows up here when restartPolicy=Always
fi
```

---

## `noctua/collectors/logs.sh`

Fetches the **previous** container logs (the run before the current restart):

```bash
output=$(kubectl logs "$pod" -n "$namespace" \
  --previous \        # previous terminated container instance
  --tail="$tail_lines" \  # default 50 lines (configurable via $3)
  2>&1) || true       # don't abort on kubectl error
```

Graceful fallback for pods that have never restarted or logs that are gone:
```bash
if [[ -z "$output" ]] || echo "$output" | grep -qiE "no previous (terminated|container)|not found"; then
  echo "No previous container logs available."
elif echo "$output" | grep -q "^error:"; then
  echo "No previous container logs available."
else
  echo "$output"
fi
```

---

## `noctua/collectors/events.sh`

Fetches Kubernetes events scoped to a specific pod using a field selector:

```bash
events_json=$(kubectl get events \
  -n "$namespace" \
  --field-selector "involvedObject.name=${pod}" \  # only events about this pod
  --sort-by='.lastTimestamp' \                      # chronological order
  -o json 2>&1)
```

Formats as a fixed-width table using `printf`:
```bash
printf "%-20s %-10s %-25s %s\n" "Last Seen" "Type" "Reason" "Message"
# %-20s = left-align in 20-char column

echo "$events_json" | jq -r --argjson limit "$limit" '
  .items[0:$limit][] |               # first N items
  [
    (.lastTimestamp // .eventTime // "" | .[0:19]),  # truncate to seconds
    (.type    // ""),                               # Normal / Warning
    (.reason  // ""),                               # BackOff, Pulled, etc.
    ((.message // "") | .[0:100])                   # cap message at 100 chars
  ] | @tsv                           # tab-separated values
' | while IFS=$'\t' read -r last type reason message; do
  printf "%-20s %-10s %-25s %s\n" "$last" "$type" "$reason" "$message"
done
```

---

## `noctua/collectors/rollout.sh`

Walks the **ownerReference chain** Pod → ReplicaSet → Deployment to show revision history.

```bash
# Step 1: get the ReplicaSet that owns this Pod
rs_name=$(echo "$pod_json" | jq -r '
  .metadata.ownerReferences // []
  | map(select(.kind == "ReplicaSet"))
  | .[0].name // empty')
```

```bash
# Step 2: get the Deployment that owns the ReplicaSet
dep_name=$(echo "$rs_json" | jq -r '
  .metadata.ownerReferences // []
  | map(select(.kind == "Deployment"))
  | .[0].name // empty')
```

```bash
# Step 3: list all ReplicaSets for this Deployment by label selector
label_sel=$(echo "$dep_json" | jq -r '
  .spec.selector.matchLabels
  | to_entries
  | map("\(.key)=\(.value)")
  | join(",")')
# produces e.g. "app=ledger-api,app.kubernetes.io/name=ledger-api"

rs_list=$(kubectl get rs -n "$namespace" -l "$label_sel" -o json)
```

```bash
# Step 4: sort by revision annotation and print table
echo "$rs_list" | jq -r --arg current "$rs_name" '
  .items[]
  | select(.metadata.annotations["deployment.kubernetes.io/revision"] != null)
  | [
      (.metadata.annotations["deployment.kubernetes.io/revision"] | tonumber),
      .metadata.name,
      (.spec.template.spec.containers[0].image // "unknown"),
      (if .metadata.name == $current then " ← current" else "" end)
    ]
  | @tsv
' | sort -n | while IFS=$'\t' read -r rev rs_n image marker; do
  printf "%-6s %-45s %s%s\n" "$rev" "$rs_n" "$image" "$marker"
done
```

---

## `noctua/analyst/rules.sh` — Rule engine

The analyst reads the bundle, extracts evidence by kind, and applies three deterministic rules.

### Evidence extraction

```bash
ps_content=$(echo "$bundle"  | jq -r '[.evidence[] | select(.kind=="pod_status") | .content] | join("\n")')
log_content=$(echo "$bundle" | jq -r '[.evidence[] | select(.kind=="log")        | .content] | join("\n")')
ev_content=$(echo "$bundle"  | jq -r '[.evidence[] | select(.kind=="event")      | .content] | join("\n")')
# select() filters the array; .content gets the text; join("\n") merges multiple items
```

### `_extract_env_var()` helper

Extracts the name of a missing environment variable from log text using three patterns:

```bash
# Pattern 1: Python KeyError → KeyError: 'DATABASE_URL'
var=$(echo "$text" | grep -oE "KeyError: '[A-Z][A-Z0-9_]+'" \
      | sed "s/KeyError: '//;s/'//" | head -1) || var=""
# -oE = only print the matched part, using Extended RE

# Pattern 2: shell-style → $DATABASE_URL is not set
var=$(echo "$text" | grep -oiE '\$[A-Z][A-Z0-9_]{3,} (is )?(not set|unset|undefined|missing)' \
      | grep -oE '[A-Z][A-Z0-9_]+' | head -1) || var=""

# Pattern 3: prose → "missing env var: DATABASE_URL"
var=$(echo "$text" | grep -iE 'missing (env var|environment variable)' \
      | grep -oE '[A-Z][A-Z0-9_]{3,}' | tail -1) || var=""
```

### Rule 1 — OOMKilled

```bash
if echo "$ps_content" | grep -q "OOMKilled"; then
  hypotheses=$(echo "$hypotheses" | jq \
    --argjson ids "$ps_ids" \
    '. + [{
      rank: 0,                 # placeholder; sorted later
      rule: "oomkilled",
      description: "Container was OOM-killed...",
      evidence_ids: $ids,
      confidence: 0.90,
      action: "raise memory limit in Helm values and redeploy"
    }]')
fi
```

OOMKilled appears in `lastState.terminated.reason` → shows up in `pod_status` evidence.
Confidence 0.90: very high signal, but could occasionally be a node memory pressure event.

### Rule 2 — ImagePullBackOff

```bash
combined_ps_ev="${ps_content}"$'\n'"${ev_content}"
# Check BOTH pod_status AND events (k8s reports it in both)
if echo "$combined_ps_ev" | grep -qE "ImagePullBackOff|ErrImagePull"; then
  all_ids=$(jq -n --argjson ps "$ps_ids" --argjson ev "$ev_ids" '$ps + $ev | unique')
  # unique deduplicates if the same id appears in both sources
```

Confidence 0.95: highest of the three rules — this error has almost no false positives.

### Rule 3 — CrashLoopBackOff ± missing env var

```bash
if echo "$ps_content" | grep -q "CrashLoopBackOff"; then
  combined_logs="${log_content}"$'\n'"${ev_content}"
  env_var=$(_extract_env_var "$combined_logs")

  if [[ -n "$env_var" ]]; then
    conf=0.86   # specific: we know WHICH variable is missing
  else
    conf=0.65   # generic: crash loop but unknown root cause
  fi
```

### Sorting and ranking

```bash
echo "$hypotheses" | jq '[sort_by(-.confidence) | to_entries[] | .value + {rank: (.key + 1)}]'
# sort_by(-.confidence)  → descending by confidence
# to_entries[]           → [{key:0, value:{...}}, {key:1, value:{...}}, ...]
# .value + {rank: (.key + 1)}  → add rank field (1-based)
```
