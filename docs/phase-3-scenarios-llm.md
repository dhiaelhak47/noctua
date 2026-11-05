# Phase 3 — Incident Scenarios & LLM Analyst

## What Phase 3 builds

- Three fault-injection scenarios that create real Kubernetes failures on the kind cluster
- An LLM analyst (`llm.sh`) that sends the sealed bundle to Azure OpenAI and returns ranked hypotheses
- An analyst dispatcher (`analyst.sh`) that selects rules / llm / hybrid mode
- `--analyst` flag on `noctua investigate`
- bats tests for the LLM analyst (mocked, no real API call)

---

## Incident Scenarios

The 3 scenarios cover the 3 rules in the rule-based analyst:

| ID  | Fault | Target service | Rule triggered |
|-----|-------|---------------|----------------|
| S01 | CrashLoopBackOff + KeyError: 'DATABASE_URL' | ledger-api | crash_loop_missing_env (0.86) |
| S02 | OOMKilled (memory limit 4Mi) | ledger-api | oomkilled (0.90) |
| S03 | ImagePullBackOff (bad tag) | inventory-svc | image_pull_backoff (0.95) |

---

## Scenario scripts (`scenarios/`)

### File structure

```
scenarios/
├── faults/
│   ├── s01-missing-env.yaml   ← Helm values: busybox image + crash script
│   ├── s02-oom.yaml           ← Helm values: memory limit 4Mi
│   └── s03-bad-image.yaml     ← Helm values: image tag 9.9.9-does-not-exist
├── s01-inject.sh              ← apply fault + wait + print investigate command
├── s02-inject.sh
├── s03-inject.sh
└── reset.sh                   ← restore all services to healthy base values
```

### How fault injection works

Each scenario script:
1. Optionally pauses Argo CD auto-sync for the target app (prevents Argo CD from reverting the fault)
2. Runs `helm upgrade <release> charts/noctua-service -f base-values.yaml -f fault-values.yaml`
3. Waits for the fault condition to appear in `kubectl get pod`
4. Prints the exact `noctua investigate` command to run

The fault values file is applied ON TOP of the base values file (layer 2 overrides layer 1).
Only the fields that need to change are specified in the fault file.

**Important:** `--reuse-values` is NOT used in scenario scripts. This prevents stale state
from a previous helm upgrade (e.g. a previous fault) leaking into the new run.

### `scenarios/faults/s01-missing-env.yaml` — CrashLoopBackOff

```yaml
replicaCount: 1
image:
  repository: busybox
  tag: "1.37.0"      # podinfo image has no shell; busybox does

command: [sh, -c]
args:
  - |-
    echo "Starting ledger-api v1.2.3..."
    sleep 2
    echo "Traceback (most recent call last):"
    echo "  File \"/app/main.py\", line 12, in <module>"
    echo "    db_url = os.environ[\"DATABASE_URL\"]"
    echo "KeyError: 'DATABASE_URL'"
    exit 1

livenessProbe:
  exec:
    command: ["true"]   # probe never fires before exit, but set high
  initialDelaySeconds: 999

hpa:
  enabled: false
serviceMonitor:
  enabled: false
```

**Why busybox?** podinfo is built from a minimal scratch-like base and has no shell binary.
Overriding the command to `sh -c ...` only works if `sh` is in the image.
busybox bundles sh and exits in <3 seconds with the right log output for the analyst to detect.

**Why `sleep 2`?** Kubernetes keeps the previous container's log until the pod is garbage
collected. The sleep ensures there is some output in the log stream before exit.

**How the command maps to Kubernetes:**
```
command: [sh, -c]   → overrides ENTRYPOINT
args: ["echo..."]   → overrides CMD (passed as 3rd argument to sh -c)
```
The container runs: `sh -c "echo 'Starting...'\n...exit 1"`

### `scenarios/faults/s02-oom.yaml` — OOMKilled

```yaml
resources:
  limits:
    memory: 4Mi   # podinfo RSS at startup is ~15MB → immediate OOMKill
hpa:
  enabled: false
```

The kernel's OOM killer kills the container when it tries to allocate beyond the cgroup limit.
Kubernetes records the reason as `OOMKilled` in `lastState.terminated.reason`.

After 3-4 restarts, the pod enters CrashLoopBackOff with `OOMKilled` in lastState.
Both `oomkilled` and `crash_loop_missing_env` rules may fire (the analyst handles this correctly
by ranking oomkilled higher since its confidence is 0.90 vs 0.65).

### `scenarios/faults/s03-bad-image.yaml` — ImagePullBackOff

```yaml
image:
  tag: "9.9.9-does-not-exist"
  pullPolicy: Always   # force re-pull so ImagePullBackOff fires even on a warm cache
hpa:
  enabled: false
```

