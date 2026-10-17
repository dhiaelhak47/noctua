# Phase 0 — First Light

> **Gate passed:** `noctua investigate` names a missing env var with evidence IDs, 21 tests green, pre-commit clean, tagged `v0.1`.

---

## Overview

Phase 0 delivers the minimal end-to-end slice: a single CLI command that inspects a Kubernetes pod, collects evidence, runs a deterministic rule-based analyst, and outputs a Markdown report with ranked hypotheses — all without touching a live LLM.

```
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
- **Evidence:** E1, E2, E3, E4
- **Suggested action:** rollback Helm values to previous revision or restore missing env var

## Evidence

### E1 — pod_status (`pod_status`)
…
```

---

## File structure

```
noctua-core/
├── src/noctua/
│   ├── models/
│   │   └── bundle.py          # EvidenceBundle, EvidenceItem, Hypothesis
│   ├── collectors/
│   │   ├── base.py            # CollectorBase ABC
│   │   ├── pod_status.py      # Pod phase, container state, restart count
│   │   ├── events.py          # Last 50 events (filtered by pod name)
│   │   ├── logs.py            # Previous-container logs (tail 50 lines)
│   │   └── rollout.py         # Rollout history via ownerRef chain
│   ├── analyst/
│   │   ├── base.py            # AnalystProvider ABC
│   │   └── rules.py           # RuleBasedAnalyst (3 rules)
│   ├── report.py              # render_markdown()
│   ├── cli.py                 # `noctua investigate` CLI entry point
│   ├── api/
│   │   └── health.py          # GET /healthz
│   └── main.py                # FastAPI app
└── tests/
    ├── test_bundle.py          # Schema + seal tests
    ├── test_analyst.py         # Rule coverage + env-var extraction
    ├── test_report.py          # Report content tests
    └── test_health.py          # /healthz endpoint
```

---

## Evidence bundle

**File:** `noctua-core/src/noctua/models/bundle.py`

The `EvidenceBundle` is the central data structure. Every investigation produces one.

```python
class EvidenceBundle(BaseModel):
    bundle_id: str          # UUIDv4, unique per investigation
    schema_version: str     # "0.1"
    created_at: datetime
    namespace: str
    pod: str
    evidence: list[EvidenceItem]    # populated by collectors
    hypotheses: list[Hypothesis]    # populated by analyst
    sha256: str             # set by .seal()
```

### EvidenceItem

```python
class EvidenceItem(BaseModel):
    id: str          # E1, E2, … — assigned by bundle.assign_ids()
    kind: EvidenceKind   # pod_status | event | log | rollout
    source: str      # collector name
    content: str     # human-readable text (passed verbatim to LLM later)
    collected_at: datetime
```

### Sealing

`bundle.seal()` does two things in order:

1. Assigns sequential IDs (`E1`, `E2`, …) to every evidence item.
2. Computes a `sha256` over the serialised evidence list (sorted keys, deterministic).

The seal makes the bundle tamper-evident: if any evidence is altered after sealing, the hash no longer matches. This is a prerequisite for the LLM analyst (Phase 3), which must only reason over the sealed bundle.

### Hypothesis

```python
class Hypothesis(BaseModel):
    rank: int           # 1 = most confident
    rule: str           # rule identifier
    description: str    # human-readable, may name specific env var / image
    evidence_ids: list[str]   # must cite sealed bundle items
    confidence: float   # 0.0–1.0
    action: str | None  # from the allowlisted action catalogue
```

---

## Collectors

**Interface:** `noctua-core/src/noctua/collectors/base.py`

```python
class CollectorBase(ABC):
    @abstractmethod
    def collect(self, namespace: str, pod: str) -> list[EvidenceItem]: ...
```

All four collectors are instantiated with a live `kubernetes` client object, making them testable via mocking and reusable across CLI and future API webhook paths.

### PodStatusCollector

**File:** `collectors/pod_status.py`

Calls `CoreV1Api.read_namespaced_pod()` and serialises:

- Pod phase
- Per-container: name, ready, restart count, image, current state (Waiting/Running/Terminated with reason and exit code), last-terminated state

Detects `CrashLoopBackOff`, `OOMKilled`, `ImagePullBackOff` — all three rules rely on this item.

### EventsCollector

**File:** `collectors/events.py`

Calls `CoreV1Api.list_namespaced_event()` with `field_selector=involvedObject.name=<pod>`, limit 50. Events are sorted by `last_timestamp` and formatted as a fixed-width table:

```
Last Seen            Type       Reason                    Message
--------------------------------------------------------------------------------
2026-10-17T08:12:03  Warning    BackOff                   Back-off restarting failed container
```

### LogsCollector

**File:** `collectors/logs.py`

Calls `CoreV1Api.read_namespaced_pod_log()` with `previous=True, tail_lines=50`. This fetches the logs of the *previous* container run — the one that crashed — which contains the stack trace or error message needed to identify the root cause.

