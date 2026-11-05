# Phase 0 — First Light

> **Gate passed:** `noctua investigate` names a missing env var with evidence IDs, all bats tests green, shellcheck clean, tagged `v0.1`.

---

## Overview

Phase 0 delivers the minimal end-to-end slice: a single CLI command that inspects a Kubernetes pod, collects evidence, runs a deterministic rule-based analyst, and outputs a Markdown report with ranked hypotheses — all without touching a live LLM.

```bash
noctua investigate default/ledger-api-abc-123
```

Output:

```
Noctua investigating default/ledger-api-abc-123 …

# NOCTUA Evidence Report

**Bundle:** `e3f1a2b4-…`
**Pod:** `default/ledger-api-abc-123`
**Seal:** `7c4d91e0a2f3b815…`

## Hypotheses

### 1. Container is crash-looping due to missing environment variable 'DATABASE_URL'. …

- **Confidence:** 86%
- **Rule:** `crash_loop_missing_env`
- **Evidence:** E1, E2, E3
- **Suggested action:** rollback Helm values to previous revision or restore missing env var

## Evidence

### E1 — pod_status (`pod_status`)
…
```

---

## File structure

```
noctua/
├── noctua                     CLI entrypoint (add to PATH)
├── investigate.sh             Orchestrates: collect → seal → analyse → report
├── seal.sh                    SHA-256 of evidence array (deterministic, sorted keys)
├── report.sh                  Bundle JSON → Markdown report
├── redact.sh                  Strips emails, IPs, tokens before sealing
├── collectors/
│   ├── pod_status.sh          kubectl get pod -o json → phase + container states
│   ├── events.sh              kubectl get events --field-selector (last 50)
│   ├── logs.sh                kubectl logs --previous --tail=50
│   └── rollout.sh             Deployment revision history via ownerRef chain
├── analyst/
│   └── rules.sh               Rule-based analyst: 3 rules, grep + jq
└── tests/
    ├── test_bundle.bats        seal.sh correctness (4 tests)
    ├── test_analyst.bats       rule detection, confidence, ranking (12 tests)
    ├── test_report.bats        markdown output correctness (8 tests)
    └── fixtures/
        ├── crashloop_bundle.json
        ├── oomkilled_bundle.json
        ├── imagepull_bundle.json
        └── healthy_bundle.json
```

---

## Evidence bundle

The bundle is a JSON document produced and consumed by all scripts:

```json
{
  "bundle_id":      "<uuid>",
  "schema_version": "0.1",
  "created_at":     "2026-11-05T10:00:00Z",
  "namespace":      "default",
  "pod":            "ledger-api-abc-123",
  "sha256":         "<64-char hex>",
  "evidence": [
    {
      "id":           "E1",
      "kind":         "pod_status",
      "source":       "pod_status",
      "content":      "Pod: default/ledger-api-abc-123\nPhase: Running\n…",
      "collected_at": "2026-11-05T10:00:00Z"
    }
  ],
  "hypotheses": [
    {
      "rank":         1,
      "rule":         "crash_loop_missing_env",
      "description":  "Container is crash-looping due to missing environment variable 'DATABASE_URL'…",
      "evidence_ids": ["E1", "E2", "E3"],
      "confidence":   0.86,
      "action":       "rollback Helm values to previous revision or restore missing env var"
    }
  ]
}
```

### Sealing (`seal.sh`)

`seal.sh` reads the evidence array from stdin, runs `jq -cS '.'` (compact + sorted keys for determinism), and pipes to `sha256sum`. The result is a 64-char hex string stored in `bundle.sha256`.

The seal is tamper-evident: any change to any evidence item changes the hash.

---

## Collectors

Each collector is a standalone script: `collectors/<name>.sh namespace pod`. It writes human-readable text to stdout, which `investigate.sh` wraps into a JSON evidence item.

### pod_status.sh

Calls `kubectl get pod -o json`. Serialises: pod phase, per-container name/ready/restart count/image, current state (Waiting/Running/Terminated with reason and exit code), last-terminated state.

Detects `CrashLoopBackOff`, `OOMKilled`, `ImagePullBackOff` — all three rules rely on this output.

### events.sh

Calls `kubectl get events --field-selector involvedObject.name=<pod>`, limit 50, sorted by `lastTimestamp`. Output is a fixed-width table:

```
Last Seen             Type       Reason                    Message
--------------------------------------------------------------------------------
2026-11-05T09:55:00   Warning    BackOff                   Back-off restarting failed container
```

### logs.sh

Calls `kubectl logs --previous --tail=50`. Fetches the logs of the *previous* container run — the one that crashed — containing the stack trace or error message needed to identify the root cause.

If no previous container exists, returns `"No previous container logs available."` without failing.

### rollout.sh

