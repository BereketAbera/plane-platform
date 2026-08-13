variable "coredns_rewrites" {
  description = "Hostname to in-cluster name map for the CoreDNS rewrite. Empty leaves CoreDNS alone, for clusters whose Corefile is not the kubeadm default."
  type        = map(string)
  default     = {}
}

variable "k3s_coredns_rewrites" {
  description = "Hostname to in-cluster name map for K3s, whose Corefile imports *.override from ConfigMap coredns-custom. Empty creates nothing."
  type        = map(string)
  default     = {}
}

# Contract section 2. Argo CD runs with CreateNamespace=false, so this is the only creator.
variable "namespaces" {
  description = "Namespace name to its PSA enforce level and, for a Plane environment, the environment label. The default is the local cluster."
  type = map(object({
    enforce     = string
    environment = optional(string)
  }))
  default = {
    argocd     = { enforce = "baseline" }
    traefik    = { enforce = "baseline" }
    monitoring = { enforce = "baseline" }
    # node-exporter only: hostNetwork and hostPID cannot pass baseline.
    monitoring-agents = { enforce = "privileged" }
    infisical         = { enforce = "baseline" }
    plane-dev         = { enforce = "baseline", environment = "dev" }
    # Tighten only after a per-workload non-root test passes (contract section 2).
    plane-prod-sim = { enforce = "baseline", environment = "prod-sim" }
  }
}

variable "quotas" {
  description = "Namespace to ResourceQuota hard limits, each ResourceQuota named budget. Null gives each Plane namespace the budget computed in main.tf, named plane-budget."
  type        = map(map(string))
  default     = null
}

variable "limit_ranges" {
  description = "Namespace to its Container LimitRange, each named defaults. Null gives each Plane namespace the one in main.tf, named plane-defaults."
  type = map(object({
    default         = map(string)
    default_request = map(string)
    max             = map(string)
  }))
  default = null
}

variable "storage_classes" {
  description = "StorageClass name to its provisioner, reclaim policy and binding mode. Empty creates none, as on kind, whose default class is used."
  type = map(object({
    provisioner         = string
    reclaim_policy      = string
    volume_binding_mode = string
  }))
  default = {}
}
