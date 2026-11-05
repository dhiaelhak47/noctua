# Phase 1 — GitOps, Helm Chart & Infrastructure

## What Phase 1 builds

- A shared Helm chart (`charts/noctua-service`) used by all 3 demo services
- An Argo CD app-of-apps that manages the entire cluster state from Git
- 3 demo services (atlas-gateway, ledger-api, inventory-svc) using podinfo as a placeholder
- Envoy Gateway for HTTP routing
- kube-prometheus-stack + Loki for observability
- Kyverno policies for security enforcement
- Sloth SLO definitions
- Security hardening: Trivy scans in CI, Helm lint as a gate

---

## Argo CD — App of Apps pattern

### How it works

```
You apply bootstrap.yaml ONCE manually
         │
         ▼
  Argo CD "bootstrap" Application
  watches gitops/apps/ in Git
         │
         ├─→ Application: atlas-gateway
         ├─→ Application: ledger-api
         ├─→ Application: inventory-svc
         ├─→ Application: kube-prometheus-stack
         ├─→ Application: loki
         ├─→ Application: kyverno
         ├─→ Application: kyverno-policies
         ├─→ Application: envoy-gateway
         └─→ Application: noctua-gateway
```

Argo CD monitors each Application. When you push a change to Git, Argo CD detects the
drift and syncs automatically (`automated: prune: true, selfHeal: true`).

### `gitops/apps/bootstrap.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: bootstrap
  namespace: argocd
spec:
  source:
    repoURL: https://github.com/dhiaelhak47/noctua.git
    targetRevision: HEAD
    path: gitops/apps          ← watches this directory
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true              ← delete resources removed from Git
      selfHeal: true           ← auto-revert manual changes to match Git
```

Apply once: `kubectl apply -f gitops/apps/bootstrap.yaml`
Then Argo CD manages itself — including the child Applications in `gitops/apps/`.

### `gitops/apps/estate.yaml` — 3 Applications

Each service gets its own Application, all pointing to the same chart path but with
different values files:

```yaml
spec:
  source:
    path: charts/noctua-service   ← shared Helm chart
    helm:
      valueFiles:
        - ../../../gitops/estate/atlas-gateway/values.yaml
        # path is relative to the chart directory
```

This "one chart, many value files" pattern avoids duplicating Deployment/Service/HPA
templates for each service.

---

## Helm chart — `charts/noctua-service/`

### `Chart.yaml`

Declares the chart name, version, and app version. `apiVersion: v2` = Helm 3.

### `values.yaml` — defaults

```yaml
replicaCount: 2
image:
  repository: ghcr.io/stefanprodan/podinfo
  tag: "6.7.0"              # podinfo has /healthz, /readyz, /metrics built in
  pullPolicy: IfNotPresent

resources:
  requests: { cpu: 50m, memory: 64Mi }
  limits:   { cpu: 200m, memory: 128Mi }   # Kyverno will reject pods without limits
```

Override any of these in a service-specific values file (e.g. `gitops/estate/ledger-api/values.yaml`).

### `templates/_helpers.tpl` — named templates

Helm helper templates are reusable snippets called with `include`:

```yaml
# In deployment.yaml:
name: {{ include "noctua-service.fullname" . }}
labels:
  {{- include "noctua-service.labels" . | nindent 4 }}
```

`nindent 4` indents every line of the output by 4 spaces (required for valid YAML
in a nested block like `labels:`). The `{{-` trims whitespace before the action.

Standard labels added to every resource:
```yaml
app.kubernetes.io/name:       # chart name
app.kubernetes.io/instance:   # Helm release name
app.kubernetes.io/version:    # chart appVersion
app.kubernetes.io/managed-by: # "Helm"
helm.sh/chart:                # chart name + version
```

### `templates/deployment.yaml` — hardened Pod spec

```yaml
spec:
  securityContext:
    runAsNonRoot: true          # pod-level: no root containers
    runAsUser: 1000
    seccompProfile:
      type: RuntimeDefault      # restricts syscalls to safe baseline
  containers:
    - securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true   # container can't write to its own fs
        capabilities:
          drop: ["ALL"]                # drop all Linux capabilities
```

Environment variables from `values.yaml`:
```yaml
env:
  {{- range $k, $v := .Values.env }}
  - name: {{ $k }}
    value: {{ $v | quote }}
  {{- end }}
# If values.yaml has: env: { DB_POOL_SIZE: "10" }
# This renders as: - name: DB_POOL_SIZE\n  value: "10"
```

### `templates/hpa.yaml` — Horizontal Pod Autoscaler

```yaml
{{- if .Values.hpa.enabled }}    ← conditional: only created if hpa.enabled=true
apiVersion: autoscaling/v2       ← v2 supports multiple metrics (CPU + memory + custom)
spec:
  scaleTargetRef:
    kind: Deployment
  minReplicas: {{ .Values.hpa.minReplicas }}   # 2 — always at least 2 for HA
  maxReplicas: {{ .Values.hpa.maxReplicas }}   # 5
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ .Values.hpa.targetCPUUtilizationPercentage }}  # 70
```

### `templates/networkpolicy.yaml` — default-deny + allowlist

```yaml
# Rule 1: default deny all ingress
spec:
  podSelector: {}       # selects ALL pods in namespace
  policyTypes: [Ingress]
  ingress: []           # empty = deny all
