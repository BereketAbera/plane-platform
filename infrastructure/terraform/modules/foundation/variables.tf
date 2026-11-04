variable "coredns_rewrites" {
  description = "Hostname to in-cluster name map for the CoreDNS rewrite. Empty leaves CoreDNS alone, for clusters whose Corefile is not the kubeadm default."
  type        = map(string)
  default     = {}
}
