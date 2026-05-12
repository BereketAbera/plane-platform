# 0004. Commit rendered Plane manifests instead of an Argo CD Helm source

**Status:** Accepted, 2026-11-04. Runtime validation pending where marked.

## Context

The `plane-ce` 1.8.6 chart needs changes its values do not cover: hardening, sync waves, hook annotations, probes and image digests. So some post-render step is required. The question is where it runs: inside Argo CD at sync time, or ahead of time in a script, with the output committed.

Two problems make the sync-time path fragile.

**The chart is not deterministic.** Pod templates carry `timestamp: {{ now | quote }}`, for example `templates/workloads/migrator.job.yaml:17` and `api.deployment.yaml:43`. Each manifest regeneration produces a new value. On Deployments that means a rollout with no real change. On the migrator Job it is worse. The name is `{{ .Release.Name }}-api-migrate-{{ .Release.Revision }}`, and `helm template` always renders revision 1, so the name never changes while the pod template does. A Job's template is immutable, so applying it fails.

**Argo CD's Helm handling has an open regression.** [Issue #30215](https://github.com/argoproj/argo-cd/issues/30215) is open and labelled `bug,regression,component:source/helm`, with a last comment on 2026-10-28 and fix [PR #30530](https://github.com/argoproj/argo-cd/pull/30530) unmerged (research, 2026-11-04). The research recorded it against the Kustomize-with-`--enable-helm` path: since v3.5.4, repo-server writes a `helm` wrapper script to `/tmp`, and reporters see `helm version --short ... signal: killed`. The cause is unknown. It fails at manifest regeneration, and the Redis cache masks it until then, so a green first sync would prove little. This platform pins Argo CD v3.5.7.

## Decision

Plane manifests are rendered ahead of time and committed.

- `helm/plane/vendor/plane-ce-1.8.6` holds the chart, byte-identical to upstream.
- `helm/plane/components/hardening` and `helm/plane/overlays/{dev,prod-sim}` hold everything local, as a Kustomize overlay.
- `make render` runs `scripts/render.sh`, which runs `kustomize build --enable-helm` and writes `gitops/environments/{dev,prod-sim}/manifests.yaml`.
- Argo CD syncs those plain files with no Helm or Kustomize at sync time.
- `scripts/render.sh --check` runs in CI through `scripts/ci/validate-manifests.sh` and fails if a render differs from what is committed.

The overlay removes the `timestamp` annotation. Kustomize does not fail when a patch target matches nothing, so `render.sh` also asserts the rules that matter: no `kind: Secret`, every image pinned by `@sha256:`, and no surviving `timestamp`.

Platform charts (Traefik, monitoring, Infisical) stay as Argo CD Helm sources, with exact versions and values from `helm/values/`. They need no post-render patching, so this decision does not apply to them.

## Alternatives considered

| Alternative | Why not |
|---|---|
| Argo CD Helm source with values only | Values cannot express the patches. `now` and the immutable Job remain |
| Argo CD Kustomize source with `kustomize.buildOptions: --enable-helm` (`plane-helm.md`) | Viable, and uses the same overlay. Exposed to #30215, needs a global flag in `argocd-cm`, and runs Argo's bundled Helm 4.2.1 and Kustomize 5.8.1 rather than the CLI versions in `tools.lock` |
| `ignoreDifferences` on `timestamp` with `RespectIgnoreDifferences` (`infisical.md`) | Hides the diff on Deployments. Does not fix the Job's immutable template and constant name (CRITIQUE.md C5) |
| Fork the chart and edit templates | Every upgrade becomes a merge. A byte-identical vendor directory plus patches keeps upstream's changes visible. A `remove` of a path the chart stops rendering fails the render, which is the alarm on a chart upgrade |

## Consequences

- Generated files live in Git. That is noise in history, and a reviewer can read exactly what will be applied. A promotion's diff is a digest change.
- Argo CD renders nothing for Plane, so #30215 cannot affect Plane syncs, and repo-server has less work to do.
- Anyone changing an overlay must run `make render` and commit the output. CI catches a forgotten render, and only after the fact.
- Renders must be deterministic, or `--check` fails on every run. [[VERIFY: running make render twice produces byte-identical output on the same tools.lock versions]]
- The render step depends on the Helm and Kustomize versions in `tools.lock`, not on Argo CD's. A tool bump can change output, and the diff shows it.
- Platform charts remain exposed to whatever Argo CD's native Helm path does. This record does not claim #30215 is limited to Kustomize. [[VERIFY: all platform Helm-source Applications regenerate without error on Argo CD v3.5.7 after the repo-server cache expires]]
- The non-determinism class of problem is not unique to Plane. `kube-prometheus-stack` needs `ignoreDifferences` for a Grafana password the chart redraws on each render (`monitoring/README.md`).
- Zero-Secret and digest rules are enforced in the render script and in `policy/`, not by Argo CD.
