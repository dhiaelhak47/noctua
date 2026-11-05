#!/usr/bin/env bash
# S02 — Inject OOMKilled into ledger-api (memory limit 4Mi)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART="$REPO_ROOT/charts/noctua-service"
BASE_VALUES="$REPO_ROOT/gitops/estate/ledger-api/values.yaml"
FAULT_VALUES="$REPO_ROOT/scenarios/faults/s02-oom.yaml"
NS="estate"
RELEASE="ledger-api"
SELECTOR="app.kubernetes.io/instance=${RELEASE}"

echo "── S02: OOMKilled (memory limit 4Mi) ────────────────────────────────────"

if command -v argocd &>/dev/null 2>&1; then
  echo "→ Pausing Argo CD auto-sync for ${RELEASE}..."
  argocd app set "$RELEASE" --sync-policy none 2>/dev/null || true
fi

echo "→ Applying fault via helm upgrade..."
helm upgrade "$RELEASE" "$CHART" \
  --namespace "$NS" \
  -f "$BASE_VALUES" \
  -f "$FAULT_VALUES"

echo "→ Waiting for OOMKilled or CrashLoopBackOff (up to 120s)..."
timeout 120 bash -c "
  until kubectl get pod -n '${NS}' -l '${SELECTOR}' --no-headers \
        | grep -qE 'CrashLoop|OOMKill|Error'; do
    sleep 3
  done
" && echo "→ Fault confirmed." || echo "WARN: timeout — pod may still be OOM-ing."

echo ""
echo "── Fault status ──────────────────────────────────────────────────────────"
kubectl get pod -n "$NS" -l "$SELECTOR"
echo ""

POD=$(kubectl get pod -n "$NS" -l "$SELECTOR" \
  --no-headers -o custom-columns=":metadata.name" | head -1)
echo "── Investigate ───────────────────────────────────────────────────────────"
echo "  noctua investigate ${NS}/${POD}"
echo "  noctua investigate ${NS}/${POD} --analyst llm"
echo "  noctua investigate ${NS}/${POD} --analyst hybrid -o s02-report.md --json"
