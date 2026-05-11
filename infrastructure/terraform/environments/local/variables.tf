variable "kubeconfig_path" {
  description = "Kubeconfig to use. Null means the repo's .local/kubeconfig, written by scripts/cluster-up.sh."
  type        = string
  default     = null
}

variable "kube_context" {
  description = "Kube context to use."
  type        = string
  default     = "kind-plane-platform"
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
