.PHONY: cluster-up cluster-down install test lint check-deps argocd-install argocd-bootstrap helm-lint

cluster-up:
	kind create cluster --config infra/kind/cluster.yaml

cluster-down:
	kind delete cluster --name noctua-local

install:
	chmod +x noctua/noctua noctua/investigate.sh noctua/seal.sh \
	         noctua/report.sh noctua/redact.sh \
	         noctua/collectors/*.sh noctua/analyst/rules.sh
	@echo "Add to PATH: export PATH=\$$PATH:$(CURDIR)/noctua"

test:
	bats noctua/tests/

lint:
	shellcheck noctua/noctua noctua/investigate.sh noctua/seal.sh \
	           noctua/report.sh noctua/redact.sh \
	           noctua/collectors/*.sh noctua/analyst/rules.sh

check-deps:
	@command -v jq       >/dev/null 2>&1 || { echo "ERROR: jq is required (https://jqlang.github.io/jq/)"; exit 1; }
	@command -v kubectl  >/dev/null 2>&1 || { echo "ERROR: kubectl is required"; exit 1; }
	@command -v bats     >/dev/null 2>&1 || { echo "ERROR: bats is required (https://github.com/bats-core/bats-core)"; exit 1; }
	@command -v shellcheck >/dev/null 2>&1 || { echo "WARN: shellcheck not found (optional for local dev)"; }
	@echo "All required dependencies found."

argocd-install:
	kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.13.0/manifests/install.yaml
	@echo "Waiting for Argo CD to be ready..."
	kubectl wait --for=condition=available --timeout=120s deployment/argocd-server -n argocd
	@echo "Argo CD ready. Bootstrap with: make argocd-bootstrap"

argocd-bootstrap:
	kubectl apply -f gitops/apps/bootstrap.yaml
	@echo "Bootstrap applied. Watch: kubectl get applications -n argocd"

helm-lint:
	helm lint charts/noctua-service -f gitops/estate/atlas-gateway/values.yaml
	helm lint charts/noctua-service -f gitops/estate/ledger-api/values.yaml
	helm lint charts/noctua-service -f gitops/estate/inventory-svc/values.yaml
