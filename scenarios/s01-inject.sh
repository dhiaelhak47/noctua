#!/usr/bin/env bash
# S01 — Inject CrashLoopBackOff with missing env var into ledger-api
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART="$REPO_ROOT/charts/noctua-service"
BASE_VALUES="$REPO_ROOT/gitops/estate/ledger-api/values.yaml"
FAULT_VALUES="$REPO_ROOT/scenarios/faults/s01-missing-env.yaml"
NS="estate"
RELEASE="ledger-api"
SELECTOR="app.kubernetes.io/instance=${RELEASE}"

echo "── S01: CrashLoopBackOff (KeyError: 'DATABASE_URL') ─────────────────────"

if command -v argocd &>/dev/null 2>&1; then
  echo "→ Pausing Argo CD auto-sync for ${RELEASE}..."
  argocd app set "$RELEASE" --sync-policy none 2>/dev/null || true
fi

echo "→ Applying fault via helm upgrade..."
helm upgrade "$RELEASE" "$CHART" \
  --namespace "$NS" \
  -f "$BASE_VALUES" \
  -f "$FAULT_VALUES"

echo "→ Waiting for CrashLoopBackOff or Error (up to 90s)..."
timeout 90 bash -c "
  until kubectl get pod -n '${NS}' -l '${SELECTOR}' --no-headers \
        | grep -qE 'CrashLoop|Error|OOMKill'; do
    sleep 3
  done
" && echo "→ Fault confirmed." || echo "WARN: timeout — pod may still be initialising."

echo ""
echo "── Fault status ──────────────────────────────────────────────────────────"
kubectl get pod -n "$NS" -l "$SELECTOR"
echo ""

POD=$(kubectl get pod -n "$NS" -l "$SELECTOR" \
  --no-headers -o custom-columns=":metadata.name" | head -1)
echo "── Investigate ───────────────────────────────────────────────────────────"
echo "  noctua investigate ${NS}/${POD}"
echo "  noctua investigate ${NS}/${POD} --analyst llm"
echo "  noctua investigate ${NS}/${POD} --analyst hybrid -o s01-report.md --json"
