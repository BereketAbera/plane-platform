variable "kubeconfig_path" {
  description = "Kubeconfig to use. Null means the repo's .local/kubeconfig, written by scripts/cluster-up.sh."
  type        = string
  default     = null
}

variable "kube_context" {
  description = "Kube context to use. Only the local cluster's: scripts/up.sh auto-approves this root, so TF_VAR_kube_context or a stray terraform.tfvars must not be able to aim it elsewhere."
  type        = string
  default     = "kind-plane-platform"

  validation {
    condition     = var.kube_context == "kind-plane-platform"
    error_message = "This root manages only the local kind cluster, whose context is kind-plane-platform. Unset TF_VAR_kube_context, or remove kube_context from terraform.tfvars."
  }
}

variable "git_repo_url" {
  description = "Git URL Argo CD reads."
  type        = string
  default     = "git://plane-git/plane-platform.git"
}

variable "git_target_revision" {
  description = "Git revision the root Application tracks."
  type        = string
  default     = "main"
}
