# Not variables: nothing should be able to aim this root at another cluster. The kubeconfig holds one context, whose server is the SSH
# tunnel from scripts/hosted/tunnel.sh, and it is never merged into ~/.kube/config.
locals {
  kubeconfig_path = abspath("${path.module}/../../../../.local/hosted/plane-prod/kubeconfig")
  kube_context    = "plane-prod"
}

provider "kubernetes" {
  config_path    = local.kubeconfig_path
  config_context = local.kube_context
}

provider "helm" {
  kubernetes = {
    config_path    = local.kubeconfig_path
    config_context = local.kube_context
  }
}
