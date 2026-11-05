# Phase 2 — RBAC, Terraform AKS & OIDC

## What Phase 2 builds

- A least-privilege Kubernetes ServiceAccount for the noctua collector
- Terraform for the AKS Free tier cluster (create + destroy on demand)
- GitHub Actions OIDC — no long-lived Azure secrets stored anywhere
- An Argo CD Application to manage the RBAC resources from Git

---

## RBAC — `noctua/rbac/`

### Why a dedicated ServiceAccount?

The noctua collector (`investigate.sh`) calls `kubectl` to gather evidence.
In production it runs as a Kubernetes Job in its own namespace (`noctua`).
That Job needs read-only access to pods, events, and logs across namespaces —
but **nothing else**. A purpose-built ServiceAccount with a tightly scoped
ClusterRole enforces this at the API server level.

Security principle: **AI never holds cluster credentials**.
The SA token is only mounted into the Job pod. The LLM analyst receives a sealed
JSON bundle — it never calls the Kubernetes API directly.

### `namespace.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: noctua
```

Isolates noctua's own workloads from the `estate` namespace (demo services).
Managed by Argo CD via the `noctua-rbac` Application.

### `serviceaccount.yaml`

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: noctua
  namespace: noctua
automountServiceAccountToken: false
```

`automountServiceAccountToken: false` — the token is NOT automatically mounted into
every pod. It is only injected by explicit `serviceAccountName:` in a Job spec.
This prevents any other pod from accidentally inheriting the token.

### `clusterrole.yaml`

```yaml
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
  # pod_status.sh: kubectl get pod -o json

  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get"]
  # logs.sh: kubectl logs --previous
  # pods/log is a subresource — listed separately from pods

  - apiGroups: [""]
    resources: ["events"]
    verbs: ["get", "list", "watch"]
  # events.sh: kubectl get events --field-selector involvedObject.name=...

  - apiGroups: ["apps"]
    resources: ["replicasets", "deployments"]
    verbs: ["get", "list", "watch"]
  # rollout.sh: walks ownerRef chain to find revision history
```

What is explicitly **NOT** granted:
- `secrets` — never; credentials must not be accessible to the analyst
- `configmaps` — not needed for collector logic
- `serviceaccounts` — not needed
- `nodes`, `persistentvolumes` — out of scope for pod-level investigation
- Anything in `networking.k8s.io`, `rbac.authorization.k8s.io`, `policy` — never

### `clusterrolebinding.yaml`

Binds the `noctua-collector` ClusterRole to the `noctua` ServiceAccount
in namespace `noctua`. ClusterRoleBinding is cluster-scoped, so the SA
can read pods/events/logs from **any namespace** — the noctua namespace restriction
is only about WHERE the SA lives, not what it can read.

### `gitops/apps/noctua-rbac.yaml`

An Argo CD Application that watches `noctua/rbac/` in Git and applies changes
automatically. After `make argocd-bootstrap`, this Application is created by
the bootstrap app-of-apps.

---

## Terraform — `infra/terraform/`

### File structure

| File | Purpose |
|---|---|
| `providers.tf` | Terraform version + provider declarations; OIDC config |
| `variables.tf` | Input variables with defaults |
| `main.tf` | Resource definitions (RG + AKS cluster) |
| `outputs.tf` | Useful values after apply |
| `.gitignore` | Never commit state files or tfvars |

### `providers.tf`

```hcl
terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.14" }
    azuread = { source = "hashicorp/azuread", version = "~> 3.0" }
  }
}

provider "azurerm" {
  features {}
  use_oidc = true   # tells the provider to use OIDC token exchange
                    # instead of a client_secret
}
```

`use_oidc = true` works because GitHub Actions provides the OIDC JWT via the
`id-token: write` permission. The Azure provider exchanges this JWT for a short-lived
access token using Azure AD's federated credential mechanism.

### `main.tf` — Key decisions

**Free tier:**
```hcl
sku_tier = "Free"
```
No SLA. Control plane is free. Compute (1 node) costs ~€50-70/month on `Standard_D2s_v3`.
**Always destroy after demos**: `terraform destroy` or `az aks delete ...`.

**SystemAssigned managed identity:**
```hcl
identity {
  type = "SystemAssigned"
}
```
No service principal to rotate. Azure manages the identity lifecycle with the cluster.

**OIDC issuer for Workload Identity:**
```hcl
oidc_issuer_enabled       = true
workload_identity_enabled = true
```
Enables pods in AKS to authenticate to Azure services (Key Vault, ACR, etc.) using
federated credentials — same no-secret principle as GitHub Actions OIDC.

