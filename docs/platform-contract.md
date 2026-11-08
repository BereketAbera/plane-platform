# Platform contract

The single source of truth for names, ownership, and ordering, in all three environments: `dev` and `prod-sim` on the local kind
cluster, and hosted production, `plane-prod`, on one K3s node on the owner's Contabo VPS. Every layer of the platform
conforms to this file. If code and this file disagree, one of them is a bug.

Decisions with a "why" live in [`docs/adr/`](adr/). This file only states what is true. Its local parts were last reconciled against the
code on 2026-11-05. Its hosted parts, each under a **Hosted production** heading, come from the binding hosted design and were checked on
2026-11-07 against the code on `main` and what the cluster ran. [Section 14](#14-changes-to-this-contract) lists both, and where hosted
production differs from its design. Whether something works is in [validation.md](validation.md), not here.

## 1. Fixed names

| Thing | Value |
|---|---|
| kind cluster | `plane-platform` (one node, `plane-platform-control-plane`) |
| kube context | `kind-plane-platform` |
| kubeconfig | `.local/kubeconfig` (scripts export `KUBECONFIG`; the user's `~/.kube/config` is never touched) |
| Kubernetes | v1.36.4 |
| Plane release | v1.4.3, source commit `37a15d99231042b3ff5a4401fed479fdbec9effe` |
| Plane chart | `plane-ce` 1.8.6, `https://helm.plane.so/`, tgz sha256 `c70244eefa7dfa94e8636048fe4032640999c7d4e265b1fec68d13060cf70e4f` |
| Helm release name | `plane` in both environments, so object names match and one patch set fits both |
| Distinct product name | **Wayline**, a customized Plane Community Edition deployment. Never present it as an original product |
| Host-only state | `.local/` (gitignored): `kubeconfig`, `kind-cluster.yaml`, `git/`, `backups/`, `secret-zero/`, `terraform/` (with `terraform/local.stale-<time>` once `make up` has moved a lost cluster's state aside), `rendered/`, `evidence-raw/`, `evidence-scrub-values`, `publishes.log`, `restore-clean.state`, `registry-snapshot.tar` while a cold install runs, `test-accounts.env`, `test-sentinel-<env>.json`, `kubeconform-schemas/`, `trivy-cache/`. Build output goes to `.build/`, also gitignored |

**Hosted production.** `infrastructure/hosted/plane-prod/target.yaml` holds these, and every hosted script and Terraform root reads them from it.

| Thing | Value |
|---|---|
| Cluster | K3s `v1.36.6+k3s1`, its default SQLite datastore, one node `vmi3733427` |
| VPS | Contabo Cloud VPS 12, instance `203733427`, IPv4 `5.253.234.127` on `eth0`, Ubuntu 24.04.5, x86_64. Its IPv6 address is not served |
| kube context | `plane-prod`, the only context in its kubeconfig |
| kubeconfig | `.local/hosted/plane-prod/kubeconfig`, server `https://127.0.0.1:16443` through the SSH tunnel. Never merged into `~/.kube/config` |
| Cluster identity | The `kube-system` namespace's UID and the node name in `target.yaml`. Scripts refuse a cluster where either differs, and Terraform's `environments/prod` one whose UID does |
| SSH | User `wayline-admin`, key `~/.ssh/wayline_contabo_ed25519`, no password and no root login |
| Public hosts | `wayline.bereket.dev`, `grafana.bereket.dev`, `infisical.bereket.dev` |
| Plane | Namespace `plane-prod`, Helm release `plane`, the same Plane release and chart as above |
| Branded images | `ghcr.io/bereketabera/wayline/{web,admin,space,backend}`, plain `linux/amd64` manifests, by digest |
| Argo CD source | `ssh://git@ssh.github.com:443/BereketAbera/plane-platform.git`, branch `deploy/plane-prod` |
| Host-only state | `.local/hosted/plane-prod/`, mode 0700: `kubeconfig`, `secret-zero/`, `terraform/`, `argocd-deploy-key`, the restic password, alert credentials, `ghcr-pull-token`, `recovery-bundle/`. Never in Git, and the recovery bundle never on the VPS |
| Evidence key | `~/.ssh/wayline_evidence_ed25519`, on the Mac only. Its public half is `.github/evidence-signers` |

## 2. Namespaces

Terraform creates every namespace below. Argo CD never creates one (`CreateNamespace=false`). Test scripts create throwaway
namespaces, `gate-checks` and `netpol-sentinel-<time>`, and delete them when they finish.

| Namespace | Purpose | PSA enforce | PSA warn/audit |
|---|---|---|---|
| `argocd` | Argo CD | `baseline` | `restricted` |
| `traefik` | Ingress | `baseline` | `restricted` |
| `monitoring` | Prometheus, Alertmanager, Grafana, Loki, Alloy, kube-state-metrics, blackbox exporter, alert sink | `baseline` | `restricted` |
| `monitoring-agents` | node-exporter only (`hostNetwork`, `hostPID`) | `privileged` | `restricted` |
| `infisical` | Infisical server and its dedicated Postgres and Redis | `baseline` | `restricted` |
| `plane-dev` | Dev environment: Plane, its secrets operator, postgres-exporter, redis-exporter | `baseline` | `restricted` |
| `plane-prod-sim` | Production simulation: the same set | `baseline`, tighten only after a per-workload non-root test passes. That test has passed, and the label has not moved. See below | `restricted` |

Every Plane namespace carries label `plane-platform/environment: dev|prod-sim`. All namespaces in
this table carry `plane-platform/managed-by: terraform`.

Exporters run in the Plane namespaces, not `monitoring`, because postgres-exporter reads that environment's `plane-pgdb`
Secret and each sits beside the data it reads. Application `monitoring-extras` deploys them from
`monitoring/manifests/environments/base/exporters.yaml`, and the quota in section 10 counts them.

The non-root condition on `plane-prod-sim` was met on 2026-11-04, on upstream images: each container ran as its configured
UID, and a server-side dry run of `enforce=restricted` gave no warnings
([plane-prod-sim-host-and-identity-1.txt](evidence/runs/plane-prod-sim-host-and-identity-1.txt),
[plane-dev-psa-1.txt](evidence/runs/plane-dev-psa-1.txt)). Containers with no shell were read from their pod specs, and prod-sim's finished
migrator on 2026-11-05 ([cluster-readings-1.txt](evidence/runs/cluster-readings-1.txt)). Moving the label is a Terraform change that nobody has made.

metrics-server is the one platform workload outside this table. It runs in `kube-system`, which kubeadm
creates, so Terraform does not create or label it. That namespace also holds kind's own CoreDNS, kindnet
and kube-proxy, so its NetworkPolicy selects only the metrics-server pod, with no namespace default-deny.

**Hosted production.** Terraform's `infrastructure/terraform/environments/prod` creates these, each with PSA warn and audit `restricted`
and label `plane-platform/managed-by: terraform`. metrics-server runs in `kube-system` here too, beside K3s's own CoreDNS and local-path
provisioner, under the same narrow policy.

| Namespace | Purpose | PSA enforce |
|---|---|---|
| `argocd` | Argo CD | `baseline` |
| `traefik` | Ingress, on hostPorts 80 and 443 | `privileged`, because `baseline` refuses a hostPort |
| `cert-manager` | cert-manager | `baseline` |
| `monitoring` | Prometheus, Alertmanager, Grafana, Loki, Alloy, kube-state-metrics, blackbox exporter, alert sink | `baseline` |
| `monitoring-agents` | node-exporter only | `privileged` |
| `infisical` | Infisical server, its Postgres and Redis, the Probes of its route, its nightly backup | `baseline` |
| `plane-prod` | Plane, its secrets operator, exporters, the nightly backup. Label `plane-platform/environment: prod` | `baseline`, until a dry run of `restricted` passes on the branded images |
| `frameflow` | Reserved for Frameflow, which is not deployed. Quota of 0 pods, default deny | `restricted` |

## 3. Hostnames and exposure

All local hosts resolve to loopback without `/etc/hosts`. Traefik is a NodePort (30080, 30443), mapped by
kind to `127.0.0.1:80` and `127.0.0.1:443` only. No TLS locally. Hosted production terminates TLS in Traefik on its own node, as the
end of this section says. Nothing here sits behind Cloudflare.

| Host | Backend |
|---|---|
| `plane.dev.localhost` | Plane dev |
| `plane.prod-sim.localhost` | Plane prod-sim |
| `argocd.localhost` | Argo CD UI |
| `grafana.localhost` | Grafana |
| `prometheus.localhost` | Prometheus |
| `alertmanager.localhost` | Alertmanager |
| `infisical.localhost` | Infisical |

**Node network.** Docker assigns the `kind` network a free `/16` that differs per machine (`172.24.0.0/16` on the
machine this was built on), so NetworkPolicies never pin it. They use Docker's default pool, `172.16.0.0/12`, for
node-sourced traffic: API server on 6443, the Git remote on 9418, and NodePort traffic reaching Traefik.
`scripts/cluster-up.sh` fails if the network falls outside that range.

`172.16.0.0/12` is also the measured source of a browser's request. On 2026-11-04 conntrack on the node showed NodePort traffic
arriving from `172.24.0.1`, the kind gateway, and with that block removed a request from the host timed out
([traefik-nodeport-source-1.txt](evidence/runs/traefik-nodeport-source-1.txt)). So `192.168.65.0/24`, which `traefik-ingress`
also allowed until then, was removed in `2d77243`.

**Internal UIs.** The five hosts that are not Plane's carry Middleware `node-network-only`: an `ipAllowList` of exactly
`172.16.0.0/12` with no `ipStrategy`, so Traefik reads the socket address and not a header. Traefik refuses a Middleware from
another namespace, so `monitoring`, `argocd` and `infisical` each hold a copy. A pod arrives from `10.244.0.0/16` and gets 403.
`policy/plane.rego` refuses a route that does not name the Middleware if it uses one of these hosts or their Services, or sits in
one of those namespaces, and a blank, null or missing namespace counts as one of those, because Argo CD places such a route in its
Application's destination. It also refuses a TCP or UDP route beside or to an internal UI, and a Middleware of that name that admits
anything else. `tests/routes/internal-routes.sh` runs both sides. This is a source-address check, not a login.

CoreDNS rewrites `plane.dev.localhost` and `plane.prod-sim.localhost` to
`traefik.traefik.svc.cluster.local`, because the Plane API dials its own public host for
`copy_object` and OAuth avatars. Terraform owns that rewrite.

**Hosted production.** Three public hosts, and no other route:

| Host | Backend | Certificate, in the backend's namespace |
|---|---|---|
| `wayline.bereket.dev` | Plane in `plane-prod`, the chart's paths | `wayline-tls` |
| `grafana.bereket.dev` | `kps-grafana:80` in `monitoring`: two rules, the login under a limit per address, and the rest but `/metrics` | `grafana-tls` |
| `infisical.bereket.dev` | `infisical:8080` in `infisical`: its sign-in and two-factor calls under one limit, its session calls under another, the API families its web client calls, and its pages. Traefik answers 404 to the rest, every machine login and machine credential among them | `infisical-tls` |

- **DNS.** One A record per host in Vercel's `bereket.dev` zone, to `5.253.234.127`, TTL 60, owned by Terraform's
  `environments/prod-host`. No AAAA record, so IPv4 only. A host's record must be live before Argo CD first sees its Certificate,
  because the zone's wildcard answers any name without a record of its own with Vercel's address, and a failed order backs off for an hour or more.
- **TLS.** cert-manager is the only certificate owner: ClusterIssuers `letsencrypt-staging` and `letsencrypt-production`, HTTP-01 through
  Traefik's Ingress provider for class `traefik`, solver Services of type ClusterIP. Traefik has no ACME resolver, its minimum is TLS 1.2,
  and `sniStrict` refuses a handshake for a name it has no certificate for.
- **Exposure.** Traefik listens on hostPorts 80 and 443, behind a ClusterIP Service, with no NodePort or LoadBalancer Service anywhere.
  Port 80 redirects to 443, except ACME's HTTP-01. Every route uses entry point `websecure` alone. The host's nftables table
  `wayline_edge` hooks `prerouting` at priority `mangle`, before kube-proxy's and portmap's DNAT, and admits by stage: `closed` (22),
  `http` (22, 80), `owner` (22, 80, 443 from one /32) and `open` (22, 80, 443). The API server is reached only through the SSH tunnel.
- **No route** for Argo CD, Prometheus, Alertmanager, Silo's console or RabbitMQ's management. `make remote-ui` port-forwards them.
  `policy/hosted.rego` allows a route only in `plane-prod` to Plane's own Services, and Grafana's and Infisical's routes word for word.
- **CoreDNS.** K3s's `coredns-custom` ConfigMap rewrites the three hosts to `traefik.traefik.svc.cluster.local`, for Plane's self-calls,
  cert-manager's self-check and the blackbox probes. Terraform owns it. CoreDNS forwards to `1.1.1.1` and `8.8.8.8`, from
  `infrastructure/hosted/plane-prod/k3s-resolv.conf`, because Contabo's own resolvers are slow.

## 4. Ownership: exactly one owner per resource

| Owner | Owns | Never touches |
|---|---|---|
| **kind CLI** via `scripts/cluster-up.sh` | The cluster and node, CNI (kindnet), port and volume mounts | Anything inside namespaces |
| **Docker Compose** via `infrastructure/local-services/` | Registry, pull-through caches, `git://` remote. These outlive the cluster | Cluster resources |
| **Terraform** via `infrastructure/terraform/environments/local` | Namespaces and labels, ResourceQuota, LimitRange, CoreDNS rewrite, the Argo CD Helm release, AppProjects, the root Application | Anything Argo CD deploys |
| **Terraform** via `infisical/terraform` (separate root and state) | Infisical projects, environments, machine identities, memberships, Kubernetes Auth config | Secret values (`*_wo` or scripts only, never in state) |
| **Argo CD** | Everything else in the cluster: Traefik, metrics-server (in `kube-system`), NetworkPolicies, monitoring, Infisical server, operators, both Plane environments | Namespaces, itself |
| **Helm** | Renders charts. It is a packaging format here, not an owner. Nothing is `helm install`ed by hand | |
| **Infisical** | Secret values and their rotation history | Kubernetes objects (the operator materialises them) |
| **Scripts** via `.local/secret-zero/` | The only secrets that exist before Infisical does. One more after it is live: `scripts/infisical-bootstrap.sh` writes Secret `plane-infisical-identity` in each Plane namespace (section 8) | Any other secret once Infisical is live |

Rule: if `git grep` finds the same resource under two owners, it is a bug. CI checks this.

**Hosted production.** The same rule, on another cluster. `scripts/ci/ownership.sh` reads the hosted tree and render too, and counts a name
that exists on both clusters as two resources.

| Owner | Owns | Never touches |
|---|---|---|
| **`scripts/hosted/provision-node.sh`**, from `infrastructure/hosted/plane-prod/` | K3s and `k3s-config.yaml`, the kubelet drop-in, sysctls, the sshd drop-in, the `wayline-edge` systemd unit, `registries.yaml` | Anything inside a namespace |
| **`scripts/hosted/edge.sh`** | The firewall table's stage | |
| **Terraform** via `infrastructure/terraform/environments/prod-host` | DNS records `wayline`, `grafana`, `infisical`, with `prevent_destroy`. The VPS only as `data "contabo_instance"`, because a resource can reinstall or cancel it | The VPS, and the rest of the zone |
| **Terraform** via `infrastructure/terraform/environments/prod` | Namespaces and labels, ResourceQuota `budget` and LimitRange `defaults` in each, storage class `local-path-retain`, ConfigMap `kube-system/coredns-custom`, the Argo CD Helm release, the bootstrap chart's AppProjects and root Application | Anything Argo CD deploys |
| **Terraform** via `infisical/terraform`, state in `.local/hosted/plane-prod/` | Project `plane-prod`, its identity, membership and Kubernetes Auth config | Secret values |
| **CI**, job `release-plane-prod` in `ci.yml`, through `scripts/ci/publish-release.sh` | Branch `deploy/plane-prod` | `main`, and the cluster |
| **Argo CD** | Everything else on the node, from `deploy/plane-prod` | Namespaces, quotas, LimitRanges, itself |
| **Infisical** | Secret values | Kubernetes objects |
| **Scripts** via `.local/hosted/plane-prod/`, from `scripts/hosted/bootstrap.sh` | Secret zero's Secrets in `infisical`, and `argocd-repo-plane-platform`, `grafana-admin`, `restic-password`, `alertmanager-wayline`, `plane-infisical-identity` | Any value Infisical holds |
| **K3s** | Its CoreDNS, its `local-path` provisioner and storage class, its API server and datastore | `coredns-custom`, which its CoreDNS imports |

## 5. Git, images, and delivery

- **Argo CD source:** `git://plane-git/plane-platform.git`, branch `main`. `plane-git` is a read-only
  container on the `kind` Docker network serving the bare repo at `.local/git/plane-platform.git`. The only
  writer is `make gitops-publish`, which pushes from the working repo to that path.
- **GitHub** (`origin`, private `BereketAbera/plane-platform`) runs CI. The local Argo CD does not read it, and hosted production's reads one
  branch of it, below. `images.yml` builds plain `linux/amd64` images on `ubuntu-24.04`, publishes them to private GHCR packages under
  `ghcr.io/bereketabera/wayline/`, whose digests differ from a local build's, and opens a digest bump for dev. Those images reach the kind
  cluster only if a merged bump is pulled, `scripts/ci/copy-to-local-registry.sh` copies them with their digests, and `make gitops-publish` runs.
  Dev then runs them under Rosetta.
- **Branded images:** `localhost:5001/wayline/{web,admin,space,backend}`, always referenced `@sha256:` by digest.
  `kind load` is forbidden: it is reported to fail on this host's containerd image store (kind #3795), and that was not reproduced
  here, because nothing calls it. `plane-dev` has run them since promotion `4f622e3` and `plane-prod-sim` since `0af8956`, both on
  2026-11-05, and the final build from `84b63d9` since `1fc9fbe` and `9c8e098`. Since 2026-11-07 `plane-dev` runs GHCR's `linux/amd64`
  set `6d3610b95f01` from there, copied with its digests, and `plane-prod-sim` still runs the build from `84b63d9`. `live` stays upstream's in both.
- **Upstream images:** by index digest from `docker.io`, never `artifacts.plane.so`. Pulls go through
  the pull-through caches declared in `infrastructure/kind/containerd-certs.d/`.
- **Plane manifests are rendered and committed.** `helm/plane/` holds the Kustomize overlay over the vendored
  chart. `make render` writes `gitops/environments/{dev,prod-sim}/manifests.yaml`. Argo CD syncs those plain
  manifests with no Helm or Kustomize at sync time. CI fails if rendering produces a diff.
- **Platform charts** (Traefik, monitoring, Infisical): Argo CD Helm sources, exact chart versions, values from
  `helm/values/` via a `$values` ref.
- **Promotion:** `make promote ENV=dev` or `make promote ENV=prod-sim`. Prod-sim accepts only a digest recorded for dev under
  the same image (`scripts/ci/check-promoted-digests.sh`), refuses unless `plane-dev` is Synced and Healthy with that digest in a
  ready container (`scripts/lib/dev-check.sh`), and takes a Postgres dump first. For a prod-sim digest that arrives through a merged
  pull request, `make gitops-publish` repeats the `plane-dev` check and the dump. It runs `check-promoted-digests.sh` only as a warning,
  because rollback uses that path. That check blocks in `scripts/promote.sh`, and a check in CI cannot block a merge on this plan.
  A changed prod-sim line that is not an image also gets a warning, and goes out. `OVERRIDE_DEV_CHECK="<reason>"` goes
  past the `plane-dev` check and is logged, and `SKIP_BACKUP=yes` skips the dump. With no cluster in reach the check is skipped: `scripts/promote.sh`
  says so in the commit message, and `make gitops-publish`, which makes no commit, only warns.
- **Rollback:** `make rollback ENV=<env>` is a `git revert` and a publish. For prod-sim the publish has `SKIP_BACKUP=yes` and
  `SKIP_DEV_CHECK`, so it needs neither a healthy `plane-dev` nor a working backup, and prod-sim gets one best-effort dump first, limited
  to 300s. Dev needs neither, because a publish that moves no prod-sim image asks the cluster nothing. A publish is all of `main`, so a
  rollback of dev stops and names any change on `main` that would move a prod-sim image and has not gone out, and `OVERRIDE_DEV_CHECK`
  goes on. A rollback of prod-sim stops the same way on anything else waiting under a promotion that never reached Argo CD. A conflict
  in a rendered file is settled by rendering, and a conflict anywhere else stops the rollback, as does a commit that touches both
  environments. Images roll back, and schemas do not. The output names the dump to restore, from what `make gitops-publish` records, or says there is nothing to restore if the promotion never
  went out.

**Hosted production.**

- **Argo CD source:** `ssh://git@ssh.github.com:443/BereketAbera/plane-platform.git`, branch `deploy/plane-prod`, read with a read-only
  deploy key whose Secret, `argocd-repo-plane-platform`, `scripts/hosted/bootstrap.sh` writes. The branch holds only
  `gitops/clusters/plane-prod`, `gitops/environments/prod` and `RELEASE.json`, which names the `main` commit and the run that released it.
  No workflow holds a Kubernetes credential.
- **Its only writer** is job `release-plane-prod` in `ci.yml`, through `scripts/ci/publish-release.sh`, on a push to `main` once lint, manifests
  and security have passed. In order: `check-prod-evidence.sh`; no move backwards, so the branch's recorded `main` commit must be an ancestor
  of this one; the branch must still hold what its `RELEASE.json` names, so a hand push stops the release; a branch that runs a set never goes
  back to none; each Wayline digest must be a plain `linux/amd64` manifest on GHCR; then a commit of the two trees alone, pushed without force.
  A failure leaves the branch where it is. `check-deploy-branch.yml` repeats the hand-push comparison daily, and so does `make remote-status`.
- **The evidence gate:** `scripts/ci/check-prod-evidence.sh`, stateless, with no override and no cluster. Every Wayline digest in
  `gitops/environments/prod/manifests.yaml` must be covered by one signed file in `docs/evidence/promotions/`, verified against
  `.github/evidence-signers` as committed. Exit 0 is good, 1 refused, 3 not yet promoted. It covers the render and nothing else.
- **Evidence:** `make record-dev-evidence` writes `docs/evidence/promotions/<set-hash>.json` and its `.sig`, signed with
  `ssh-keygen -Y sign -n wayline-evidence`. It refuses unless the newest dev smoke passed, with `branding-overlay` PASS; every container
  started before that smoke began; every digest runs in `plane-dev` in a ready container; and each branded digest is a plain `linux/amd64`
  manifest on GHCR, built by a successful `images.yml` run on a commit in `origin/main`'s history. It records `executed_under: rosetta-on-arm64`.
- **Promotion:** `gh workflow run promote-plane-prod.yml -f set_hash=<hash>` maps the set to GHCR names, renders, adds
  `applications/plane-prod.yaml` on the first run, runs the gate, and opens a pull request. A person merging it is the approval. `prod-sim`
  is not on this path.
- **Rollback:** a revert on `main`, or promoting an older set, whose evidence still verifies. A revert of the first promotion is refused,
  because root would prune Application `plane-prod`. The database does not go back, and `scripts/hosted/README.md` has the restore path.
- **Images:** the branded four from GHCR, pulled with Secret `ghcr-pull`. Upstream images by index digest, and K3s's containerd pulls
  `docker.io` through `mirror.gcr.io` first. No Docker runs on the VPS. `make scan-images-hosted` and `scan-hosted.yml` scan what this
  cluster runs, for `linux/amd64`.
- **Plane manifests:** `scripts/render.sh --env prod` renders `helm/plane/overlays/prod`, over the same vendored chart and
  `components/hardening`, to `gitops/environments/prod/manifests.yaml`. `make render` runs it after the local two, and CI fails on a diff.
  The overlay has its own host, registry, volumes and sizes, and none of prod-sim's CPU patches.
- **Platform charts:** Argo CD Helm sources at the same versions as locally, plus cert-manager `v1.21.3` from `quay.io/jetstack/charts`,
  with values from `gitops/clusters/plane-prod/values/`: plain copies adapted from `helm/values/`, never patches over them.

## 6. Sync waves

Inside each Plane Application, in order:

| Wave | Resources |
|---|---|
| -3 | ServiceAccounts, `InfisicalConnection` |
| -2 | `InfisicalAuth` |
| -1 | `InfisicalStaticSecret` (health-gated with custom Lua) |
| 0 | ConfigMaps, Services |
| 1 | StatefulSets: postgres, redis, rabbitmq, silo |
| 2 | Migrator Job, as an Argo `Sync` hook. Never `PreSync`: it deadlocks a fresh install |
| 3 | Deployments: api, worker, beat, web, admin, space, live |
| 4 | Ingress routes and their Middlewares |

Root app-of-apps, in order:

| Wave | What |
|---|---|
| -10 | `network-policies`, `backup-storage` |
| -9 | `traefik` |
| -8 | `metrics-server`, and root's second source `gitops/bootstrap/argocd-route`: IngressRoute `argocd-server` and Middleware `node-network-only` |
| -7 | `kube-prometheus-stack` |
| -6 | `loki`, `alloy` |
| -5 | `monitoring-extras` |
| -4 | `infisical`, with waves of its own: ServiceAccount -2, Postgres and Redis -1, server 0, route and Middleware 1 |
| -3 | `infisical-operator-dev`, `infisical-operator-prod-sim` |
| -1 | `plane-dev` |
| 0 | `plane-prod-sim` |

`postgres-exporter` carries `argocd.argoproj.io/ignore-healthcheck`, because `monitoring-extras` syncs at -5 and its Secret
`plane-pgdb` does not appear until -1.

`argocd-cm` carries these health overrides (`resource.customizations.health.*` in `helm/values/argocd.yaml`), and the first is what
makes the root waves gate:

| Kind | Why | What it reads |
|---|---|---|
| `argoproj.io/Application` | Argo CD removed this check in 1.8, and its own aggregation skips hooks and resources not created yet, so a child would read Healthy between its internal waves | Healthy only with health Healthy, no `.operation` in flight, and sync status Synced. A child that stays OutOfSync therefore holds every later wave |
| `monitoring.coreos.com/Prometheus` | The built-in check reads `NoPodReady` as Degraded, which is every Prometheus start, and that failed root's sync on the first boot | Not-ready pods read Progressing, so the wave waits. `Reconciled: False` stays Degraded. The cost is that a Prometheus that can never start also reads Progressing, and root waits on it with no retry |
| `secrets.infisical.com/InfisicalStaticSecret` | `status.error` means something only at the current generation | Healthy or Degraded once `observedGeneration` matches, Progressing before that |
| `secrets.infisical.com/InfisicalAuth`, `InfisicalConnection` | They carry only a condition | Follows `IsReady` at the current generation |

Root and every child retry without limit, with `refresh: true`. A Degraded child fails root's sync and the retry reads the newest
commit. A child in any other state holds root in `Running` with no retry, so a fix to an Application manifest then needs root's
operation terminated (`infrastructure/terraform/README.md`).

The waves order the sync, and nothing more. Root's own operation ends right after it applies wave 0, without
waiting for `plane-prod-sim`, and `plane-dev` stays Degraded until `scripts/infisical-bootstrap.sh` publishes
its identity Secret. So readiness is never read from root: `make up` waits for Traefik, then Infisical, and only
after the bootstrap for all 14 Applications, each Synced and Healthy.

**Rollout settings.** Set in `helm/plane/components/hardening` for both environments:

- `progressDeadlineSeconds: 600` on all seven Deployments. Image pulls count against it and the kubelet pulls one image at a time,
  so on a cold mirror the last pod of wave 3 started 448s in ([plane-dev-firstboot-1.txt](evidence/runs/plane-dev-firstboot-1.txt)).
  The earlier value, 360, failed web, admin and space on that first boot and held the sync until a retry. That event was read live
  and is not in a saved file. 600 stays above the longest startup budget, 300s.
- `preStop: {sleep: {seconds: 5}}` on web, admin, space, live and api. A pod gets SIGTERM as its endpoint starts to go, and Traefik
  can still send it requests for a moment. Without the pause a rollout failed 10 of 2,757 samples, and with it 0 of 5,902 across two rollouts
  ([before](evidence/runs/plane-dev-rollout-availability-1.txt), [after](evidence/runs/plane-dev-rollout-availability-2.txt)).

**Hosted production.** Root app-of-apps, from `gitops/clusters/plane-prod/applications/`, with the same health overrides and the same
retry without limit and `refresh: true`. Root has no resources finalizer, so removing its release does not cascade into production's data.

| Wave | What |
|---|---|
| -10 | `network-policies`, `backup` |
| -9 | `traefik` |
| -8 | `cert-manager`, `metrics-server` |
| -7 | `certificates`, `kube-prometheus-stack` |
| -6 | `loki`, `alloy` |
| -5 | `monitoring-extras` |
| -4 | `infisical`: the chart, and from `platform/infisical` its Postgres, Redis, ServiceAccount, token reviewer and public route |
| -3 | `infisical-operator-prod` |
| 0 | `plane-prod`, added by the first promotion from `plane-prod-application.yaml.tmpl` |
| 1 | `rillmark`, `awushi-cloudgarden`, `infisical-operator-frameflow` |
| 2 | `frameflow` |

That is 17 children and root, 18 Applications. The four at waves 1 and 2 are the apps beside Wayline, after it:
[hosted-apps.md](hosted-apps.md). Inside `plane-prod` the waves are the ones above, with two additions: the seventh
`InfisicalStaticSecret`, `ghcr-pull`, at -1, and Job `plane-prod-predeploy-dump`, a `Sync` hook at wave 1, which waits for Postgres,
tolerates an empty database, and dumps to the backup volume before the migrator runs at wave 2. The ClusterIssuers, the Certificates and
the three backup CronJobs carry `argocd.argoproj.io/ignore-healthcheck`, so an outside service that cannot be reached, or one failed night,
does not fail root's sync. Alerts report those instead.

## 7. Argo CD projects

| Project | May deploy to | May create |
|---|---|---|
| `platform` | All namespaces | Cluster-scoped resources, CRDs, operators, every NetworkPolicy, ClusterRoleBindings |
| `plane-dev` | `plane-dev` only | Namespaced workloads and Infisical CRs. No NetworkPolicy, no cluster-scoped resources |
| `plane-prod-sim` | `plane-prod-sim` only | Same as `plane-dev` |

`policy/gitops.rego` refuses a Plane Application under any other project, any Application under project `default` or none,
rendered manifests of an environment under any project but its own, and a document that wraps others under any kind, because conftest
reads only the outer one, and `policy/charts.rego` refuses the same through a chart's values. That check runs in CI, and nothing makes it block a merge on this GitHub plan. `scripts/ci/lib-manifests.sh`
also refuses a `.yml`, `.json` or `.jsonnet` file in a plain directory Argo CD reads, because no check would read it, and any other `*.yaml` beside a rendered `manifests.yaml`.

**Hosted production.** Terraform installs two AppProjects from `gitops/clusters/plane-prod/bootstrap-chart/`, read from no branch, so
nothing Git delivers can widen them. `policy/gitops.rego` and `policy/hosted.rego` hold the hosted Applications to them.

| Project | May deploy to | May create |
|---|---|---|
| `platform` | All namespaces, from the repository and the seven chart repositories it lists | Cluster-scoped resources and NetworkPolicies. Never a Namespace, ResourceQuota or LimitRange, which Terraform owns |
| `plane-prod` | `plane-prod` only, from the repository alone | Namespaced workloads and Infisical CRs. No NetworkPolicy, ResourceQuota, LimitRange or cluster-scoped resource |

Every Plane environment syncs automatically with self-heal. The prod-sim control point is the Git change,
not the sync button. A drill that changes live objects behind Git's back must pause self-heal first, or Argo CD reverts the change within
seconds: a replica change on `plane-admin-wl` was put back in 3s ([GITOPS-4](evidence/runs/GITOPS-4-20261105T073240Z.txt)). A failure delivered through a commit keeps self-heal on, because the bad state is then what Git asks for.

## 8. Secret contract

Six Kubernetes Secrets in each Plane namespace, each produced by an `InfisicalStaticSecret`, and a seventh that holds no secret value:

| Secret | Keys |
|---|---|
| `plane-app-env` | `DATABASE_URL`, `REDIS_URL`, `AMQP_URL` |
| `plane-app-keys` | `SECRET_KEY`, `LIVE_SERVER_SECRET_KEY` |
| `plane-live-env` | `REDIS_URL` |
| `plane-doc-store` | `USE_MINIO=1`, `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_S3_BUCKET_NAME=uploads`, `AWS_S3_ENDPOINT_URL=http://plane-minio:9000`, `FILE_SIZE_LIMIT=5242880` |
| `plane-pgdb` | `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` |
| `plane-rabbitmq` | `RABBITMQ_DEFAULT_USER`, `RABBITMQ_DEFAULT_PASS` |
| `plane-infisical-identity` | `identityId`. Written by `scripts/infisical-bootstrap.sh`, not the operator, because the id changes on every re-bootstrap and the CRD accepts only a Secret reference. It is not a credential: login also needs a ServiceAccount token |

Hard rules, each learned from reading upstream code:

- The rendered manifests contain **zero `kind: Secret`**. CI enforces it.
- The bucket is `uploads` in both environments. Any other name breaks export links (`export_task.py`). Isolation
  comes from each environment having its own Silo.
- Passwords are hex. The chart does not URL-encode them into connection strings.
- `FILE_SIZE_LIMIT` is bytes. `5MB` crashes Django at import.
- **Never rotate `SECRET_KEY`.** It derives the key for the encrypted config rows, 7 on a fresh instance and 8 once `scripts/backup.sh` has added its sentinel row, and `decrypt_data` fails silently to `""`.
- Each environment has its own Infisical project, machine identity (built-in `viewer`), and org role `no-access`.
  Custom roles and folder RBAC are paid features, so per-project isolation is the free-tier boundary.
- Secret zero (Infisical's `ENCRYPTION_KEY`, `AUTH_SECRET`, database and Redis passwords) lives in `.local/secret-zero/`, mode 0600,
  and in the cluster Secrets `scripts/secret-zero.sh` makes from it.

**Hosted production.** The same six, from project `plane-prod`, environment `prod`, of an Infisical of its own in namespace `infisical`, plus a
seventh synced Secret and the same identity Secret:

| Secret | Keys |
|---|---|
| `ghcr-pull` | `.dockerconfigjson` for `ghcr.io`, from the token at `/GHCR_PULL_TOKEN`. ServiceAccount `plane` names it in `imagePullSecrets` |
| `plane-infisical-identity` | `identityId`, as above |

- One operator, from Application `infisical-operator-prod`, scoped to `plane-prod`. The identity may log in only from namespace `plane-prod`
  and ServiceAccount `plane-infisical-auth`, through Infisical's Service and not its public route, which refuses a machine's credential.
- Secret zero, the restic password, the deploy key and the alert credentials live in `.local/hosted/plane-prod/`, never in Infisical, so
  nothing is circular. `scripts/hosted/bootstrap.sh` writes them as Secrets: Infisical's three, `restic-password` in `plane-prod` and
  `infisical`, `argocd-repo-plane-platform`, `grafana-admin` and `alertmanager-wayline`. The GHCR pull token starts as
  `.local/hosted/plane-prod/ghcr-pull-token`, and the seed puts it into Infisical, where `ghcr-pull` reads it.
- `scripts/secret-zero.sh`, `infisical-bootstrap.sh` and `infisical-seed.sh` take hosted production only through `scripts/hosted/target.sh`,
  when `WAYLINE_TARGET=plane-prod` and `CONFIRM=plane-prod` are both set. Otherwise they behave as they do locally.
- `scripts/hosted/bundle.sh` writes the recovery bundle: secret zero, every Terraform state, the deploy key, the restic password, the
  read-only pull key, the alert credentials, the GHCR token, Grafana's admin login, any off-site credentials and the SSH known hosts, encrypted
  with age to the recipient in `scripts/hosted/recovery-recipient.txt`. Not the kubeconfig, which SSH brings back, and no backup. The private
  identity stays with the owner, and the bundle never goes to the VPS.
- K3s runs with `secrets-encryption: true`, so Secrets are encrypted at rest in its datastore.
- Infisical's one admin signs in through its public route with an authenticator app. Email codes cannot work, because there is no SMTP.

## 9. Data services

Per environment, from chart 1.8.6 with digests overridden:

| Service | Image | Digest |
|---|---|---|
| PostgreSQL | `postgres:15.19-alpine` | `sha256:54e0dd8e8cddcdbb9156c2486eed5a43eccb7214d7c6828097d41ce049fb3984` |
| Valkey | `valkey/valkey:7.2.15-alpine` | `sha256:f8c1a646f4b31ae4dc3980ff06723a20b533ea1123b9796d450d78ed53ad6d3e` |
| RabbitMQ | `rabbitmq:3.13.7-management-alpine` | `sha256:606d8c0d6b3c18d1da9afc53bc7cdb2a8d5486df91b5a9830e9e07626c9ae281` |
| Silo (MinIO fork) | `pgsty/silo:RELEASE.2026-10-26T00-00-00Z-distroless` | `sha256:e6544a902f426f2b4e775b89f3c1cd78310dbffc262d1ed82e9800c1cb1b5885` |

- RabbitMQ must stay on 3.13 or 4.2. On 4.3 Celery attaches 0 consumers (upstream chart PR #304). It needs
  `vm_memory_high_watermark.absolute = 256Mi` in `conf.d`.
- Official MinIO images no longer pull anonymously (repo archived). Silo is the fork upstream Plane itself uses.
  It speaks the same S3 API and uses the same data format. Documentation says "MinIO-compatible (Silo)" and explains this.
- The Silo pin is this repository's, not upstream's. Chart 1.8.6 and upstream's compose pair Plane v1.4.3 with
  `RELEASE.2026-09-16T00-00-00Z`, and the digest above is the newer distroless `RELEASE.2026-10-26T00-00-00Z-distroless`.
  [ADR 0005](adr/0005-minio-compatible-silo.md) has the reasoning and the fallback.
- PVs use kind's default `standard` class on the Docker VM volume, not VirtioFS. Backups go to `/backups`, which is host-mounted.

**Hosted production.** The same four images, by the same digests, pulled as `linux/amd64`. Volumes use storage class `local-path-retain`,
which Terraform makes on K3s's `local-path` provisioner with reclaim `Retain`, because K3s's own class deletes a volume with its claim. Sizes:
Postgres 30Gi, Valkey 2Gi, RabbitMQ 4Gi, Silo 64Gi. `local-path` does not enforce a size, so only the disk alerts bound what a volume holds.
Backups go to static hostPath PVs, `Retain`, under `/srv/wayline/backups/plane-prod` (40Gi) and `/srv/wayline/backups/infisical` (10Gi),
one PVC `backups` in each of those namespaces. Nightly, sealed with `restic/restic:0.19.1` by digest: `infisical` at 01:47 UTC and
`plane-prod` at 02:17 UTC, kept 7 daily, 4 weekly and 3 monthly, then `restic check`. Predeploy dumps are kept 90 days.

## 10. Memory budget per workload

Requests and limits in MiB. Change these only with a measurement.

| Workload | Req | Limit | | Workload | Req | Limit |
|---|---:|---:|---|---|---:|---:|
| web | 16 | 64 | | worker (`CELERY_WORKER_CONCURRENCY=2`) | 256 | 768 |
| admin | 16 | 64 | | beat | 128 | 256 |
| space | 96 | 256 | | postgres | 128 | 512 |
| live | 128 | 384 | | valkey | 16 | 96 |
| api (1 gunicorn worker) | 256 | 768 | | rabbitmq | 128 | 512 |
| silo | 256 | 512 | | | | |

Bring the two environments up serially. Simultaneous first boots are the worst case for memory.

Terraform turns this budget into a `ResourceQuota/plane-budget` in each Plane namespace (`modules/foundation/main.tf`). Deployments
count twice, because a rolling update surges one extra pod each and a quota that fits only the steady state fails the rollout:

| Resource | Hard limit | How derived |
|---|---:|---|
| `requests.memory` | 2732Mi | 2 x 896 for Deployments, 528 for StatefulSets, 412 for extras |
| `limits.memory` | 7984Mi | 2 x 2560 for Deployments, 1632 for StatefulSets, 1232 for extras |
| `pods` | 24 | 2 x 7 Deployments, 4 StatefulSets, 6 extras |
| `persistentvolumeclaims` | 6 | 4 StatefulSets, the backup PVC, one spare for restore drills |

Extras, request and limit in MiB: secrets operator 64/128, postgres-exporter 16/48, redis-exporter 12/32, migrator 128/512, backup
Job 128/256, one ad-hoc pod 64/256. There is no CPU line, because the budget has no CPU and a CPU quota would reject any pod that
omits a request. `LimitRange/plane-defaults` sets a default limit of 256Mi, a default request of 64Mi, and a maximum of 1Gi per container.

The quota does not fit every Deployment, exporters included, surging at once with the migrator, a backup and an ad-hoc pod: that
is 26 pods, 2760Mi and 8064Mi ([quota-budget-1.txt](evidence/runs/quota-budget-1.txt)). All seven Plane Deployments surging together
reached 21 of 24 pods with no `FailedCreate` ([plane-dev-rollout-quota-1.txt](evidence/runs/plane-dev-rollout-quota-1.txt)).

**Hosted production.** Sizes come from `helm/plane/overlays/prod/patches/`, which run after `components/hardening` and replace its numbers.
They are starting values from the hosted design's sizing table, to be measured again on this node. One replica of each. CPU, then memory in
MiB, request and limit:

| Workload | CPU | Memory | | Workload | CPU | Memory |
|---|---:|---:|---|---|---:|---:|
| web | 20m / 500m | 32 / 128 | | worker (`CELERY_WORKER_CONCURRENCY=4`) | 250m / 2000m | 512 / 1536 |
| admin | 20m / 500m | 32 / 128 | | beat | 20m / 200m | 128 / 256 |
| space | 50m / 500m | 128 / 384 | | postgres | 1000m / 4000m | 2048 / 4096 |
| live | 100m / 1000m | 256 / 768 | | valkey | 50m / 500m | 64 / 512 |
| api (3 gunicorn workers) | 500m / 3000m | 768 / 2048 | | rabbitmq | 100m / 1000m | 256 / 1024 |
| silo | 100m / 1000m | 384 / 1536 | | | | |

`infrastructure/hosted/plane-prod/capacity.yaml` sets a ResourceQuota `budget` and a LimitRange `defaults` on every namespace Terraform
makes, and Terraform applies them. Quotas cap and do not reserve:

| Namespace | `requests.cpu` | `requests.memory` | `limits.memory` | Pods | PVCs | `requests.storage` |
|---|---:|---:|---:|---:|---:|---:|
| `plane-prod` | 3300m | 7Gi | 14688Mi | 32 | 6 | 140Gi |
| `monitoring` | 300m | 1792Mi | 4416Mi | 14 | 3 | 27Gi |
| `infisical` | 300m | 1664Mi | 2400Mi | 6 | 3 | 13Gi |
| `argocd` | 250m | 512Mi | 1984Mi | 8 | 0 | 0 |
| `traefik` | 100m | 192Mi | 512Mi | 3 | 0 | 0 |
| `cert-manager` | 50m | 192Mi | 448Mi | 6 | 0 | 0 |
| `monitoring-agents` | 20m | 48Mi | 128Mi | 2 | 0 | 0 |
| `frameflow` | | | | 0 | 0 | 0 |

`plane-prod`'s `limits.memory` is 12624Mi steady and 2064Mi of room for one surge, the api's, or a backup's or migrator's. The node is
counted as 12 CPU, 47Gi and 400Gi, less the system's share: 1500m and 5Gi, which `kubelet.conf` reserves or keeps free for eviction, and
40Gi of disk for the OS, K3s's data and the images.
Frameflow's reservation, 18Gi of memory, 6 CPU requested and 100Gi of temporary disk, is not deployed, and exists as what the caps on everything
else leave free. `scripts/ci/check-capacity.sh` runs in CI's Manifests job and fails unless every quota's sum, with the system's share and
Frameflow's, still fits the node. A quota sized for the steady state alone would stop a rollout, so each leaves room for its largest surge,
and several surging together go one after another.

## 11. Make interface

`make setup up status test logs backup restore down` plus `destroy`, `render`, `promote`, `rollback`, `rotate`, `restore-clean`,
`ci`, `images`, `gitops-publish`, `gates`, `test-e2e`, `test-netpol`, `test-infisical`, `test-routes`, `test-separation`, `test-alert`,
`test-load`, `scan-images`, `publish-evidence`, `drill-failed-deploy`, `drill-pod-restart`, `drill-clean-restore`,
`drill-clean-restore-harness`, `wayline-upgrade-check`, `wayline-upstream-check`.
`make help` lists them. Options are passed as `make <target> NAME=value`. `tests/drills/failed-migrator.sh` has no target and runs directly.
`make drill-clean-restore CONFIRM=yes CLEAN_INSTALL_FIRST=yes` backs up, deletes the cluster, runs `tests/drills/clean-install.sh` from a fresh clone with
new secrets, deletes that, and restores from backup into a new cluster. It keeps the local registry and the pull-through caches, and copies `.tools`. `COLD_INSTALL=yes`, which goes only with `CLEAN_INSTALL_FIRST=yes`, removes the local services and their volumes instead, so the clean
install builds and promotes its images and pulls everything through empty caches. It still copies `.tools`, and it saves the registry to `.local/registry-snapshot.tar` and puts it back at the end.

- `make down` stops the cluster and **keeps all data**. `make up` resumes it.
- `make up` is idempotent, so it is also how to continue after a failure. It refuses uncommitted changes under
  `gitops/`, `helm/`, `monitoring/` and `infisical/`, because Argo CD reads only commits.
  `UP_STOP_AFTER=<cluster|publish|terraform|secret-zero|traefik|infisical>` stops it after that step.
- `make test` keeps going after a failure and labels each test PASS, FAIL or BLOCKED. `scripts/test.sh` exits 0,
  1 or 2 for those, as `tests/e2e/smoke.py` does. `make` itself exits 2 on any failure, and prints which.
- `make destroy` deletes the cluster, refuses without `CONFIRM=yes`, and takes a backup unless `SKIP_BACKUP=yes`. With an unfinished clean
  restore that backup still goes ahead, because what it deletes may be all there is, where a plain `make backup` refuses an environment that
  restore has not finished and whose data has not come back, unless `ALLOW_BACKUP_DURING_RESTORE=yes`. `SKIP_BACKUP=yes` then deletes what is there with no backup. `make destroy` removes
  `.local/terraform/local` and keeps backups, secret zero and `.local/terraform/infisical`, because a clean restore needs them.
  `PURGE=yes` also removes the local services and their volumes.
- `make restore` refuses to overwrite a non-empty environment without `CONFIRM=yes`. `make restore-clean` brings the whole platform
  back into a clean environment, Infisical first, and a resume keeps an environment whose data has come back and refuses one that does not match this backup part way through,
  unless `ALLOW_RESUME_OVERWRITE` names it, as in `ALLOW_RESUME_OVERWRITE=dev` or `"dev prod-sim"`, out of `infisical`, `dev` and `prod-sim`. `yes` is refused. The overwrite is recorded as FAIL. `scripts/restore.sh` exits 0 when everything is proven, 1 when something failed, and 2
  when nothing failed but something could not run or a person has to act, which is not a pass. `scripts/restore.sh infisical` alone also has 3:
  Infisical is back, and a person has to sign in to prove it. A clean restore also has 4: everything is proven and nothing is left to resume, and the run overwrote what
  `ALLOW_RESUME_OVERWRITE` named, so its result reads `OVERWROTE`, which is not a pass. Through `make`, any of these but 0 is make's own exit 2, and make prints the script's.
- Scripts that write to the cluster, a registry or the disk check free host disk through `guard_disk`, because the Docker VM
  cannot see the real limit. The default is 10 GiB (`MIN_FREE_DISK_GIB`). `up.sh` asks for 25 and `cluster-up.sh` for 15 when
  creating a cluster, and `ALLOW_LOW_DISK="<reason>"` goes past those two and is logged, but not past the 10 GiB, and it refuses a reason of fewer than two words. `MIN_FREE_DISK_GIB` below the default is the way past that, and is logged too. `scan-images.sh`
  asks for 15, and scripts that write little ask for 1 or 2, such as `promote.sh`, `rollback.sh` and `gitops-publish.sh`.
  `down.sh`, `destroy.sh`, `logs.sh`, `status.sh`, `copy-to-local-registry.sh` and the CI checks do not call it directly, so the first four
  still work on a full disk. `destroy.sh` reaches it through `backup.sh` unless `SKIP_BACKUP=yes`, and `scripts/ci/validate-manifests.sh`, so `make ci`, reaches it through `render.sh --check`, at 1 GiB. `prereqs.sh` has its own floor of 25 GiB.

**Hosted production.** `make remote-<verb> TARGET=plane-prod`, and nothing else reaches it: no local target can, and `ENV=prod` stays
refused by the local scripts. Verbs: `tunnel`, `kubeconfig`, `status`, `bootstrap`, `ui`, `grafana-admin`, `infisical-admin`, `smoke`,
`test`, `netpol`, `backup`, `restart-check`, `pull-setup`, `pull-backups`, `backup-dest`, `restore-test`, `alerts`, `bundle`,
`publish-evidence`. `make help` says what each takes.

- Every script that reaches the cluster does so through `scripts/hosted/lib.sh`. It sources `scripts/lib/common.sh`, which stays hard-wired
  to kind, then overrides `KUBECONFIG`, `KUBE_CONTEXT`, `LOCAL_DIR` and `kc`, needs `TARGET=plane-prod`, and fails closed unless the live
  `kube-system` UID and node name match `target.yaml`. `provision-node.sh` and `edge.sh` stand apart, because they run before there is a
  cluster to compare.
- What changes something needs `CONFIRM=plane-prod`. `CONFIRM=yes` does not count, so a habit from the local targets aims nothing.
- `make remote-test` exits 0, 1 or 2 like `make test`, and says BLOCKED or INCOMPLETE plainly. `ONLY="outside backups"` runs parts of it.
- `scripts/ci/check-cluster-separation.sh`, run by `scripts/ci/lint.sh` in CI and `make ci`, refuses a local marker (`plane-git`,
  `localhost:5001`, `*.localhost`, `kind-<name>` or kind's address pool) in the hosted trees and scripts; `gitops/clusters`, a bare
  `plane-prod`, `grafana.bereket.dev` or `infisical.bereket.dev` in the local trees; and `kubectl` in `scripts/hosted` except through the
  kubeconfig and context `lib.sh` sets.
- From the Mac, outside `remote-*`: `make record-dev-evidence` writes the signed evidence, and `make scan-images-hosted` scans what this
  cluster runs from the registries alone.

## 12. Evidence rule

A claim in the docs needs evidence in `docs/evidence/`, captured from a real run with its date and command. Results are
labelled **PASS**, **FAIL**, **BLOCKED** or **NOT RUN**. A number with no measurement behind it must say "estimate".
No secrets, tokens or passwords in evidence files. Scripts write raw output to `.local/evidence-raw/`, and
`make publish-evidence` copies it to `docs/evidence/runs/` with secret values scrubbed and fails on any gitleaks finding.

Hosted runs write to the same `.local/evidence-raw/`. `make remote-publish-evidence TARGET=plane-prod` first collects the values of hosted
production's Secrets and Grafana's admin password for the scrub, through `scripts/hosted/scrub-values.sh`, then runs `make publish-evidence`,
which itself reaches no hosted cluster. Promotion evidence, `docs/evidence/promotions/<set-hash>.json` and its signature, is written by
`make record-dev-evidence` and never edited, because an edited file no longer verifies.

A row may read PENDING for a hosted run planned for the night of 2026-11-07 that had not run when its page was written. PENDING is not a
result: the run gives the row one of the four labels, and that counts once its file is here.

## 13. Repository layout and directory owners

```text
apps/wayline/                  branding: pinned-source patches, overlay, codemod, Dockerfiles
infrastructure/kind/           cluster template, containerd mirror config
infrastructure/local-services/ registry, pull-through caches, git daemon (Compose)
infrastructure/terraform/      modules/{foundation,argocd}, environments/local; for hosted production environments/prod (the cluster)
                               and environments/prod-host (the VPS as data, and DNS). environments/dev is an interface document
infrastructure/hosted/plane-prod/  target.yaml, capacity.yaml, K3s, kubelet and registry config, the firewall table and its unit,
                               sshd and sysctl drop-ins, the alert config template, restore-test templates
helm/plane/                    vendor/ (byte-identical chart), components/hardening, overlays/{dev,prod-sim,prod}
helm/values/                   values for every local platform chart, one file per chart
gitops/bootstrap/              root Application source (applied by Terraform)
gitops/applications/           Application manifests; the local root app syncs this directory
gitops/platform/               plain manifests owned by the platform project (network-policies, backup-storage)
gitops/clusters/plane-prod/    hosted production: bootstrap-chart/ (AppProjects and root, installed by Terraform), applications/,
                               values/ (plain copies adapted from helm/values), platform/ (network policies, certificates, backup,
                               monitoring extras, Infisical's own objects)
gitops/environments/           rendered Plane manifests: {dev,prod-sim,prod}/manifests.yaml. Generated, never hand-edited
infisical/                     Terraform root for Infisical config, plus docs
monitoring/                    dashboards, rules, blackbox config, alert sink (manifests/ is a Kustomize root)
policy/                        conftest rules
tests/                         e2e/ smoke, gates/ day-1, drills/, load/, routes/ internal UIs, separation/ between environments,
                               rules/ promtool unit tests, network-policy-matrix.yaml
scripts/                       entry points behind make targets; scripts/lib/common.sh is sourced by nearly all, scripts/lib/up-checks.sh holds
                               what up.sh, restore.sh and the clean-restore drill refuse on, scripts/ci/ holds CI's,
                               scripts/hosted/ everything that touches the VPS, through scripts/hosted/lib.sh
docs/                          adr/, runbooks/, evidence/{runs,ci,security,branding,promotions}
.github/workflows/             thin workflows that call the same scripts as make targets
```

Image digests for a Plane environment live in `helm/plane/overlays/<env>/kustomization.yaml` under `images:`.
`make promote` edits them and re-renders, and `make rollback` takes an edit back with `git revert`. Nothing else writes those lines for
`dev` and `prod-sim`. For `prod`, `scripts/ci/promote-prod.sh`, run by `promote-plane-prod.yml`, writes them from a signed set, and a revert on
`main` takes one back.

The root app also includes `backup-storage` (wave -10), pointing at `gitops/platform/backup-storage`: a static hostPath PV
on `/backups/<name>`, `Retain`, for each of `dev`, `prod-sim` and `infisical` (`backups-dev`, `backups-prod-sim`,
`backups-infisical`), plus a PVC named `backups` in each of those three namespaces, so backup pods mount only a PVC and
stay PSA-compatible.

## 14. Changes to this contract

Each line settles a place where the code and this file disagreed, by changing this file to match the code. Times in commits are
+0300, so the UTC dates below can read a day earlier than `git log`.

| Date of the change in code | Section | Now true | Where |
|---|---|---|---|
| 2026-11-04 | 2 | Exporters run in the Plane namespaces, and metrics-server in `kube-system`. The code always did this | `monitoring/manifests/environments/base/exporters.yaml`, `gitops/applications/metrics-server.yaml` |
| 2026-11-04 | 3 | `172.16.0.0/12` is the measured NodePort source, and `192.168.65.0/24` is gone | `2d77243`, [traefik-nodeport-source-1.txt](evidence/runs/traefik-nodeport-source-1.txt) |
| 2026-11-04 | 3 | `node-network-only` on the five internal UIs | `fee3947`, [routes-after-3.txt](evidence/runs/routes-after-3.txt) |
| 2026-11-05 | 3 | The allow list is required by namespace and Service as well as host, and no TCP or UDP route may sit beside an internal UI | `91bf4b3`, `policy/plane.rego` |
| 2026-11-04 | 4, 8 | A seventh Secret, `plane-infisical-identity`, written by a script. The code always did this | `scripts/infisical-bootstrap.sh`, [infisical-bootstrap-1.txt](evidence/runs/infisical-bootstrap-1.txt) |
| 2026-11-04 | 5 | Prod-sim also needs `plane-dev` to have proven the digest, recorded under the same image | `3a67ba0`, `scripts/lib/dev-check.sh`, `scripts/ci/check-promoted-digests.sh` |
| 2026-11-04 | 5 | `make gitops-publish` repeats the `plane-dev` check and the dump, and not the check of what dev recorded | `3a67ba0`, `scripts/gitops-publish.sh` |
| 2026-11-04 | 6 | The whole root wave list, including root's second source | `gitops/applications/*.yaml`, `gitops/bootstrap/argocd-route/ingressroute.yaml` |
| 2026-11-04 | 6 | Application health needs no `.operation` and Synced, and root retries with `refresh: true` | `615e97c`, [argocd-wave-gating-1.txt](evidence/runs/argocd-wave-gating-1.txt) |
| 2026-11-04 | 6 | A Prometheus with no ready pod reads Progressing | `40403db`, [h43-lua-runtime-1.txt](evidence/runs/h43-lua-runtime-1.txt) |
| 2026-11-04 | 6 | `progressDeadlineSeconds: 600`, was 360 | `4b33f75` |
| 2026-11-04 | 6 | `preStop` sleep of 5s on the five Deployments behind a Service | `2aefba1` |
| 2026-11-04 | 7 | A policy rule holds each Plane Application to its own project | `b19fe26`, `policy/gitops.rego` |
| 2026-11-04 | 7 | Only a change behind Git's back needs self-heal paused. The code always did this | `tests/drills/failed-deploy-rollback.sh` |
| 2026-11-04 | 9 | The Silo pin is newer than upstream's. The code always did this | `helm/plane/overlays/*/kustomization.yaml`, [ADR 0005](adr/0005-minio-compatible-silo.md) |
| 2026-11-04 | 10 | Quota 2732Mi, 7984Mi, 24 pods, with the exporters budgeted. It was 2704Mi, 7904Mi, 22 pods | `bc8bb91`, [quota-budget-1.txt](evidence/runs/quota-budget-1.txt) |
| 2026-11-05 | 11 | `guard_disk` is not in every script, on purpose, and the target list is complete | `scripts/`, `Makefile` |
| 2026-11-05 | 11 | A new cluster's disk checks take `ALLOW_LOW_DISK`, and the 10 GiB floor does not | `1fb4707`, `scripts/lib/up-checks.sh` |
| 2026-11-05 | 1 | A lost cluster's state moves aside to `terraform/local.stale-<time>`, and each publish is recorded in `publishes.log` | `1fb4707`, `4664cbd` |
| 2026-11-05 | 3, 7 | A blank or null namespace reads as none, and a document that wraps others is refused | `c32d27c`, `dc200f2`, `policy/` |
| 2026-11-05 | 5 | `make gitops-publish` warns about a digest `make promote` would refuse and about prod-sim lines that are not images, and goes on | `cf55d3d`, `7ca9ace`, `scripts/gitops-publish.sh` |
| 2026-11-05 | 5 | A rollback of dev needs no dump or check, and stops on an unpublished prod-sim change. A rollback names the dump from the publish record | `7ca9ace`, `4664cbd`, `scripts/rollback.sh` |
| 2026-11-05 | 7 | CI refuses a file only Argo CD would read in a plain directory or beside a render, and a List through a chart's values | `010cdd5`, `40a2e3a`, `scripts/ci/lib-manifests.sh`, `policy/charts.rego` |
| 2026-11-05 | 11 | `MIN_FREE_DISK_GIB` below the default is logged | `e1c12a1`, `scripts/lib/common.sh` |
| 2026-11-05 | 11 | `scripts/restore.sh` has a documented exit 2, and `failed-migrator.sh` has no make target | `scripts/restore.sh`, `1c6adbe` |
| 2026-11-05 | 13 | `scripts/lib/up-checks.sh` is named | `scripts/lib/up-checks.sh` |
| 2026-11-05 | 5 | A rollback of a commit touching both environments stops | `53aab26`, `scripts/rollback.sh` |
| 2026-11-05 | 1, 11 | `make drill-clean-restore` takes `CLEAN_INSTALL_FIRST=yes`, and with it `COLD_INSTALL=yes`, which removes the local services and keeps a registry snapshot. A backup refuses an environment a clean restore has not finished, a resume refuses to overwrite, and `ALLOW_LOW_DISK` needs words | `tests/drills/clean-install.sh`, `3e87cc0`, `scripts/backup.sh`, `scripts/restore.sh`, `scripts/lib/up-checks.sh` |
| 2026-11-04 | 5 | With no cluster in reach, `scripts/promote.sh` records the skipped check in the commit, and `make gitops-publish`, which makes no commit, only warns. The code always did this | `3f500ab`, `3a67ba0`, `scripts/lib/dev-check.sh` |
| 2026-11-04 | 8 | `SECRET_KEY` covers 7 encrypted rows on an instance no backup has touched, and 8 once `scripts/backup.sh` has added its sentinel. The code always did this | `scripts/backup.sh`, [smoke-dev-20261104T225624Z.json](evidence/runs/smoke-dev-20261104T225624Z.json), [smoke-dev-20261105T001213Z.json](evidence/runs/smoke-dev-20261105T001213Z.json) |
| 2026-11-04 | 11 | `scripts/ci/validate-manifests.sh` reaches `guard_disk` through `render.sh --check`, at 1 GiB. The code always did this | `scripts/render.sh`, `scripts/ci/validate-manifests.sh` |
| 2026-11-04 | 13 | `make rollback` also writes the overlay's `images:` lines, through `git revert`. The code always did this | `scripts/rollback.sh`, `91ef477` |
| 2026-11-06 | 1 to 13 | Hosted production, `plane-prod`, on K3s on the Contabo VPS: its names, namespaces, hosts, owners, delivery, waves, projects, secrets, sizes, make targets and evidence, under a **Hosted production** heading in each section, from the binding hosted design | `infrastructure/hosted/plane-prod/`, `infrastructure/terraform/environments/{prod,prod-host}`, `gitops/clusters/plane-prod/`, `helm/plane/overlays/prod`, `scripts/hosted/`, `policy/hosted.rego` |
| 2026-11-06 | 3 | Nothing sits behind Cloudflare, and DNS is in Vercel. This file said Pass 2 would terminate TLS at Cloudflare, which was not built | `infrastructure/terraform/environments/prod-host/main.tf` |
| 2026-11-06 | 5 | `images.yml` builds plain `linux/amd64` images on `ubuntu-24.04`, and dev runs those bytes under Rosetta | `.github/workflows/images.yml`, `scripts/ci/copy-to-local-registry.sh` |
| 2026-11-06 | 6 | The dump before a migration is Job `plane-prod-predeploy-dump`, a `Sync` hook at wave 1. The hosted design named it `plane-predeploy-dump` | `helm/plane/overlays/prod/predeploy-dump.yaml` |
| 2026-11-07 | 3 | Grafana has a public route at `grafana.bereket.dev`, behind its own login. The hosted design gave no console one, and the owner chose this | `890348e`, `gitops/clusters/plane-prod/platform/monitoring-extras/shared/grafana-route.yaml`, `policy/hosted.rego` |
| 2026-11-07 | 3, 8 | Infisical has a public route at `infisical.bereket.dev`, for its one admin, by the owner's choice. The hosted design gave it none | `929d7a1`, [ADR 0017](adr/0017-infisical-public-route.md), `gitops/clusters/plane-prod/platform/infisical/route.yaml` |
| 2026-11-07 | 3, 4 | Three Certificates, three A records and three CoreDNS rewrites. The hosted design named one of each, for Plane | `gitops/clusters/plane-prod/platform/certificates/`, `infrastructure/terraform/environments/prod-host/main.tf`, `environments/prod/main.tf` |
| 2026-11-07 | 9 | Off the VPS, the encrypted repositories are copied to the Mac by hand. The hosted design's S3-compatible copy is used only when the owner's files for it exist | `scripts/hosted/pull-backups.sh`, `scripts/hosted/backup-dest.sh` |