The kubelet tries to pull the image, the registry returns 404, and the pod enters
`ErrImagePull` → after retries → `ImagePullBackOff`.
No container ever starts, so logs are unavailable — the analyst reads evidence from
pod_status and events only.

---

## Running scenarios

### Prerequisites

```bash
make cluster-up
make argocd-install
make argocd-bootstrap
make install   # chmod +x all scripts, adds noctua to PATH
```

### S01 — CrashLoopBackOff

```bash
make s01
# → Fault injected. Output:
#   noctua investigate estate/ledger-api-<hash>
#   noctua investigate estate/ledger-api-<hash> --analyst llm

noctua investigate estate/ledger-api-<hash>
# → Analyst (rules) → rank 1: crash_loop_missing_env (86%)
#   "Container is crash-looping due to missing environment variable 'DATABASE_URL'."
```

### S02 — OOMKilled

```bash
make s02

noctua investigate estate/ledger-api-<hash>
# → Analyst (rules) → rank 1: oomkilled (90%)
#   "Container was OOM-killed. Memory limit is too low for the current workload."
```

### S03 — ImagePullBackOff

```bash
make s03

noctua investigate estate/inventory-svc-<hash>
# → Analyst (rules) → rank 1: image_pull_backoff (95%)
#   "Container image cannot be pulled. The image tag may not exist or registry credentials are missing."
```

### Reset

```bash
make reset
# → Restores all 3 services to healthy podinfo:6.7.0
# → Re-enables Argo CD auto-sync for each app
```

---

## Analyst modes

The `--analyst` flag selects which analyst runs. Default is `rules`.

```bash
noctua investigate estate/ledger-api-<hash>                   # rules (default)
noctua investigate estate/ledger-api-<hash> --analyst llm     # Azure OpenAI
noctua investigate estate/ledger-api-<hash> --analyst hybrid  # rules + llm merged
```

Or set via environment variable (useful for scripts):
```bash
export NOCTUA_ANALYST=llm
noctua investigate estate/ledger-api-<hash>
```

---

## LLM analyst — `noctua/analyst/llm.sh`

### Design

The LLM analyst is a **drop-in replacement** for `rules.sh`: same stdin/stdout contract,
same output schema. This allows the dispatcher (`analyst.sh`) to swap analysts without
changing anything downstream (report.sh, investigate.sh, tests).

```
stdin:  bundle JSON
stdout: hypotheses JSON array (identical schema to rules.sh output)
```

### Mock mode

Set `NOCTUA_LLM_MOCK=1` to skip the API call and return a synthetic response.
Used in bats tests and for demos without Azure credentials:

```bash
NOCTUA_LLM_MOCK=1 noctua investigate estate/ledger-api-<hash> --analyst llm
```

### Environment variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `AZURE_OPENAI_ENDPOINT` | Yes | — | Resource base URL e.g. `https://my-resource.openai.azure.com` |
| `AZURE_OPENAI_API_KEY` | Yes | — | API key for the resource |
| `AZURE_OPENAI_DEPLOYMENT` | No | `gpt-4o-mini` | Deployment name inside the resource |
| `AZURE_OPENAI_API_VERSION` | No | `2024-10-21` | API version for chat completions |
| `NOCTUA_LLM_MOCK` | No | `0` | Set to `1` to skip API call |

### System prompt

The LLM is told to output a JSON object with key `"hypotheses"`:
```
You are NOCTUA, an expert Kubernetes incident analyst.
Given evidence collected from a Kubernetes cluster, return a JSON object
with key "hypotheses" containing an array of ranked hypotheses...
```

Using `response_format: {type: "json_object"}` forces the model to output JSON.
The model must return `{"hypotheses": [...]}` matching the evidence bundle schema.

### Normalisation

The raw API response is normalised before returning:
```bash
echo "$content" | jq '
  (.hypotheses // (if type == "array" then . else [] end)) |
  sort_by(-.confidence) |
  to_entries |
  map(.value + {
    rank:         (.key + 1),
    confidence:   (clamp 0.0 to 1.0),
    rule:         (default "llm_hypothesis"),
    ...
  })'
```

This handles:
- Model returning `{"hypotheses": [...]}` → extract array
- Model returning bare array → use directly
- Missing/malformed fields → filled with safe defaults
- Confidence outside [0,1] → clamped

### Error handling

| Condition | Behaviour |
|---|---|
| `AZURE_OPENAI_ENDPOINT` not set | Exit 1 immediately (clear error message) |
| curl fails (network, timeout) | Log to stderr, return `[]` (safe empty) |
| API error response | Log error message to stderr, return `[]` |
| Empty response content | Log to stderr, return `[]` |
| Malformed JSON from model | Log to stderr, return `[]` |

