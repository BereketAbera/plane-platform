# 0009. Two namespace-scoped Infisical operators

**Status:** Accepted, 2026-11-04. Two clean first boots showed both operators up with no restart, so the crash loop this expects was not seen.

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

- Two extra pods, each with a 64Mi request and a 128Mi limit (`helm/values/infisical-operator-*.yaml`). They count against each Plane namespace's quota, and `modules/foundation` includes them. At idle on 2026-11-04 they used 22 and 38 MiB by `kubectl top`, and peaked at 25 and 40 MiB ([infisical-memory-1.txt](../evidence/runs/infisical-memory-1.txt)).
- The prod-sim operator depends on CRDs from the dev release. Its manager is expected to crash-loop until they exist, then recover. Removing the dev release would remove the CRDs for both. On the first boot both operators started within a second of each other and the prod-sim one read Ready after 31s ([plane-prod-sim-firstboot-1.txt](../evidence/runs/plane-prod-sim-firstboot-1.txt)), so the crash loop this expects was not seen. That boot was not clean, so recovery from that crash loop has not been seen. The clean and cold installs were the next first boots of both operators. On the cold one their Applications synced at 11:50:59Z for prod-sim and 11:51:00Z for dev, and the wait's first line, 62 s later, names neither ([timeline](../evidence/runs/clean-install-20261105T105546Z/app-timeline.txt), [make up](../evidence/runs/clean-install-20261105T105546Z/make-up.txt)). The first smoke's `workloads-ready` reads every pod in the namespace, which holds its operator, and it read `pods that have restarted: 0` in both environments on both installs ([clean, dev](../evidence/runs/clean-install-20261105T075041Z/e2e-dev-first.txt), [clean, prod-sim](../evidence/runs/clean-install-20261105T075041Z/e2e-prod-sim-first.txt), [cold, dev](../evidence/runs/clean-install-20261105T105546Z/e2e-dev-first.txt), [cold, prod-sim](../evidence/runs/clean-install-20261105T105546Z/e2e-prod-sim-first.txt)). So the crash loop was not seen there either, and recovery from it still has not been.
- The metrics ClusterRoles remain. `iso-*-metrics-auth-role` grants token and access reviews, and is bound to the operator. `iso-*-metrics-reader` grants `/metrics` get, and is bound to nobody ([cluster-readings-2.txt](../evidence/runs/cluster-readings-2.txt)). The ServiceMonitor stays off, because scraping needs a binding for Prometheus that the contract does not name, so operator metrics are not collected.
- A login with `plane-dev`'s ServiceAccount token as the prod-sim identity gets 401, `K8s namespace not allowed`, in both directions, and each operator gets no on Secrets and token minting in the other namespace ([infisical-isolation-3.txt](../evidence/runs/infisical-isolation-3.txt), [infisical-rbac-1.txt](../evidence/runs/infisical-rbac-1.txt)). A scratch `InfisicalAuth` in `plane-dev` that reached for prod-sim's account and identity read `IsReady: False`, because the operator could not fetch `plane-prod-sim/plane-infisical-identity` ([infisical-rbac-1.txt](../evidence/runs/infisical-rbac-1.txt)). A custom resource holding the prod-sim id in a Secret of its own namespace has not been applied, and the 401 above is the login it would make.
- Each operator reaches the API server and Infisical under default-deny NetworkPolicy. On 2026-11-05 each logged 12 to 18 successful reconciles in 150s with no error lines ([routes-after-3.txt](../evidence/runs/routes-after-3.txt)), and the dev operator logged in again after 42 minutes ([infisical-token-renewal-1.txt](../evidence/runs/infisical-token-renewal-1.txt)).
- This hardens one path, not the cluster. Anyone with cluster-admin, or with Secret read in a namespace, still reads that environment's values directly from etcd-backed Secrets. Accounts outside the Plane namespaces can do that too: Traefik's and the Prometheus operator's chart roles list Secrets in every namespace ([cluster-readings-2.txt](../evidence/runs/cluster-readings-2.txt)). Both operators run in one cluster, on one node, so this is not equivalent to independent production clusters.
