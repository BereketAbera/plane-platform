# Bootstrap

What Terraform applies so that Argo CD has something to reconcile. Nothing else writes these objects.

| Path | Contents | Applied by |
|---|---|---|
| `chart/` | AppProjects `platform`, `plane-dev`, `plane-prod-sim`, and the `root` Application | `helm_release.bootstrap` in `infrastructure/terraform/modules/argocd` |
| `argocd-route/` | IngressRoute for `argocd.localhost`, wave -8 | The `root` Application, from Git |

`chart/` is a local Helm chart, installed as a separate release, because `kubernetes_manifest` needs the CRDs at plan
time and the Argo CD chart's `extraObjects` cannot share a release with CRDs it installs. The full reasoning is in
[`infrastructure/terraform/README.md`](../../infrastructure/terraform/README.md).

Every template stays valid YAML, with no `range` or `if`, so linters that read `gitops/**` can parse it.

`root` has two sources. Its status therefore carries `status.sync.revisions`, and `status.sync.revision` is empty.
