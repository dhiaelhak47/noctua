variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "francecentral"
}

variable "resource_group_name" {
  description = "Resource group that contains the AKS cluster."
  type        = string
  default     = "noctua-demo"
}

variable "cluster_name" {
  description = "AKS cluster name."
  type        = string
  default     = "noctua-aks"
}

variable "kubernetes_version" {
  description = "Kubernetes version for the AKS cluster."
  type        = string
  default     = "1.31"
}

variable "node_count" {
  description = "Number of nodes in the system node pool."
  type        = number
  default     = 1   # Free tier: 1 node only
}

variable "node_vm_size" {
  description = "VM SKU for the system node pool."
  type        = string
  default     = "Standard_D2s_v3"
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default = {
    project     = "noctua"
    environment = "demo"
    managed_by  = "terraform"
  }
}
