locals {
  traefik_service = "traefik.traefik.svc.cluster.local"
}

module "foundation" {
  source = "../../modules/foundation"

  # The Plane API dials its own public host for copy_object and OAuth avatars. *.localhost means
  # loopback to a browser, but inside a pod it must reach Traefik.
  coredns_rewrites = {
    "plane.dev.localhost"      = local.traefik_service
    "plane.prod-sim.localhost" = local.traefik_service
  }
}

module "argocd" {
  source = "../../modules/argocd"

  namespace            = module.foundation.namespaces["argocd"]
  values_file          = "${path.module}/../../../../helm/values/argocd.yaml"
  bootstrap_chart_path = "${path.module}/../../../../gitops/bootstrap/chart"
  git_repo_url         = var.git_repo_url
  git_target_revision  = var.git_target_revision

  # Quotas and LimitRanges must exist before Argo CD can place anything in a Plane namespace.
  depends_on = [module.foundation]
}
