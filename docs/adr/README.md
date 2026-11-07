# Architecture decision records

Each record states one decision, why it was made, what was rejected, and what it costs. The current facts (names, versions, ownership, ordering) live in the [platform contract](../platform-contract.md). These records explain them.

The application here is a customized deployment of open-source Plane Community Edition v1.4.3 (AGPL-3.0), named Wayline. It is not an original product. See [0013](0013-hybrid-branding.md) and [AGPL compliance](../agpl-compliance.md).

## How to read these

**"Accepted" means the choice is in force in the repository. It does not mean the choice has been proven at runtime.** A record is reasoning, not evidence. Results live in [`docs/evidence/`](../evidence/README.md) and are summarized in [validation](../validation.md), labelled PASS, FAIL, BLOCKED or NOT RUN (contract section 12).

| Marker | Meaning |
|---|---|
| "Not tested in Pass 1" | Nothing in Pass 1 ran this, and the record makes no claim either way |
| "Not measured in Pass 1" | No run read this figure, and the record makes no claim about it |
| "estimate" | A planning number. The text says how it was derived |
| "research, 2026-11-04" | Read from an upstream source, registry or issue on that date, not re-checked since. Upstream status can change |
| `infisical.md`, `plane-helm.md`, `infra-versions.md`, `cicd-security.md`, `plane-branding.md`, `CRITIQUE.md` | The build's research notes. They are not in this repository, so treat what they are cited for as a reading, not a source you can check here. `infisical.md` is not [`docs/infisical.md`](../infisical.md) |
| A link into `evidence/runs/` | Output from a real run, raw or a transcript put together by whoever ran the test. [The evidence README](../evidence/README.md#layout) says how to tell them apart. `make publish-evidence` copies it from `.local/evidence-raw/` under the same name, with secrets scrubbed |

Where source code and research disagreed, the code wins, and the record says so.

A record may end with a dated section, **What we found when we ran it**. The decision text above it stays as it was written, so the reasoning at the time stays readable, and that section says what the first real runs on 2026-11-04 and 2026-11-05 changed, or, for hosted production, those on 2026-11-07. A marker that a run answered became a plain statement with its evidence. One that Pass 1 never tested became the words "Not tested in Pass 1" or "Not measured in Pass 1".

**The clean rebuild.** `make drill-clean-restore CONFIRM=yes CLEAN_INSTALL_FIRST=yes` deletes the cluster, installs from a fresh clone with new secrets, keeping the local registry and pull-through caches, tests that install and deletes it, then restores dev, prod-sim and Infisical from backup into a new cluster. `COLD_INSTALL=yes` with it removes the registry and caches first, so the install builds from source and pulls through empty caches. Both forms ran on 2026-11-05, and their output is published ([first log](../evidence/runs/drill-clean-restore-20261105T074859Z.log), [second log](../evidence/runs/drill-clean-restore-20261105T105347Z.log)). Each restore read PASS on every step. Each log's last line reads `RESULT FAIL`, and its one failure is the test's own: the step `destroy-refused` inherited `CONFIRM=yes`, so `make destroy` obeyed. `af8b26e` cleared the variable, make still passed it down, and `1374c1e` clears that too, which has not run in a drill, and whose line was [checked against a stub](../evidence/runs/destroy-refused-line-check.txt). TEAR-1 has a [clean run](../evidence/runs/TEAR-1-20261105T083304Z.txt) of its own, which refused. The cold install also found a real defect, [images their own user could not read](../known-limitations.md#what-real-runs-found), so its `make up` of 5238 s is not a good install's time, and a full cold install with no defect has not been timed. No record here has a `VERIFY` or `MEASURE` marker left. `LOSE_CLUSTER=yes` then deleted with kind alone, with no install in the gap, every restore step PASS, and its last line reads `RESULT PASS` ([log](../evidence/runs/drill-clean-restore-20261105T130633Z.log)). `Docker.raw` around a delete is at the top and bottom of [that drill's output](../evidence/runs/BKP-6-20261105T130633Z-lose-cluster-make.txt), which brackets the whole drill, and [TEAR-5b](../validation.md#10-clean-teardown-and-recreation) is the row for it.

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
| [0015](0015-exclusions.md) | Exclusions: Bitnami, cert-manager, CloudNativePG, Soft Serve. Superseded in part by 0018: cert-manager, for hosted production | Partly |
| [0016](0016-datastore-versions.md) | Datastore versions: Postgres 15, Valkey 7.2, RabbitMQ 3.13 and not 4.3 | Yes |
| [0017](0017-infisical-public-route.md) | A public route for hosted production's Infisical, for its one admin | Yes |
| [0018](0018-hosted-tls-cert-manager.md) | TLS on hosted production: cert-manager and Let's Encrypt HTTP-01, terminated by Traefik on the node | Yes |

Numbers are stable and are referenced from code: `infrastructure/kind/cluster.yaml.tmpl` points at 0002. Do not renumber. To change a decision, add a new record that supersedes the old one, and update the old record's status line.

## Format

`NNNN-title.md`, with a status line and four sections: Context, Decision, Alternatives considered, Consequences. A fifth, What we found when we ran it, follows where a run changed the reasoning.

## Scope

Records 0001 to 0016 were written for Pass 1: the local platform, with `dev` and `prod-sim` as two namespaces of one kind cluster on the Mac. They still describe it. Records 0017 and 0018 are about hosted production, `plane-prod`, which has run since 2026-11-07 on one K3s node on a Contabo VPS, with its DNS records at Vercel through Terraform, and TLS terminated by Traefik on the node with cert-manager and Let's Encrypt. Where a Pass 1 record mentions Pass 2 as Hetzner Cloud, independent dev and prod clusters, or Cloudflare, it describes a plan that did not happen. [Future Hetzner](../future-hetzner.md) and the [Pass 2 handoff](../../PASS2_HANDOFF.md) are the record of that plan. Hosted production's own facts are in [`scripts/hosted/README.md`](../../scripts/hosted/README.md) and under [`gitops/clusters/plane-prod`](../../gitops/clusters/plane-prod/), and its runbooks are in [runbooks](../runbooks/README.md).