---
# Rule 2: allow from Envoy Gateway
- namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: envoy-gateway-system
---
# Rule 3: allow Prometheus to scrape
- namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: monitoring
  ports:
    - port: 9898   # podinfo metrics port
```

This means only the gateway (user traffic) and Prometheus (metrics) can reach pods.
Any other service trying to call another service directly is blocked.

### `templates/servicemonitor.yaml` — Prometheus discovery

```yaml
metadata:
  labels:
    release: kube-prometheus-stack   # ← CRITICAL: Prometheus only discovers ServiceMonitors with this label
spec:
  selector:
    matchLabels:
      {{- include "noctua-service.selectorLabels" . | nindent 6 }}  # finds the Service
  endpoints:
    - port: http
      path: {{ .Values.serviceMonitor.path }}   # /metrics
      interval: {{ .Values.serviceMonitor.interval }}  # 30s
```

### `templates/httproute.yaml` — Gateway API routing

```yaml
{{- if .Values.httpRoute.enabled }}
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
spec:
  parentRefs:
    - name: {{ .Values.httpRoute.gateway.name }}         # noctua-gateway
      namespace: {{ .Values.httpRoute.gateway.namespace }}  # envoy-gateway-system
  hostnames:
    {{- toYaml .Values.httpRoute.hostnames | nindent 4 }}  # atlas-gateway.noctua.local
  rules:
    - backendRefs:
        - name: {{ include "noctua-service.fullname" . }}
          port: {{ .Values.service.port }}
```

---

## Per-service values (`gitops/estate/`)

### `atlas-gateway/values.yaml`

```yaml
fullnameOverride: atlas-gateway
env:
  PODINFO_UI_MESSAGE: "atlas-gateway"   # podinfo shows this in its UI
httpRoute:
  enabled: true
  hostnames: [atlas-gateway.noctua.local]
```

### `ledger-api/values.yaml`

```yaml
env:
  DB_POOL_SIZE: "10"    # simulates a database connection pool setting
                         # used in the S01 (pool exhaustion) incident scenario
httpRoute:
  enabled: true
  hostnames: [ledger-api.noctua.local]
```

### `inventory-svc/values.yaml`

```yaml
env:
  READY_DELAY: "0"    # podinfo can delay readiness; "0" = healthy by default
                       # set to e.g. "60" to simulate S02 (slow startup) scenario
httpRoute:
  enabled: true
  hostnames: [inventory-svc.noctua.local]
```

---

## Envoy Gateway (`gitops/gateway/`)

### `gatewayclass.yaml`

```yaml
kind: GatewayClass
metadata:
  name: noctua
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
```

GatewayClass is cluster-scoped. It tells Kubernetes which controller handles Gateways
with `className: noctua`. Envoy Gateway watches for this class name.

### `gateway.yaml`

```yaml
kind: Gateway
metadata:
  name: noctua-gateway
  namespace: envoy-gateway-system
spec:
  gatewayClassName: noctua
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels:
              gateway.networking.k8s.io/allow-noctua: "true"
```

`allowedRoutes.namespaces.from: Selector` means only namespaces with the label
`gateway.networking.k8s.io/allow-noctua: "true"` can attach HTTPRoutes to this gateway.
This prevents rogue namespaces from hijacking traffic.

The `estate` namespace gets this label via `gitops/namespace/estate.yaml`.

---

## Kyverno policies (`security/kyverno/`)

All three policies use `validationFailureAction: Enforce` — Kyverno actively blocks
non-compliant pods (as opposed to `Audit` which only logs violations).

### `require-limits.yaml`

```yaml
match:
  any:
    - resources:
        kinds: [Pod]
        namespaces: [estate]     # scoped to estate only; monitoring namespace is exempt
validate:
  foreach:
    - list: "request.object.spec.containers"
      deny:
        conditions:
          any:
            - key: "{{ element.resources.limits.cpu || '' }}"
              operator: Equals
              value: ""           # deny if cpu limit is empty/missing
