# Noctua

> Every incident leaves evidence. Noctua reads it first.

Evidence-first incident investigation for Kubernetes on Azure.

## Architecture

Deterministic collectors → redacted, sealed evidence bundle → LLM ranks hypotheses → fixes as GitHub PRs from an allowlisted action catalogue → Argo CD applies after human merge → verifier checks SLO recovery → postmortem draft.

## Quick start

```bash
# Install dependencies (jq, bats, shellcheck, kubectl)
make check-deps

# Make scripts executable and add noctua/ to PATH
make install
export PATH=$PATH:$(pwd)/noctua

# Spin up local cluster
make cluster-up

# Investigate a pod
noctua investigate default/my-pod

# Write report to file + JSON bundle
noctua investigate -o report.md --json my-namespace/my-pod

# Run tests (no cluster required)
make test

# Lint shell scripts
make lint
```

## Stack

- **Runtime**: Kubernetes (kind locally, AKS for demos)
- **Collectors**: shell scripts + `kubectl` + `jq`
- **Analyst**: rule-based (`grep` + `jq`) → LLM (Phase 3)
- **IaC**: Terraform
- **GitOps**: Argo CD + Helm
- **Observability**: kube-prometheus-stack, Loki, Tempo, Sloth
- **Policy**: Kyverno
- **Gateway**: Envoy Gateway
- **LLM**: Azure OpenAI (Phase 3+)
- **Testing**: bats + shellcheck

## Evidence bundle

Each investigation produces a sealed, schema-versioned JSON bundle:

```json
{
  "bundle_id":      "<uuid>",
  "schema_version": "0.1",
  "created_at":     "<iso8601>",
  "namespace":      "default",
  "pod":            "ledger-api-abc-123",
  "sha256":         "<64-char hex>",
  "evidence":       [ { "id": "E1", "kind": "pod_status", ... } ],
  "hypotheses":     [ { "rank": 1, "rule": "crash_loop_missing_env", "confidence": 0.86, ... } ]
}
```

The SHA-256 seals the evidence array — any tampered content changes the hash.

## Project layout

```
noctua/
  noctua                   CLI entrypoint (add to PATH)
  investigate.sh           Orchestrates collection → seal → analyse → report
  seal.sh                  SHA-256 seal of evidence array
  report.sh                Bundle JSON → markdown report
  redact.sh                Strips emails, IPs, tokens before sealing
  collectors/
    pod_status.sh          kubectl get pod -o json
    logs.sh                kubectl logs --previous
    events.sh              kubectl get events --field-selector
    rollout.sh             Deployment revision history via ReplicaSet chain
  analyst/
    rules.sh               Rule-based analyst: OOMKilled, ImagePullBackOff, CrashLoop
  tests/
    test_bundle.bats       seal.sh correctness
    test_analyst.bats      rule detection, confidence, ranking
    test_report.bats       markdown output correctness
    fixtures/              Pre-built bundles for offline testing
infra/
  kind/cluster.yaml        1 control-plane + 2 workers
```
