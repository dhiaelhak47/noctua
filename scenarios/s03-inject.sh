#!/usr/bin/env bash
# S03 — Inject ImagePullBackOff into inventory-svc (non-existent image tag)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART="$REPO_ROOT/charts/noctua-service"
BASE_VALUES="$REPO_ROOT/gitops/estate/inventory-svc/values.yaml"
FAULT_VALUES="$REPO_ROOT/scenarios/faults/s03-bad-image.yaml"
NS="estate"
RELEASE="inventory-svc"
SELECTOR="app.kubernetes.io/instance=${RELEASE}"

echo "── S03: ImagePullBackOff (bad image tag) ────────────────────────────────"

if command -v argocd &>/dev/null 2>&1; then
  echo "→ Pausing Argo CD auto-sync for ${RELEASE}..."
  argocd app set "$RELEASE" --sync-policy none 2>/dev/null || true
fi

echo "→ Applying fault via helm upgrade..."
helm upgrade "$RELEASE" "$CHART" \
  --namespace "$NS" \
  -f "$BASE_VALUES" \
  -f "$FAULT_VALUES"

echo "→ Waiting for ImagePullBackOff or ErrImagePull (up to 60s)..."
timeout 60 bash -c "
  until kubectl get pod -n '${NS}' -l '${SELECTOR}' --no-headers \
        | grep -qE 'ImagePull|ErrImage'; do
    sleep 3
  done
" && echo "→ Fault confirmed." || echo "WARN: timeout — check pod status manually."

echo ""
echo "── Fault status ──────────────────────────────────────────────────────────"
kubectl get pod -n "$NS" -l "$SELECTOR"
echo ""

POD=$(kubectl get pod -n "$NS" -l "$SELECTOR" \
  --no-headers -o custom-columns=":metadata.name" | head -1)
echo "── Investigate ───────────────────────────────────────────────────────────"
echo "  noctua investigate ${NS}/${POD}"
echo "  noctua investigate ${NS}/${POD} --analyst llm"
echo "  noctua investigate ${NS}/${POD} --analyst hybrid -o s03-report.md --json"