```

`foreach` iterates every container in the pod spec. If any container lacks limits,
the pod is rejected.

### `no-latest-tag.yaml`

```yaml
deny:
  conditions:
    any:
      - key: "{{ element.image }}"
        operator: Equals
        value: "*:latest"      # glob: any repo + :latest tag
      - key: "{{ element.image }}"
        operator: NotContains
        value: ":"             # no tag at all (defaults to :latest)
```

Both conditions are needed: `nginx:latest` matches the first, `nginx` (no tag) matches
the second.

### `no-privileged.yaml`

```yaml
deny:
  conditions:
    any:
      - key: "{{ element.securityContext.privileged || false }}"
        operator: Equals
        value: true
```

`|| false` is Kyverno JMESPath: if the field doesn't exist, default to `false`.
Only denies pods that explicitly set `privileged: true`.

---

## Sloth SLOs (`observability/sloth/slos.yaml`)

Sloth generates Prometheus recording rules and Prometheus alerting rules from a
higher-level SLO definition. Each service gets two SLOs:

### Availability SLO

```yaml
slos:
  - name: availability
    objective: 99.5     # 99.5% of requests must be non-5xx
    sli:
      events:
        errorQuery: sum(rate(http_requests_total{job="atlas-gateway",code=~"5.."}[{{.window}}]))
        totalQuery: sum(rate(http_requests_total{job="atlas-gateway"}[{{.window}}]))
```

Sloth fills `{{.window}}` with different burn-rate windows (1h, 6h, 72h) automatically
to generate multi-window alerts.

### Latency SLO

```yaml
  - name: latency-p95
    objective: 99.5     # 99.5% of requests must have p95 < 300ms
    sli:
      events:
        # Counts requests that completed WITHIN 300ms (le="0.3" bucket)
        errorQuery: sum(rate(http_request_duration_seconds_bucket{le="0.3"}[{{.window}}]))
        totalQuery: sum(rate(http_request_duration_seconds_count[{{.window}}]))
```

The latency SLO is expressed as "good events / total events" where a "good event" is
a request that completed in under 300ms.

---

## CI — Phase 1 additions (`.github/workflows/ci.yml`)

### `helm-lint` job

```yaml
- uses: azure/setup-helm@v4
  with:
    version: v3.16.3
- run: |
    helm lint charts/noctua-service -f gitops/estate/atlas-gateway/values.yaml
    helm lint charts/noctua-service -f gitops/estate/ledger-api/values.yaml
    helm lint charts/noctua-service -f gitops/estate/inventory-svc/values.yaml
```

`helm lint` renders templates with the given values and validates the YAML structure.
Running it with each values file catches per-service overrides that break the chart.

### `security-scan` job

```yaml
- uses: aquasecurity/trivy-action@0.28.0
  with:
    scan-type: config      # scans Helm/YAML/Dockerfile for misconfigurations
    scan-ref: charts/
    format: sarif          # GitHub Code Scanning format
    output: trivy-results.sarif
    exit-code: "0"         # non-blocking: creates findings but doesn't fail CI

- uses: github/codeql-action/upload-sarif@v3
  with:
    sarif_file: trivy-results.sarif
    # Findings appear in GitHub → Security → Code scanning alerts
```

`exit-code: "0"` means Trivy findings don't fail the build yet — they appear in the
GitHub Security tab as advisories. Set to `"1"` once a clean baseline is established.

---

## Makefile targets

### `make argocd-install`

```makefile
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
# --dry-run=client -o yaml + apply is idempotent: works even if namespace exists
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.13.0/manifests/install.yaml
kubectl wait --for=condition=available --timeout=120s deployment/argocd-server -n argocd
```

### `make argocd-bootstrap`

```makefile
kubectl apply -f gitops/apps/bootstrap.yaml
```

### `make helm-lint`

```makefile
helm lint charts/noctua-service -f gitops/estate/atlas-gateway/values.yaml
helm lint charts/noctua-service -f gitops/estate/ledger-api/values.yaml
helm lint charts/noctua-service -f gitops/estate/inventory-svc/values.yaml
```

---

## Full cluster bootstrap sequence

```bash
# 1. Create local cluster
make cluster-up

# 2. Install Argo CD
make argocd-install

# 3. Bootstrap app-of-apps (Argo CD manages everything from here)
make argocd-bootstrap

# 4. Watch Argo CD sync all applications
kubectl get applications -n argocd -w

# 5. Access Argo CD UI
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Open: https://localhost:8080
# User: admin
# Password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```
