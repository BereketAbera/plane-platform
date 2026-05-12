# 0009. Two namespace-scoped Infisical operators

**Status:** Accepted, 2026-11-04. Runtime validation pending where marked.

## Context

One project per environment ([0007](0007-self-hosted-infisical-per-environment-projects.md)) is only useful if the component that fetches secrets cannot cross it.

In cluster mode, one Infisical operator (secrets-operator chart 0.11.16) has a ClusterRole over Secrets everywhere and can mint a token for any ServiceAccount. Nothing would stop an `InfisicalAuth` in `plane-dev` from referencing the prod-sim identity. That would undo the project boundary from inside the cluster.

## Decision

Two releases, one per Plane namespace: `infisical-operator-dev` and `infisical-operator-prod-sim`. Each sets `scopedNamespaces` to its own namespace and `scopedRBAC: true`. Both settings are required: without `scopedRBAC` the release still gets the ClusterRole.

Details the chart forces:

| Setting | Why |
|---|---|
| `fullnameOverride: iso-dev` and `iso-prod-sim` | The chart truncates its fullname to 15 characters, so both release names become `infisical-opera` and collide on cluster-scoped objects |
| `installCRDs: true` on the dev release only | Two Applications owning one CRD would fight over it |
| Both Applications in the `platform` AppProject | Scoped mode still renders three cluster-scoped objects per release: two metrics ClusterRoles and one ClusterRoleBinding. The Plane projects refuse cluster-scoped objects |
| `hostAPI` set to the in-cluster URL, and `InfisicalConnection.address` always set | The chart's default is Infisical Cloud. An empty address would send identity tokens there |
| `defaultResourcesHelmHooks: false` | The chart's comment says Argo CD users need this or syncs hang |
| No finalizer on the Applications | Cascading a delete removes the CRDs, and with them every Infisical custom resource in both namespaces |

## Alternatives considered

| Alternative | Why not |
|---|---|
| One cluster-wide operator | It can read every Secret and mint any token. It collapses the environment boundary |
| One operator scoped to both namespaces | Saves one pod. One ServiceAccount would still act in both namespaces, so a mistake or a compromise reaches both |
| No operator, scripts push Secrets into the cluster | No reconciliation, and a script holding credentials for both environments |

## Consequences

- Two extra pods, each with a 64Mi request and a 128Mi limit (`helm/values/infisical-operator-*.yaml`). They count against each Plane namespace's quota, and `modules/foundation` includes them. [[MEASURE: operator RSS at idle]]
- The prod-sim operator depends on CRDs from the dev release. Its manager is expected to crash-loop until they exist, then recover. Removing the dev release would remove the CRDs for both. [[VERIFY: the prod-sim operator recovers without intervention once the dev release has installed the CRDs]]
- The metrics ClusterRoles remain. They grant only token and access reviews. The ServiceMonitor stays off, because scraping needs a binding for Prometheus that the contract does not name, so operator metrics are not collected.
- [[VERIFY: an InfisicalAuth in plane-dev that references the prod-sim ServiceAccount or identity fails]]
- [[VERIFY: each operator can reach the API server and Infisical under default-deny NetworkPolicy]]
- This hardens one path, not the cluster. Anyone with cluster-admin, or with Secret read in a namespace, still reads that environment's values directly from etcd-backed Secrets. Both operators run in one cluster, on one node, so this is not equivalent to independent production clusters.