The analyst never crashes `investigate.sh` — it always returns a valid (possibly empty) array.

---

## Analyst dispatcher — `noctua/analyst/analyst.sh`

```bash
#!/usr/bin/env bash
# --mode rules|llm|hybrid

case "$mode" in
  rules)
    echo "$bundle" | bash "$SCRIPT_DIR/rules.sh"
    ;;
  llm)
    echo "$bundle" | bash "$SCRIPT_DIR/llm.sh"
    ;;
  hybrid)
    rules_h=$(echo "$bundle" | bash "$SCRIPT_DIR/rules.sh")
    llm_h=$(echo "$bundle"   | bash "$SCRIPT_DIR/llm.sh")
    printf '%s\n%s\n' "$rules_h" "$llm_h" | jq -s '
      add |
      sort_by(-.confidence) |
      unique_by(.rule) |   ← keeps highest-confidence per rule, deduplicates
      to_entries |
      map(.value + {rank: (.key + 1)})'
    ;;
esac
```

**Hybrid mode** runs both analysts and merges the results:
- `printf '%s\n%s\n'` outputs both JSON arrays on separate lines
- `jq -s` slurps them: `[rules_array, llm_array]`
- `add` flattens to one array
- `sort_by(-.confidence)` orders by confidence
- `unique_by(.rule)` deduplicates — if both analysts agree on `crash_loop_missing_env`,
  only the highest-confidence instance is kept

The result is a combined ranked list where rule-based findings and LLM findings both appear,
deduplicated by rule name. If the LLM finds a new issue the rules missed, it appears as an
additional entry.

---

## `investigate.sh` — `--analyst` flag

```bash
# New flag added:
--analyst)  analyst="$2"; shift 2 ;;

# Default from environment variable (allows override via export):
analyst="${NOCTUA_ANALYST:-rules}"

# Analyse step now calls the dispatcher:
hypotheses=$(echo "$bundle" | "$SCRIPT_DIR/analyst/analyst.sh" --mode "$analyst")
```

---

## `test_llm.bats` — Tests

All tests use `NOCTUA_LLM_MOCK=1` — no API call, no credentials needed in CI.

| Test | What it verifies |
|---|---|
| `llm mock: returns a JSON array` | Output is `type == "array"` |
| `llm mock: array has at least one hypothesis` | Mock always returns 1 result |
| `llm mock: hypothesis has required fields` | rule, description, confidence, rank all present |
| `llm mock: confidence is between 0.0 and 1.0` | awk float comparison |
| `llm mock: rank is 1 for first hypothesis` | 1-based rank |
| `llm mock: works with oomkilled fixture` | Schema holds for different fixture |
| `llm mock: works with healthy fixture` | Mock returns result regardless of content |
| `llm: exits non-zero when credentials absent` | `:` bash expansion fails cleanly |
| `analyst --mode rules: returns valid array` | Dispatcher passes through to rules.sh |
| `analyst --mode llm: mock mode` | Dispatcher passes through to llm.sh |
| `analyst --mode hybrid: combines results` | hybrid ≥ rules alone in count |
| `analyst --mode hybrid: all entries have rank` | No null rank fields |
| `analyst --mode hybrid: sorted by confidence` | awk float comparison on [0] vs [1] |
| `analyst: unknown mode exits non-zero` | Error handling in dispatcher |

---

## Full end-to-end example

```bash
# 1. Bring up cluster and bootstrap GitOps
make cluster-up
make argocd-install
make argocd-bootstrap
kubectl get applications -n argocd   # wait for all to sync

# 2. Install noctua CLI
make install
export PATH=$PATH:$(pwd)/noctua

# 3. Inject S01 fault
make s01
# Output: noctua investigate estate/ledger-api-6d9f7b8-xzp5q

# 4. Run rule-based analyst (no Azure credentials needed)
noctua investigate estate/ledger-api-6d9f7b8-xzp5q -o s01-rules.md --json
cat s01-rules.md

# 5. Run LLM analyst (requires Azure credentials)
export AZURE_OPENAI_ENDPOINT=https://my-resource.openai.azure.com
export AZURE_OPENAI_API_KEY=sk-...
noctua investigate estate/ledger-api-6d9f7b8-xzp5q --analyst llm -o s01-llm.md

# 6. Run hybrid (both analysts, merged)
noctua investigate estate/ledger-api-6d9f7b8-xzp5q --analyst hybrid -o s01-hybrid.md

# 7. Reset to healthy
make reset
```

The `s01-rules.json` file (from `--json`) contains the full sealed bundle with hypotheses —
this is the artifact that Phase 4 (fix PR generation) will consume.
