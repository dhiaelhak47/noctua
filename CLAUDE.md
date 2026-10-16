NOCTUA — key decisions (updated 2026-10-15)

Full blueprint: https://claude.ai/code/artifact/aaa697cb-21ec-417c-82ce-03c45db52dab CKA + NOCTUA 12-week plan: https://claude.ai/code/artifact/b1101fd5-d6c0-4a9b-81a3-3381e61e14db

Concept: evidence-first incident investigation for Kubernetes on Azure. Deterministic collectors -> redacted, sealed evidence bundle -> LLM ranks cited hypotheses -> fixes only as GitHub PRs from an allowlisted action catalogue -> Argo CD applies after human merge -> verifier checks SLO recovery -> postmortem draft.
Positioning update: HolmesGPT, K8sGPT, Azure SRE Agent already do AI k8s diagnosis. Reposition NOCTUA as a reference platform + benchmark: pluggable analysts (rule-based, HolmesGPT, own LLM) scored on reproducible incidents; add build-vs-adopt ADR; consider upstream eval contributions. Runner-up concept: Azure drift-impact explainer.
Monetisation: primary value is career (senior/platform roles) and consulting/training; no direct product unless teams validate the benchmark idea. Check employment contract before side activity.
Codename NOCTUA. Tagline: "Every incident leaves evidence. Noctua reads it first."
Stack: Terraform, kind locally, AKS Free tier for demos (destroy, not stop), GitHub Actions + OIDC, Argo CD, Helm, Envoy Gateway, Kyverno, kube-prometheus-stack + Loki (+Tempo), Sloth, Python/FastAPI noctua-core, Postgres+pgvector, Azure OpenAI mini-class model.
Schedule (6 h/day, 5 days/week): CKA via KodeKloud 4 h/day + NOCTUA 2 h/day until exam Thu 19 Nov 2026 (go/no-go Wed 18 Nov on killer.sh >= 75%); then NOCTUA 6 h/day; holidays 21 Dec–1 Jan off; v1.0 launch week of 18 Jan 2027.
Status: next step is Implementation Prompt 1 (repo skeleton + slice 0).