A `400` response from the API means no previous container exists (pod never crashed or logs were GC'd); this is handled gracefully by returning a descriptive `EvidenceItem` instead of raising.

### RolloutCollector

**File:** `collectors/rollout.py`

Walks the `ownerReferences` chain to reconstruct deployment history:

```
Pod  →  ownerRef[kind=ReplicaSet]  →  ownerRef[kind=Deployment]
                                              ↓
                            list all ReplicaSets by label selector
                            sort by annotation deployment.kubernetes.io/revision
```

Output shows each revision with its ReplicaSet name and container image, marking the current one:

```
Deployment: default/ledger-api
Ready replicas: 0/1

Rev    ReplicaSet                                    Image
------------------------------------------------------------------------------------------
1      ledger-api-7f4d8b9c5                          ghcr.io/noctua/ledger-api:v1.4.1
2      ledger-api-6c3a1d8f2                          ghcr.io/noctua/ledger-api:v1.4.2 ← current
```

This makes it immediately visible that v1.4.2 is the current (crashing) revision and v1.4.1 was the last stable one — the rollback target.

---

## Rule-based analyst

**File:** `noctua-core/src/noctua/analyst/rules.py`

**Interface:** `noctua-core/src/noctua/analyst/base.py`

```python
class AnalystProvider(ABC):
    @abstractmethod
    def analyse(self, bundle: EvidenceBundle) -> EvidenceBundle: ...
```

`RuleBasedAnalyst` is the Phase 0 implementation. It makes no network calls — deterministic, fast, and usable in CI. It is also the fallback in all later phases when the LLM is unavailable.

### Rules

| Rule ID | Trigger | Confidence | Action |
|---------|---------|-----------|--------|
| `oomkilled` | `OOMKilled` in pod_status | 0.90 | Raise memory limit |
| `image_pull_backoff` | `ImagePullBackOff` or `ErrImagePull` in pod_status or events | 0.95 | Check image tag / imagePullSecrets |
| `crash_loop_missing_env` | `CrashLoopBackOff` in pod_status + env var found in logs | 0.86 | Rollback Helm values |
| `crash_loop_missing_env` | `CrashLoopBackOff` in pod_status, no env var found | 0.65 | Manual investigation |

Rules are checked in order of **decreasing specificity** (OOMKilled before CrashLoop) so that a pod which is OOM-killed and then crash-loops gets both hypotheses, ranked correctly by confidence.

### Env-var extraction

When `CrashLoopBackOff` is detected, the analyst scans previous-container logs and events for five patterns to identify *which* env var caused the crash:

| Pattern | Example match |
|---------|--------------|
| `KeyError: '<VAR>'` | `KeyError: 'DATABASE_URL'` → `DATABASE_URL` |
| `missing env var: <VAR>` | `missing env var: SECRET_KEY` → `SECRET_KEY` |
| `environment variable: <VAR> is not set` | → `API_TOKEN` |
| `env var not found: <VAR>` | → `DB_HOST` |
| `$<VAR> is not set` | `$DB_PASSWORD is not set` → `DB_PASSWORD` |

If a var is found, confidence is 0.86 and the var name is embedded in the hypothesis description. If not found, confidence drops to 0.65 and the description is generic.

### Ranking

After all rules run, hypotheses are sorted descending by `confidence` and assigned sequential `rank` values (1 = highest).

---

## Report generator

**File:** `noctua-core/src/noctua/report.py`

`render_markdown(bundle: EvidenceBundle) -> str` produces a Markdown document with:

1. **Header** — bundle ID, pod, timestamp, first 16 chars of sha256
2. **Hypotheses** — ranked list, each citing its evidence IDs, confidence, rule ID, and suggested action
3. **Evidence** — each item in a fenced code block, labelled with its ID, kind, and source

Evidence IDs in hypotheses are direct cross-references to items in the evidence section, so a reader can jump from "Evidence: E1, E2" to the exact pod status and log that triggered the rule.

---

## CLI

**File:** `noctua-core/src/noctua/cli.py`

Entry point registered in `pyproject.toml`:

```toml
[project.scripts]
noctua = "noctua.cli:app"
```

### Usage

```
noctua investigate [OPTIONS] TARGET

Arguments:
  TARGET  <namespace>/<pod>  or just <pod>  (namespace defaults to "default")

Options:
  -n, --namespace TEXT   Kubernetes namespace  [default: default]
  -o, --output PATH      Write report to file
  --json                 Also write bundle JSON alongside the report
  --help                 Show this message and exit.
```

### Examples

```bash
# Print report to terminal (rich-rendered Markdown)
noctua investigate default/ledger-api-abc-123

# Shorthand — namespace/pod in one arg
noctua investigate default/ledger-api-abc-123

# Save report to file
noctua investigate ledger-api-abc-123 -n default -o report.md

# Save both report and bundle JSON
noctua investigate ledger-api-abc-123 -o report.md --json
```

### Kubeconfig

The CLI tries `~/.kube/config` first, then in-cluster config (when running as a Pod). The cluster created for NOCTUA development (`noctua-local`) is picked up automatically:

```bash
kind create cluster --config infra/kind/cluster.yaml
# → context "kind-noctua-local" is written to ~/.kube/config
noctua investigate default/<pod-name>
```

---

## FastAPI service

**Files:** `noctua-core/src/noctua/main.py`, `noctua-core/src/noctua/api/health.py`

The FastAPI app is the host for the future webhook endpoint (Phase 2). Phase 0 exposes only the health check:

```
GET /healthz  →  {"status": "ok", "version": "0.1.0"}
```

Run locally:

```bash
cd noctua-core
uvicorn noctua.main:app --reload --port 8080
```

---

## Dependencies

Added in Phase 0 (`noctua-core/pyproject.toml`):

| Package | Version | Purpose |
|---------|---------|---------|
| `fastapi` | ≥0.115 | HTTP API host |
| `uvicorn[standard]` | ≥0.32 | ASGI server |
| `pydantic` | ≥2.9 | Evidence bundle schema and validation |
| `pydantic-settings` | ≥2.6 | Future settings management |
| `httpx` | ≥0.27 | Async HTTP client (tests + future collectors) |
| `kubernetes` | ≥29 | Kubernetes Python client (all four collectors) |
| `typer` | ≥0.12 | CLI framework |
| `rich` | ≥13 | Terminal Markdown rendering |

Dev extras: `pytest`, `pytest-asyncio`, `ruff`, `mypy`.

---

## Tests

**21 tests, all green.** Run with:

```bash
cd noctua-core
pytest -v
```

### test_bundle.py (4 tests)

| Test | What it checks |
|------|---------------|
| `test_assign_ids_sequential` | E1, E2, E3 in order |
| `test_seal_sets_sha256` | 64-char hex string after seal |
| `test_seal_is_deterministic` | Same input → same sha256 |
| `test_seal_changes_on_content_change` | Different content → different sha256 |

### test_analyst.py (10 tests)

| Test | What it checks |
|------|---------------|
| `test_crash_loop_with_keyerror_names_env_var` | `DATABASE_URL` in description, both evidence IDs cited, confidence 0.86 |
| `test_crash_loop_without_env_var_has_lower_confidence` | Confidence 0.65 when no var found |
| `test_oomkilled_detected` | `oomkilled` rule, confidence 0.90 |
| `test_image_pull_backoff_detected` | `image_pull_backoff` rule, confidence 0.95, both evidence IDs |
| `test_no_match_returns_empty_hypotheses` | Healthy pod → `[]` |
| `test_hypotheses_ranked_by_descending_confidence` | OOMKilled ranks above CrashLoop |
| `test_env_var_extraction_patterns[KeyError…]` | `DATABASE_URL` |
| `test_env_var_extraction_patterns[missing env var…]` | `SECRET_KEY` |
| `test_env_var_extraction_patterns[environment variable…]` | `API_TOKEN` |
| `test_env_var_extraction_patterns[$DB_PASSWORD…]` | `DB_PASSWORD` |

### test_report.py (6 tests)

| Test | What it checks |
|------|---------------|
| `test_report_contains_bundle_id` | UUID in report header |
| `test_report_contains_env_var_in_hypothesis` | `DATABASE_URL` in hypotheses section |
| `test_report_contains_evidence_ids` | `E1`, `E2` present |
| `test_report_contains_evidence_content` | `CrashLoopBackOff` in evidence block |
| `test_report_contains_seal` | First 16 chars of sha256 in header |
| `test_empty_hypotheses_message` | `"Manual investigation required"` for healthy pod |

### test_health.py (1 test)

`GET /healthz` returns `{"status": "ok"}`.

---

## Local quickstart

```bash
# 1. Clone and enter the repo
git clone https://github.com/dhiaelhak47/noctua.git
cd noctua

# 2. Start local cluster (kind must be installed)
make cluster-up
# → creates kind-noctua-local with 1 control-plane + 2 workers

# 3. Install noctua-core in development mode
make dev

# 4. Run tests
make test

# 5. Deploy a crashing pod (example)
kubectl run crash-test --image=busybox \
  --restart=Always \
  -- sh -c 'echo "KeyError: '"'"'DATABASE_URL'"'"'"; exit 1'

# 6. Investigate
noctua investigate default/crash-test
```

---

## What Phase 0 does NOT do

- No LLM calls (analyst is purely rule-based)
- No persistence (bundle exists only in memory during the CLI run)
- No alerting integration (investigation is triggered manually)
- No PR creation (fix proposals come in Phase 4)
- No redaction of sensitive values (planned for Phase 2)

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