Walks the `ownerReferences` chain: Pod → ReplicaSet → Deployment. Lists all ReplicaSets for the Deployment (by label selector), sorted by `deployment.kubernetes.io/revision` annotation, marking the current one:

```
Deployment: default/ledger-api
Ready replicas: 0/1

Rev    ReplicaSet                                    Image
------------------------------------------------------------------------------------------
1      ledger-api-7f4d8b9c5                          ghcr.io/noctua/ledger-api:v1.4.1
2      ledger-api-6c3a1d8f2                          ghcr.io/noctua/ledger-api:v1.4.2 ← current
```

---

## Rule-based analyst (`analyst/rules.sh`)

Reads bundle JSON (stdin or file arg), extracts evidence content by kind, applies three rules, outputs a hypotheses JSON array sorted by confidence descending.

### Rules

| Rule ID | Trigger | Confidence | Action |
|---|---|---|---|
| `oomkilled` | `OOMKilled` in pod_status | 0.90 | Raise memory limit |
| `image_pull_backoff` | `ImagePullBackOff` or `ErrImagePull` in pod_status or events | 0.95 | Check image tag / imagePullSecrets |
| `crash_loop_missing_env` | `CrashLoopBackOff` + env var found in logs | 0.86 | Rollback Helm values |
| `crash_loop_missing_env` | `CrashLoopBackOff`, no env var found | 0.65 | Manual investigation |

### Env-var extraction

When `CrashLoopBackOff` is detected, `_extract_env_var()` scans previous-container logs and events for patterns:

| Pattern | Example |
|---|---|
| `KeyError: 'VAR'` | `KeyError: 'DATABASE_URL'` → `DATABASE_URL` |
| `$VAR is not set` | `$DB_PASSWORD is not set` → `DB_PASSWORD` |
| `missing env var: VAR` | `missing env var: SECRET_KEY` → `SECRET_KEY` |

---

## Report generator (`report.sh`)

Reads bundle JSON (stdin or file arg), outputs Markdown:

1. **Header** — bundle ID, pod, timestamp, first 16 chars of sha256
2. **Hypotheses** — ranked list with confidence %, rule ID, evidence IDs, suggested action
3. **Evidence** — each item in a fenced code block labelled with its ID, kind, and source

---

## Tests

Run with `make test` (requires `bats` and `jq`, no cluster required).

### test_bundle.bats (4 tests)
- seal produces 64-char hex sha256
- seal is deterministic for identical input
- seal changes when content changes
- seal is order-independent (key sorting)

### test_analyst.bats (12 tests)
- CrashLoop: detects rule, extracts DATABASE_URL, confidence ≥ 0.80, cites E1/E3
- OOMKilled: detects rule, confidence 0.90, is rank 1
- ImagePull: detects rule, confidence 0.95
- Healthy pod: empty hypotheses array
- Ranking: sorted by confidence desc, rank is 1-based

### test_report.bats (8 tests)
- Contains bundle_id, DATABASE_URL, E1/E2/E3, CrashLoopBackOff content, sha256 seal
- Healthy pod shows "Manual investigation required"
- Confidence shown as 95%
- Suggested action present

---

## Dependencies

| Tool | Purpose |
|---|---|
| `bash` | All scripts |
| `kubectl` | Cluster evidence collection |
| `jq` | JSON assembly, parsing, sealing |
| `sha256sum` | Bundle sealing (GNU coreutils) |
| `grep`, `sed`, `awk` | Pattern matching in analyst |
| `bats` | Test runner |
| `shellcheck` | Linter |

---

## Local quickstart

```bash
# 1. Install deps: jq, bats, shellcheck
make check-deps

# 2. Make executable + add to PATH
make install
export PATH=$PATH:$(pwd)/noctua

# 3. Start local cluster
make cluster-up

# 4. Run tests (no cluster needed)
make test

# 5. Deploy a crashing pod
kubectl run crash-test \
  --image=busybox --restart=Always \
  -- sh -c 'echo "KeyError: '\''DATABASE_URL'\''"; exit 1'

# 6. Investigate
noctua investigate default/crash-test
```

---

## What Phase 0 does NOT do

- No LLM calls (analyst is purely rule-based)
- No persistence (bundle exists in memory/stdout only)
- No alerting integration (investigation is triggered manually)
- No PR creation (Phase 4)
- No redaction at collection time (redact.sh exists but is not wired into collect yet)

---

## What comes next — Phase 1

Phase 1 installs the full observability platform on the local kind cluster via Argo CD:

- Argo CD app-of-apps
- Envoy Gateway + cert-manager
- kube-prometheus-stack (Prometheus, Grafana, Alertmanager)
- Loki (log aggregation)
- Sloth (SLO definitions — 99.5% availability, p95 < 300 ms)
- CI hardening: Trivy image scan, SBOM generation, Cosign keyless signing

**Gate:** a commit only reaches the cluster via CI → Git → Argo CD; an unsigned image is rejected by Kyverno.
