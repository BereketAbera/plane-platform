# plane-ce 1.8.6, vendored

`plane-ce/` is the release tarball untarred with no edits. Change nothing inside it. Fixes go in
`helm/plane/components/hardening` so an upgrade stays a directory swap and a patch that no longer
applies fails the render.

| | |
|---|---|
| Chart | `plane-ce` 1.8.6, appVersion 1.4.3 |
| Index | `https://helm.plane.so/index.yaml` |
| Tarball | `https://github.com/makeplane/helm-charts/releases/download/plane-ce-1.8.6/plane-ce-1.8.6.tgz` |
| Tarball sha256 | `c70244eefa7dfa94e8636048fe4032640999c7d4e265b1fec68d13060cf70e4f` (matches `index.yaml` and the platform contract) |
| Tree hash | `10d7ce728dce7daa22cd111d041becccaa5d9e3add257b221c231a4f5734c48f` |
| Licence | AGPL-3.0, by the chart's `artifacthub.io/license` annotation only. The upstream repo has no LICENSE file |

Recompute the tree hash from this directory:

```sh
find plane-ce -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256
```

To re-verify against upstream, download the tarball, check its sha256, untar it elsewhere and run
`diff -r` against `plane-ce/`.
