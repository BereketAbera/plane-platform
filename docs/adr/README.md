# Architecture decision records

Each record states one decision, why it was made, what was rejected, and what it costs. The current facts (names, versions, ownership, ordering) live in the [platform contract](../platform-contract.md). These records explain them.

The application here is a customized deployment of open-source Plane Community Edition v1.4.3 (AGPL-3.0), named Wayline. It is not an original product. See [0013](0013-hybrid-branding.md) and [AGPL compliance](../agpl-compliance.md).

## How to read these

**"Accepted" means the choice is in force in the repository. It does not mean the choice has been proven at runtime.** A record is reasoning, not evidence. Results live in [`docs/evidence/`](../evidence/README.md) and are summarized in [validation](../validation.md), labelled PASS, FAIL, BLOCKED or NOT RUN (contract section 12).

| Marker | Meaning |
|---|---|
| `VERIFY` or `MEASURE`, in double square brackets | Only the clean rebuild below can answer it |
| "not yet recorded" | Depends on that same rebuild. Its result had not arrived when the sentence was written |
| "Not tested in Pass 1" | Nothing in Pass 1 ran this, and the record makes no claim either way |
| "estimate" | A planning number. The text says how it was derived |
| "research, 2026-11-04" | Read from an upstream source, registry or issue on that date, not re-checked since. Upstream status can change |
| A link into `evidence/runs/` | Raw output from a real run. `make publish-evidence` copies it from `.local/evidence-raw/` under the same name, with secrets scrubbed |

Where source code and research disagreed, the code wins, and the record says so.

A record may end with a dated section, **What we found when we ran it**. The decision text above it stays as it was written, so the reasoning at the time stays readable, and that section says what the first real runs on 2026-11-04 and 2026-11-05 changed. A marker that a run answered became a plain statement with its evidence. One that Pass 1 never tested became the words "Not tested in Pass 1".

**The clean rebuild.** `make drill-clean-restore CONFIRM=yes CLEAN_INSTALL_FIRST=yes` was running when these records were last edited on 2026-11-05. It deletes the cluster, installs from a fresh clone with new secrets, keeping the local registry and pull-through caches, tests that install and deletes it, then restores dev, prod-sim and Infisical from backup into a new cluster. Its results are not yet recorded, and no record here relies on them. Only it can answer the time of one `make up`, the disk growth of a first install, `Docker.raw` after a delete, and data across the rebuild. Two of those carry markers here: disk growth in [0003](0003-local-registry-and-pull-through-caches.md) and data across the rebuild in [0016](0016-datastore-versions.md).

## Index

| # | Decision | Depends on a runtime result? |
|---|---|---|
| [0001](0001-ownership-boundaries.md) | One owner per resource across kind, Compose, Terraform, Argo CD, Helm and Infisical | Yes |
| [0002](0002-cluster-creation.md) | The kind CLI creates the cluster. Terraform does not | Yes |
| [0003](0003-local-registry-and-pull-through-caches.md) | Local registry and pull-through caches instead of `kind load` | Yes |
| [0004](0004-rendered-plane-manifests.md) | Commit rendered Plane manifests instead of an Argo CD Helm source | Yes |
| [0005](0005-minio-compatible-silo.md) | MinIO-compatible store (Silo) after official MinIO images ended | Yes |
| [0006](0006-traefik-no-gateway-api.md) | Traefik rather than the archived ingress-nginx, and no Gateway API yet | Yes |
| [0007](0007-self-hosted-infisical-per-environment-projects.md) | Self-hosted Infisical with one project per environment on the free tier | Yes |
| [0008](0008-scripted-rotation-secret-key-never-rotated.md) | Scripted rotation, and `SECRET_KEY` is never rotated | Yes |
| [0009](0009-namespace-scoped-operators.md) | Two namespace-scoped Infisical operators | Yes |
| [0010](0010-networkpolicy-under-kindnet.md) | NetworkPolicy under kindnet, and its limits | Yes |
| [0011](0011-local-git-daemon-as-argo-source.md) | Local git daemon as Argo CD's source in Pass 1, and GitHub is not read | Yes |
| [0012](0012-monitoring-without-backend-metrics.md) | Monitoring a backend with no `/metrics` endpoint | Yes |
| [0013](0013-hybrid-branding.md) | Hybrid branding: overlay, patches and codemod | Yes |
| [0014](0014-migrator-sync-hook.md) | The migrator is an Argo CD `Sync` hook, not `PreSync` | Yes |
| [0015](0015-exclusions.md) | Exclusions: Bitnami, cert-manager, CloudNativePG, Soft Serve | Partly |
| [0016](0016-datastore-versions.md) | Datastore versions: Postgres 15, Valkey 7.2, RabbitMQ 3.13 and not 4.3 | Yes |

Numbers are stable and are referenced from code: `infrastructure/kind/cluster.yaml.tmpl` points at 0002. Do not renumber. To change a decision, add a new record that supersedes the old one, and update the old record's status line.

## Format

`NNNN-title.md`, with a status line and four sections: Context, Decision, Alternatives considered, Consequences. A fifth, What we found when we ran it, follows where a run changed the reasoning.

## Scope

All of these cover Pass 1, a local platform on one kind node. Nothing cloud is provisioned or configured. Where a record mentions Pass 2 (Hetzner Cloud, independent dev and prod environments, Cloudflare) it states intent only. See [future Hetzner](../future-hetzner.md) and the [Pass 2 handoff](../../PASS2_HANDOFF.md).
