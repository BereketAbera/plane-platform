locals {
  # The helm provider only notices a local chart's template edits when Chart.yaml's version moves.
  # Passing a content hash as a value makes any edit show up in the plan.
  bootstrap_chart_hash = sha256(join("", [
    for f in sort(fileset(var.bootstrap_chart_path, "**")) : filesha256("${var.bootstrap_chart_path}/${f}")
  ]))
}

# Chart index digest for 10.11.7, verified against the tarball:
# 9f24a574ead97a1a68af447ab2678073c5e16a98ff9385aee766daf74361f04e
resource "helm_release" "argocd" {
  name       = "argocd"
  namespace  = var.namespace
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "10.11.7"

  values = [file(var.values_file)]

  # First boot pulls the 202 MiB image through the pull-through cache, then runs the Redis secret hook.
  timeout       = 600
  wait          = true
  wait_for_jobs = true
  max_history   = 3
}

# A second release, not the chart's extraObjects: this chart ships its CRDs as ordinary templates,
# and Helm maps every object in a release to an API before creating any of them. On an empty
# cluster an AppProject in the same release fails with "no matches for kind". kubernetes_manifest
# fails even earlier, at plan time.
resource "helm_release" "bootstrap" {
  name      = "argocd-bootstrap"
  namespace = var.namespace
  chart     = var.bootstrap_chart_path

  values = [yamlencode({
    gitRepoURL     = var.git_repo_url
    targetRevision = var.git_target_revision
    chartHash      = local.bootstrap_chart_hash
  })]

  max_history = 3

  depends_on = [helm_release.argocd]
}
