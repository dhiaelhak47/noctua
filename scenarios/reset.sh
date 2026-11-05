#!/usr/bin/env bash
# Restore all 3 services to their healthy base values, re-enable Argo CD auto-sync.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART="$REPO_ROOT/charts/noctua-service"
NS="estate"

declare -A SERVICES=(
  [atlas-gateway]="$REPO_ROOT/gitops/estate/atlas-gateway/values.yaml"
  [ledger-api]="$REPO_ROOT/gitops/estate/ledger-api/values.yaml"
  [inventory-svc]="$REPO_ROOT/gitops/estate/inventory-svc/values.yaml"
)

for svc in atlas-gateway ledger-api inventory-svc; do
  base="${SERVICES[$svc]}"
  echo "→ Restoring ${svc}..."
  # Note: no --reuse-values — this fully replaces the values with the base file,
  # removing any fault overrides from the previous inject.
  helm upgrade "$svc" "$CHART" \
    --namespace "$NS" \
    -f "$base"

  if command -v argocd &>/dev/null 2>&1; then
    echo "   Re-enabling Argo CD auto-sync for ${svc}..."
    argocd app set "$svc" --sync-policy automated 2>/dev/null || true
  fi
done

echo ""
echo "── All services restored ─────────────────────────────────────────────────"
kubectl get pods -n "$NS"
