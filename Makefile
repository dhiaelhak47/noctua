.PHONY: cluster-up cluster-down dev test lint

cluster-up:
	kind create cluster --config infra/kind/cluster.yaml

cluster-down:
	kind delete cluster --name noctua-local

dev:
	cd noctua-core && pip install -e ".[dev]"

test:
	cd noctua-core && pytest

lint:
	cd noctua-core && ruff check . && ruff format --check .
