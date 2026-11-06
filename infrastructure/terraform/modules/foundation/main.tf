locals {
  plane_namespaces = { for name, ns in var.namespaces : name => ns if ns.environment != null }

  # Contract section 10, MiB per pod. Rendered manifests in gitops/environments carry the same numbers.
  plane_deployments = {
    web    = { request = 16, limit = 64 }
    admin  = { request = 16, limit = 64 }
    space  = { request = 96, limit = 256 }
    live   = { request = 128, limit = 384 }
    api    = { request = 256, limit = 768 }
    worker = { request = 256, limit = 768 }
    beat   = { request = 128, limit = 256 }
  }
  plane_statefulsets = {
    postgres = { request = 128, limit = 512 }
    valkey   = { request = 16, limit = 96 }
    rabbitmq = { request = 128, limit = 512 }
    silo     = { request = 256, limit = 512 }
  }
  # Pods the contract budget does not list but that do run in these namespaces.
  plane_extras = {
    infisical-operator = { request = 64, limit = 128 }  # helm/values/infisical-operator-*.yaml, one per namespace
    postgres-exporter  = { request = 16, limit = 48 }   # monitoring/manifests/environments/base/exporters.yaml
    redis-exporter     = { request = 12, limit = 32 }   # same file
    migrator           = { request = 128, limit = 512 } # helm/plane overlays, Argo Sync hook
    backup-job         = { request = 128, limit = 256 } # ESTIMATE until the backup Job has run
    ad-hoc-pod         = { request = 64, limit = 256 }  # LimitRange defaults: smoke tests and drills
  }

  # Deployments count twice: a RollingUpdate surges one extra pod each, and a quota that only
  # fits the steady state makes a rollout fail with "exceeded quota" while the old pods keep
  # serving, which looks like a stuck deploy rather than a budget problem.
  quota_request_mib = (
    2 * sum([for w in values(local.plane_deployments) : w.request]) +
    sum([for w in values(local.plane_statefulsets) : w.request]) +
    sum([for w in values(local.plane_extras) : w.request])
  )
  quota_limit_mib = (
    2 * sum([for w in values(local.plane_deployments) : w.limit]) +
    sum([for w in values(local.plane_statefulsets) : w.limit]) +
    sum([for w in values(local.plane_extras) : w.limit])
  )
  quota_pods = 2 * length(local.plane_deployments) + length(local.plane_statefulsets) + length(local.plane_extras)

  # A cluster with no quotas of its own gets the computed budget on each Plane namespace.
  quotas = var.quotas != null ? var.quotas : tomap({
    for name in keys(local.plane_namespaces) : name => tomap({
      "requests.memory" = "${local.quota_request_mib}Mi"
      "limits.memory"   = "${local.quota_limit_mib}Mi"
      pods              = tostring(local.quota_pods)
      # The chart's StatefulSets, the backup PVC (contract section 13), one spare for restore drills.
      persistentvolumeclaims = tostring(length(local.plane_statefulsets) + 2)
    })
  })

  limit_ranges = var.limit_ranges != null ? var.limit_ranges : tomap({
    for name in keys(local.plane_namespaces) : name => {
      default         = tomap({ memory = "256Mi" })
      default_request = tomap({ memory = "64Mi" })
      # The largest budgeted container is 768Mi. Anything above 1Gi needs a contract change first.
      max = tomap({ memory = "1Gi" })
    }
  })
}

resource "kubernetes_namespace_v1" "this" {
  for_each = var.namespaces

  metadata {
    name = each.key
    labels = merge(
      {
        "pod-security.kubernetes.io/enforce" = each.value.enforce
        "pod-security.kubernetes.io/warn"    = "restricted"
        "pod-security.kubernetes.io/audit"   = "restricted"
        "plane-platform/managed-by"          = "terraform"
      },
      each.value.environment == null ? {} : { "plane-platform/environment" = each.value.environment },
    )
  }
}

# The computed budget is memory and object counts only. The contract budgets no CPU, and a CPU quota
# would reject any pod that omits a CPU request. A cluster that passes its own quotas names its own
# resources, and its limit_ranges must give a CPU request to any pod that lacks one.
resource "kubernetes_resource_quota_v1" "plane" {
  for_each = local.quotas

  metadata {
    name      = var.quotas != null ? "budget" : "plane-budget"
    namespace = kubernetes_namespace_v1.this[each.key].metadata[0].name
  }

  spec {
    hard = each.value
  }
}

# A quota on limits.memory rejects a pod with no limit. These defaults make such a pod admissible
# and visibly small, instead of failing a sync with a quota error.
resource "kubernetes_limit_range_v1" "plane" {
  for_each = local.limit_ranges

  metadata {
    name      = var.limit_ranges != null ? "defaults" : "plane-defaults"
    namespace = kubernetes_namespace_v1.this[each.key].metadata[0].name
  }

  spec {
    limit {
      type            = "Container"
      default         = each.value.default
      default_request = each.value.default_request
      max             = each.value.max
    }
  }
}

resource "kubernetes_storage_class_v1" "this" {
  for_each = var.storage_classes

  metadata {
    name = each.key
  }

  storage_provisioner = each.value.provisioner
  reclaim_policy      = each.value.reclaim_policy
  volume_binding_mode = each.value.volume_binding_mode
}

# kubeadm created this ConfigMap and is recorded as its field manager, so server-side apply
# conflicts without force. kind never re-runs the kubeadm addon phase, so nothing takes it back.
# The Corefile's `reload` plugin picks the change up without a pod restart.
#
# TRAP: the provider's delete applies an empty data map, which removes the whole Corefile key.
# After `terraform destroy` CoreDNS cannot mount its config on the next restart. Delete the kind
# cluster after a destroy; do not keep using it.
resource "kubernetes_config_map_v1_data" "coredns" {
  count = length(var.coredns_rewrites) > 0 ? 1 : 0

  metadata {
    name      = "coredns"
    namespace = "kube-system"
  }

  data = {
    Corefile = templatefile("${path.module}/corefile.tftpl", { rewrites = var.coredns_rewrites })
  }

  force         = true
  field_manager = "terraform-plane-platform"
}

# K3s's Corefile imports this ConfigMap's *.override keys, and K3s redeploys its own coredns ConfigMap, so the kubeadm template
# above would not stay. K3s neither creates nor manages this one, so a plain resource owns it, and destroying it only removes
# the rewrites. The volume is optional in K3s's Deployment, and the reload plugin should pick the keys up without a restart.
resource "kubernetes_config_map_v1" "k3s_coredns_custom" {
  count = length(var.k3s_coredns_rewrites) > 0 ? 1 : 0

  metadata {
    name      = "coredns-custom"
    namespace = "kube-system"
  }

  data = {
    "rewrites.override" = join("", [for host, target in var.k3s_coredns_rewrites : "rewrite name exact ${host} ${target}\n"])
  }
}