**Azure CNI Overlay networking:**
```hcl
network_plugin      = "azure"
network_plugin_mode = "overlay"
pod_cidr            = "192.168.0.0/16"
```
Overlay mode: pods get IPs from a private CIDR that doesn't consume Azure subnet space.
Required for Kyverno webhook (needs stable pod-to-pod networking).

**Network policy:**
```hcl
network_policy = "azure"
```
Enforces NetworkPolicy resources at the VNet level (Azure NPM). Works with the
`networkpolicy.yaml` templates in the Helm chart.

### `variables.tf` — Configurable values

```
location           = "francecentral"   # Azure region close to you
cluster_name       = "noctua-aks"
kubernetes_version = "1.31"
node_count         = 1                 # Free tier: 1 node max is practical
node_vm_size       = "Standard_D2s_v3"  # 2 vCPU, 8 GB RAM
```

### `outputs.tf`

After `terraform apply`, useful values are printed:

```
kube_config_command = "az aks get-credentials --resource-group noctua-demo --name noctua-aks"
oidc_issuer_url     = "https://oidc.prod-aks.azure.com/..."  # for Workload Identity setup
```

---

## GitHub Actions OIDC — `.github/workflows/terraform.yml`

### What OIDC means here

Traditional approach (bad): store an Azure client secret as a GitHub secret.
Secrets can leak, need rotation, and persist forever.

OIDC approach: GitHub generates a **short-lived JWT** for each workflow run.
The JWT is exchanged for an Azure access token that expires in 1 hour.
No secret is ever stored.

### Setup (one-time, done in Azure portal)

1. Create an App Registration in Azure AD (or use an existing one).
2. Add a Federated Credential on the App Registration:
   - **Issuer:** `https://token.actions.githubusercontent.com`
   - **Subject:** `repo:dhiaelhak47/noctua:ref:refs/heads/main`
   - **Audience:** `api://AzureADTokenExchange`
3. Assign the App Registration's Service Principal a role on your subscription
   (e.g. `Contributor` for AKS create/delete).
4. Add three GitHub Secrets (not variables — these are IDs, not secrets, but GitHub
   recommends storing them as secrets for access control):
   - `AZURE_CLIENT_ID` — App Registration's Application (client) ID
   - `AZURE_TENANT_ID` — Your Azure AD tenant ID
   - `AZURE_SUBSCRIPTION_ID` — Your Azure subscription ID

### The workflow

```yaml
permissions:
  id-token: write   # GitHub must grant permission to generate OIDC token
  contents: read

env:
  ARM_CLIENT_ID:       ${{ secrets.AZURE_CLIENT_ID }}
  ARM_TENANT_ID:       ${{ secrets.AZURE_TENANT_ID }}
  ARM_SUBSCRIPTION_ID: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
  # No ARM_CLIENT_SECRET — OIDC only.
```

```yaml
- name: Azure login (OIDC)
  uses: azure/login@v2
  with:
    client-id:       ${{ secrets.AZURE_CLIENT_ID }}
    tenant-id:       ${{ secrets.AZURE_TENANT_ID }}
    subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
```

This action exchanges the GitHub OIDC JWT for an Azure access token.
Subsequent steps (`az`, `terraform`) inherit this authentication context.

### Triggering

```yaml
on:
  workflow_dispatch:          # manual trigger from GitHub Actions UI
    inputs:
      action:
        type: choice
        options: [plan, apply, destroy]
  push:
    paths: [infra/terraform/**]  # auto-plan on terraform changes
```

Manual trigger with `action: apply` creates the cluster.
Manual trigger with `action: destroy` tears it down.
Push to main auto-runs `plan` only (no auto-apply — requires human review).

---

## Workflow: create AKS cluster for a demo

```bash
# 1. Trigger from GitHub Actions UI: action=apply
#    OR locally with az CLI:
cd infra/terraform
terraform init
terraform apply

# 2. Configure kubectl
az aks get-credentials --resource-group noctua-demo --name noctua-aks --overwrite-existing

# 3. Bootstrap Argo CD (same as local kind setup)
make argocd-install
make argocd-bootstrap

# 4. Argo CD syncs everything from Git including noctua-rbac

# 5. After the demo — ALWAYS DESTROY to avoid charges
terraform destroy
# OR trigger from GitHub Actions UI: action=destroy
```

---

## Security summary

| Component | Secret stored | How auth works |
|---|---|---|
| GitHub → Azure | No client_secret | OIDC JWT → short-lived token |
| AKS cluster | SystemAssigned MSI | Azure-managed, no rotation needed |
| noctua SA | No token stored | Mounted only in collector Jobs |
| AI analyst | None | Receives sealed bundle, no cluster access |
| Argo CD | kubeconfig (in-cluster) | Service account inside cluster |
