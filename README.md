# Noctua

> Every incident leaves evidence. Noctua reads it first.

Evidence-first incident investigation for Kubernetes on Azure.

## Architecture

Deterministic collectors → redacted, sealed evidence bundle → LLM ranks cited hypotheses → fixes as GitHub PRs from an allowlisted action catalogue → Argo CD applies after human merge → verifier checks SLO recovery → postmortem draft.

## Quick start

```bash
# Spin up local cluster
make cluster-up

# Install noctua-core for development
make dev

# Run tests
make test
```

## Stack

- **Runtime**: Kubernetes (kind locally, AKS for demos)
- **API**: Python / FastAPI
- **IaC**: Terraform
- **GitOps**: Argo CD + Helm
- **Observability**: kube-prometheus-stack, Loki, Tempo, Sloth
- **Policy**: Kyverno
- **Gateway**: Envoy Gateway
- **LLM**: Azure OpenAI
