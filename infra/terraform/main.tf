resource "azurerm_resource_group" "noctua" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_kubernetes_cluster" "noctua" {
  name                = var.cluster_name
  location            = azurerm_resource_group.noctua.location
  resource_group_name = azurerm_resource_group.noctua.name
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.kubernetes_version

  # Free tier: no SLA, no uptime guarantee, no cost for the control plane.
  # Destroy after each demo — never leave running to avoid compute charges.
  sku_tier = "Free"

  default_node_pool {
    name       = "system"
    node_count = var.node_count
    vm_size    = var.node_vm_size

    # Upgrade nodes automatically when a new Kubernetes patch is released.
    upgrade_settings {
      max_surge = "33%"
    }
  }

  # Use managed identity — no service principal rotation needed.
  identity {
    type = "SystemAssigned"
  }

  # Enable the OIDC issuer so workloads can use Azure Workload Identity.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # Azure Monitor managed Prometheus (optional — comment out to stay free tier)
  # monitor_metrics {}

  network_profile {
    network_plugin = "azure"
    network_policy = "azure"
    # Azure CNI Overlay keeps node CIDR separate from pod CIDR.
    network_plugin_mode = "overlay"
    pod_cidr            = "192.168.0.0/16"
  }

  tags = var.tags

  lifecycle {
    # Prevent accidental destroy during active demo sessions.
    # Remove this block before running terraform destroy.
    prevent_destroy = false
  }
}
