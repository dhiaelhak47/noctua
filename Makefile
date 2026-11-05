.PHONY: cluster-up cluster-down install test lint check-deps

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
