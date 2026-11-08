locals {
  hosted   = "${path.module}/../../../hosted/plane-prod"
  target   = yamldecode(file("${local.hosted}/target.yaml"))
  capacity = yamldecode(file("${local.hosted}/capacity.yaml"))
}

data "kubernetes_namespace_v1" "kube_system" {
  metadata {
    name = "kube-system"
  }
}

# The kubeconfig's context is only a name, and a tunnel can point anywhere. This is the check that it is this cluster: everything below
# waits on it, and a plan fails here before it would touch anything.
resource "terraform_data" "right_cluster" {
  lifecycle {
    precondition {
      condition     = data.kubernetes_namespace_v1.kube_system.metadata[0].uid == local.target.kube_system_uid
      error_message = "The cluster behind this kubeconfig has kube-system UID ${data.kubernetes_namespace_v1.kube_system.metadata[0].uid}, and infrastructure/hosted/plane-prod/target.yaml says ${local.target.kube_system_uid}. If K3s was just installed on the right node, record its UID there. Otherwise this is the wrong cluster, so stop."
    }
  }
}

module "foundation" {
  source = "../../modules/foundation"

  namespaces = {
    argocd = { enforce = "baseline" }
    # Traefik's hostPorts cannot pass baseline, and they are the only way in.
    traefik    = { enforce = "privileged" }
    monitoring = { enforce = "baseline" }
    # node-exporter only: hostNetwork and hostPID cannot pass baseline.
    monitoring-agents = { enforce = "privileged" }
    infisical         = { enforce = "baseline" }
    cert-manager      = { enforce = "baseline" }
    # Baseline until a dry run of restricted passes on the branded images.
    plane-prod = { enforce = "baseline", environment = "prod" }
    # The static sites. nginx runs as user 101 with every capability dropped, and cert-manager's solver pod passes too, so they start
    # at the strictest level.
    rillmark           = { enforce = "restricted" }
    awushi-cloudgarden = { enforce = "restricted" }
    # Frameflow, its Hatchet, Postgres and Silo, its operator and its Jobs. Each runs as a user that is not root, with every capability
    # dropped and no privilege escalation, as cert-manager's solver does, so it keeps the strictest level, and anything added must pass it.
    frameflow  = { enforce = "restricted" }
    snakebrawl = { enforce = "restricted" }
  }

  quotas       = local.capacity.quotas
  limit_ranges = local.capacity.limit_ranges

  # Plane's volumes and the monitoring volumes. K3s's own local-path class deletes a volume with its claim.
  storage_classes = {
    local-path-retain = {
      provisioner         = "rancher.io/local-path"
      reclaim_policy      = "Retain"
      volume_binding_mode = "WaitForFirstConsumer"
    }
  }

  # The Plane API dials its own public host, and blackbox and cert-manager's self-check read it, the two consoles' and each app's too.
  # Inside a pod that must reach Traefik's Service, not go out through the host firewall and back, which cert-manager's egress refuses: an
  # app's Certificate never becomes Ready without its line here.
  k3s_coredns_rewrites = {
    (local.target.domain)             = "traefik.traefik.svc.cluster.local"
    (local.target.grafana_domain)     = "traefik.traefik.svc.cluster.local"
    (local.target.infisical_domain)   = "traefik.traefik.svc.cluster.local"
    (local.target.frameflow_domain)   = "traefik.traefik.svc.cluster.local"
    (local.target.rillmark_domain)    = "traefik.traefik.svc.cluster.local"
    (local.target.cloudgarden_domain) = "traefik.traefik.svc.cluster.local"
    "snakebrawl.io"                   = "traefik.traefik.svc.cluster.local"
    "www.snakebrawl.io"               = "traefik.traefik.svc.cluster.local"
    "ws.snakebrawl.io"                = "traefik.traefik.svc.cluster.local"
  }

  depends_on = [terraform_data.right_cluster]
}

module "argocd" {
  source = "../../modules/argocd"

  namespace            = module.foundation.namespaces["argocd"]
  values_file          = "${path.module}/../../../../gitops/clusters/plane-prod/values/argocd.yaml"
  bootstrap_chart_path = "${path.module}/../../../../gitops/clusters/plane-prod/bootstrap-chart"
  git_repo_url         = "ssh://git@ssh.github.com:443/BereketAbera/plane-platform.git"
  # CI commits here only what has passed the evidence gate, and it holds only the two hosted trees.
  git_target_revision = "deploy/plane-prod"

  # Quotas and LimitRanges must exist before Argo CD can place anything in a namespace.
  depends_on = [module.foundation]
}
