variable "namespace" {
  description = "Namespace for Argo CD. Must already exist; nothing here creates namespaces."
  type        = string
}

variable "values_file" {
  description = "Path to the argo-cd chart values file."
  type        = string
}

variable "bootstrap_chart_path" {
  description = "Path to the local chart holding the AppProjects and the root Application."
  type        = string
}

variable "git_repo_url" {
  description = "Git URL Argo CD reads. Pass 2 changes this one value to GitHub."
  type        = string
}

variable "git_target_revision" {
  description = "Git revision the root Application tracks."
  type        = string
}
