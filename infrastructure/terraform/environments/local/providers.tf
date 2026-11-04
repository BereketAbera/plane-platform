locals {
  kubeconfig_path = coalesce(var.kubeconfig_path, abspath("${path.module}/../../../../.local/kubeconfig"))
}

provider "kubernetes" {
  config_path    = local.kubeconfig_path
  config_context = var.kube_context
}

provider "helm" {
  kubernetes = {
    config_path    = local.kubeconfig_path
    config_context = var.kube_context
  }
}
