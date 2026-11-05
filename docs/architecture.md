# NOCTUA — Architecture Overview

## What NOCTUA is

NOCTUA is an **evidence-first incident investigation platform** for Kubernetes on Azure.
The core idea: before any AI hypothesis is generated, raw evidence is collected, sealed,
and stored. The AI analyst only sees the sealed evidence — it cannot modify it.

Tagline: *"Every incident leaves evidence. Noctua reads it first."*

---

## The pipeline (end to end)

```
kubectl / k8s API
      │
      ▼
┌─────────────────────────────────┐
│  COLLECTORS  (read-only)        │
│  pod_status · events · logs     │
│  rollout_history                │
└────────────────┬────────────────┘
                 │  raw text strings
                 ▼
┌─────────────────────────────────┐
│  SEAL (sha256)                  │  ← tamper-evidence
│  jq -cS '.' | sha256sum        │
└────────────────┬────────────────┘
                 │  sealed JSON bundle
                 ▼
┌─────────────────────────────────┐
│  ANALYST  (rule-based today)    │
│  rules.sh → hypotheses[]        │
│  (LLM analyst in later phases)  │
└────────────────┬────────────────┘
                 │  bundle + hypotheses
                 ▼
┌─────────────────────────────────┐
│  REPORT  (Markdown)             │
│  report.sh → human-readable    │
└─────────────────────────────────┘
```

**Planned extensions (later phases):**
```
hypotheses → GitHub PR  → Argo CD applies fix → verifier checks SLO → postmortem draft
```

---

## Component map

```
noctua/                      ← the CLI tool (all bash + jq)
│
├── noctua                   ← entry point / dispatcher
├── investigate.sh           ← orchestrator: collect → seal → analyse → report
├── seal.sh                  ← SHA-256 of sorted-key JSON (tamper evidence)
├── redact.sh                ← strips emails, IPs, tokens before storage
├── report.sh                ← bundle JSON → Markdown human report
│
├── collectors/
│   ├── pod_status.sh        ← kubectl get pod -o json → structured text
│   ├── events.sh            ← kubectl get events (table)
│   ├── logs.sh              ← kubectl logs --previous --tail=50
│   └── rollout.sh           ← ownerRef chain → revision table
│
└── analyst/
    └── rules.sh             ← 3 deterministic rules → hypotheses[]
        ├── Rule 1: OOMKilled       (confidence 0.90)
        ├── Rule 2: ImagePullBackOff (confidence 0.95)
        └── Rule 3: CrashLoopBackOff ± missing env var (0.86 / 0.65)

charts/
└── noctua-service/          ← shared Helm chart (all 3 demo services)
    ├── Chart.yaml
    ├── values.yaml          ← safe defaults
    └── templates/
        ├── deployment.yaml  ← hardened securityContext
        ├── service.yaml
        ├── hpa.yaml         ← autoscaling/v2 (CPU-based)
        ├── networkpolicy.yaml ← default-deny + allow gateway + prometheus
        ├── servicemonitor.yaml ← Prometheus scrape via ServiceMonitor CRD
        └── httproute.yaml   ← Gateway API HTTPRoute (Envoy Gateway)

gitops/
├── apps/                    ← Argo CD app-of-apps (bootstrap + children)
│   ├── bootstrap.yaml       ← applied ONCE manually; self-manages from then on
│   ├── estate.yaml          ← 3 service Applications (atlas-gateway, ledger-api, inventory-svc)
│   ├── monitoring.yaml      ← kube-prometheus-stack + loki
│   ├── kyverno.yaml         ← kyverno + kyverno-policies
│   └── envoy-gateway.yaml   ← envoy-gateway + noctua-gateway
│
├── estate/                  ← per-service Helm value overrides
│   ├── atlas-gateway/values.yaml
│   ├── ledger-api/values.yaml
│   └── inventory-svc/values.yaml
│
├── gateway/                 ← GatewayClass + Gateway resources
└── namespace/estate.yaml    ← namespace with gateway routing label

security/kyverno/            ← ClusterPolicies (enforced on estate namespace)
├── require-limits.yaml      ← CPU + memory limits mandatory
├── no-latest-tag.yaml       ← :latest tag banned
└── no-privileged.yaml       ← privileged containers banned

observability/sloth/         ← Sloth SLO definitions
└── slos.yaml                ← 99.5% availability + p95 < 300ms per service

infra/
├── kind/cluster.yaml        ← local dev cluster
└── terraform/               ← AKS Free tier (Phase 2)
    ├── providers.tf
    ├── main.tf
    ├── variables.tf
    └── outputs.tf

noctua/rbac/                 ← K8s RBAC for the noctua collector SA (Phase 2)
├── namespace.yaml
├── serviceaccount.yaml
├── clusterrole.yaml         ← get/list/watch pods/events/logs ONLY
└── clusterrolebinding.yaml
```

---

## Security model

| Actor | Permissions |
|---|---|
| `noctua` ServiceAccount | `get`, `list`, `watch` on pods, events, pod/log — **no secrets** |
| Argo CD | Only write actor — applies Git-sourced manifests |
| GitHub Actions | OIDC federated — no long-lived secrets stored |
| AI analyst | Reads sealed bundle only — never touches the cluster |

The AI never holds cluster credentials. It receives a sealed, tamper-evident JSON bundle and returns ranked hypotheses. Any fix is proposed as a GitHub PR against the Helm values, reviewed by a human, then merged — at which point Argo CD applies it.

---

## Evidence bundle schema (v0.1)

```json
{
  "bundle_id":      "uuid-v4",
  "schema_version": "0.1",
  "created_at":     "2026-11-05T10:00:00Z",
  "namespace":      "estate",
  "pod":            "ledger-api-abc-123",
  "sha256":         "64-hex-char SHA-256 of evidence[] with sorted keys",
  "evidence": [
    {
      "id":           "E1",
      "kind":         "pod_status | event | log | rollout",
      "source":       "collector name",
      "content":      "raw text collected from the cluster",
      "collected_at": "2026-11-05T10:00:00Z"
    }
  ],
  "hypotheses": [
    {
      "rank":         1,
      "rule":         "crash_loop_missing_env",
      "description":  "human-readable explanation",
      "confidence":   0.86,
      "evidence_ids": ["E1", "E2", "E3"],
      "action":       "suggested remediation"
    }
  ]
}
```

The `sha256` field is a **seal** — computed by `seal.sh` over the `evidence[]` array with
JSON keys sorted (`jq -cS '.'`). If any evidence item is modified after collection, the
seal will not match.

---

## Stack

| Layer | Technology |
|---|---|
| Local cluster | kind |
| Cloud cluster | AKS Free tier (destroy when not demoing) |
| GitOps | Argo CD (app-of-apps pattern) |
| Packaging | Helm (one chart, per-service value overrides) |
| Ingress | Envoy Gateway + Gateway API HTTPRoutes |
| Observability | kube-prometheus-stack + Loki |
| SLOs | Sloth (PrometheusServiceLevel CRDs) |
| Policy | Kyverno ClusterPolicies |
| IaC | Terraform |
| CI | GitHub Actions + OIDC (no long-lived secrets) |
| AI | Azure OpenAI (mini-class model, later phases) |
| Core tool | Bash + jq (zero Python in the control plane) |
