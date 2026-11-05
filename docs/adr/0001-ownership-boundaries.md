# 0001. One owner per resource

**Status:** Accepted, 2026-11-04. Runtime validation pending where marked.

## Context

Several tools here can create the same Kubernetes object. Terraform can apply a manifest, Helm can install a chart, and Argo CD can create a namespace. If two tools write one object they overwrite each other, and the winner depends on timing. On a platform meant to be rebuilt from nothing, that shows up as a bootstrap that only sometimes works.

There are also real ordering cycles. Argo CD cannot deploy itself before it exists. Infisical cannot hold the secrets it needs in order to start. Terraform's Kubernetes providers cannot plan against a cluster that does not exist yet.

## Decision

Every resource has exactly one owner (contract section 4).

| Owner | Owns | Never touches |
|---|---|---|
| kind CLI, via `scripts/cluster-up.sh` | Cluster, node, CNI (kindnet), port and volume mounts | Anything inside namespaces |
| Docker Compose, via `infrastructure/local-services/` | Registry, pull-through caches, `git://` remote | Cluster resources |
| Terraform, via `infrastructure/terraform/environments/local` | Namespaces and labels, ResourceQuota, LimitRange, CoreDNS rewrite, Argo CD release, AppProjects, root Application | Anything Argo CD deploys |
| Terraform, via `infisical/terraform` (separate root and state) | Infisical projects, environments, machine identities, memberships, Kubernetes Auth config | Secret values |
| Argo CD | Everything else in the cluster | Namespaces, itself |
| Helm | Nothing. It renders charts | |
| Infisical | Secret values and their version history | Kubernetes objects. The operator materialises them |
| Scripts, via `.local/secret-zero/` | Secrets that must exist before Infisical does | See Consequences for one exception |

The reasons behind the less obvious lines:

- **Terraform installs Argo CD, and Argo CD does not manage itself.** A bad sync cannot take down the controller that would apply the fix, and `terraform apply` does not depend on the Git remote.
- **AppProjects come from Terraform, not Git.** An Application in Git must not be able to widen its own permissions.
- **Terraform creates namespaces, and `CreateNamespace=false` everywhere.** PSA labels, quotas and limit ranges must exist before the first workload lands.
- **AppProjects also enforce the boundary.** `platform` blacklists Namespace, ResourceQuota and LimitRange. The Plane projects additionally blacklist NetworkPolicy and allow no cluster-scoped resources, so a chart that renders one of these fails at sync instead of creating a second owner. On 2026-11-04 project `plane-dev` refused a NetworkPolicy at sync, on the real controller, for the whole of a 30-minute retry loop ([h16-throwaway-1.txt](../evidence/runs/h16-throwaway-1.txt)).
- **Helm has no owner role.** Nothing is `helm install`ed by hand. Terraform's `helm_release` installs two releases (Argo CD and `argocd-bootstrap`), and Argo CD renders platform charts itself.

`scripts/ci/ownership.sh` fails CI if Terraform and Argo CD both claim one object, if either holds a kind reserved for the other, or if two Argo CD sources declare one object.

## Alternatives considered

| Alternative | Why not |
|---|---|
| Terraform owns everything through `helm_release` and `kubernetes_manifest` | No continuous reconciliation or self-heal. `kubernetes_manifest` needs CRDs at plan time, which fails on an empty cluster. Plan size grows with every workload |
| Argo CD owns everything, including namespaces and itself | A self-managed controller can break its own recovery path. Namespace labels and quotas would race the workloads placed in them |
| Hand-run `helm install` or helmfile | No record of desired state in the cluster, and no drift correction |
| One Terraform root that also creates the cluster | See [0002](0002-cluster-creation.md) |

## Consequences

- **Terraform does not provision the kind cluster, the CNI, the local registry, the caches or the Git remote.** The kind CLI and Docker Compose create those. No document here may say otherwise.
- Argo CD upgrades are a Terraform change, not a GitOps sync. This is a real gap in the GitOps story, accepted for the recovery property above.
- The chart with AppProjects and the root Application is a second release because of how Helm maps objects to APIs. See `infrastructure/terraform/README.md`. It costs one small chart at `gitops/bootstrap/chart`.
- Terraform runs twice in a bootstrap: the foundation root first, and `infisical/terraform` once Argo CD has brought the Infisical server up. That second run needs an admin token, so it is driven by `scripts/infisical-bootstrap.sh`, not Argo CD.
- **One exception to the table.** `scripts/infisical-bootstrap.sh` applies the Secret `plane-infisical-identity` to each Plane namespace after Infisical is live. The identity ids change on every re-bootstrap, so they cannot be rendered into Git, and the CRD accepts only a Secret reference. The ids are not credentials on their own: login also needs a ServiceAccount token.
- `terraform destroy` deletes the namespaces, with every PVC and all Plane data, and removes the CoreDNS `Corefile` key. Normal teardown is `make destroy`, which deletes the cluster and the foundation root's state together.
- `scripts/ci/ownership.sh` is static. A name Terraform computes at plan time is covered only by the per-kind rules.
- **This boundary separates tools, not environments.** `plane-dev` and `plane-prod-sim` share one node, one API server, one etcd, one CNI, one Argo CD, one Traefik, one Infisical server and one monitoring stack. Namespace separation is not equivalent to independent production clusters.
- [[VERIFY: make up on a clean host creates every resource through its listed owner with no two-writer conflict]]

## What we found when we ran it

Added 2026-11-05. The bring-up on 2026-11-04 was staged, on a host that had run earlier builds, so it is not the clean host the marker above asks for. It showed no two-writer conflict: re-running each stage changed nothing Terraform owns, and `scripts/ci/ownership.sh` passes ([h17-ownership-1.txt](../evidence/runs/h17-ownership-1.txt)).

One gap in the reasoning. "An Application in Git must not be able to widen its own permissions" held for what a project allows, but an Application could still name a wider project. `policy/gitops.rego` has refused that since `b19fe26`, and a planted defect showed it fails ([negative controls](../evidence/ci/ci-3-20261104T223937Z-negative-controls-local.log)). That is a check in CI, and on this GitHub plan a failing check cannot block a merge.
