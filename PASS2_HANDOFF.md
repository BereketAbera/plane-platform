# Pass 2 handoff: moving the platform to Hetzner Cloud and Cloudflare

This document describes everything needed for the Hetzner migration. It is written for an engineer who did not build Pass 1.

The application is a customized deployment of open-source Plane Community Edition v1.4.3 (AGPL-3.0), under the name Wayline. It is not an original product, and nothing here should present it as one.

Written 2026-11-04, mostly against commit `f733b87`, while Pass 1 was still being integrated and validated. Reconcile it against the final code before use.

**Markers.** `VERIFY` is a claim that needs a runtime result or a check against a current primary source. `MEASURE` is a number that must come from a measurement. Anything about Hetzner or Cloudflare that carries `VERIFY` is from the author's memory and was not checked against current documentation. Treat it as a question to answer, not a fact.

**Nothing cloud exists.** No Hetzner or Cloudflare resource, account, token, or Terraform code has been created. `infrastructure/terraform/environments/{dev,prod}` holds only interface documents.

## Contents

1. [What Pass 1 hands over](#1-what-pass-1-hands-over)
2. [Target topology and how to choose](#2-target-topology-and-how-to-choose)
3. [What carries over unchanged](#3-what-carries-over-unchanged)
4. [What must change, per component](#4-what-must-change-per-component)
5. [Terraform module interfaces](#5-terraform-module-interfaces)
6. [Accounts and credentials the owner must supply](#6-accounts-and-credentials-the-owner-must-supply)
7. [Sizing method](#7-sizing-method)
8. [Security hardening required before real users](#8-security-hardening-required-before-real-users)
9. [AGPL section 13](#9-agpl-section-13)
10. [Cost items to price](#10-cost-items-to-price)
11. [Phased migration plan with verification gates](#11-phased-migration-plan-with-verification-gates)
12. [Open decisions](#12-open-decisions)
13. [Appendix: local values hard-coded in the repository](#13-appendix-local-values-hard-coded-in-the-repository)

Related: [known limitations](docs/known-limitations.md), [Terraform environment contracts](docs/future-hetzner.md), [AGPL compliance](docs/agpl-compliance.md), [platform contract](docs/platform-contract.md).

## 1. What Pass 1 hands over

Pass 1 is one kind node on a laptop, with two Plane namespaces. It is a rehearsal of the delivery and operations model. It is not evidence that the design works on real infrastructure.

| Layer | Pass 1 owner | Created by |
|---|---|---|
| Cluster, node, CNI (kindnet) | kind CLI | `scripts/cluster-up.sh`. Terraform does not create it |
| Registry, pull-through caches, `git://` remote | Docker Compose | `infrastructure/local-services/compose.yaml`. Terraform does not create them |
| Namespaces, ResourceQuota, LimitRange, CoreDNS rewrite, Argo CD release, AppProjects, root Application | Terraform | `infrastructure/terraform/environments/local` |
| Infisical projects, identities, Kubernetes Auth | Terraform, separate root | `infisical/terraform` |
| Everything else in the cluster | Argo CD | `gitops/applications` |
| Secret values | Infisical, with secret zero in `.local/secret-zero/` | Scripts |

Runtime status when this was written:

- The only runtime results are the day-1 gates (digest pulls, kindnet enforcement against a sentinel, `git://` from a pod), captured in [`docs/evidence/day1-gates.txt`](docs/evidence/day1-gates.txt).
- Plane had not been deployed on this cluster, so no application behaviour below is proven. [[VERIFY: docs/validation.md records the final Pass 1 result of make up and make test]]
- Read [`docs/validation.md`](docs/validation.md) for what actually ran before relying on any "carries over" row below.

The reasons a kind result does not transfer are listed in [known limitations](docs/known-limitations.md#what-pass-1-does-not-prove).

## 2. Target topology and how to choose

The requirement is independent dev and prod. Pass 1's two namespaces do not meet it, because namespace separation is not equivalent to independent production clusters. Both namespaces share one API server, etcd, kernel, CoreDNS, Traefik, Argo CD, Infisical, and disk.

### Options

| Option | Blast radius between dev and prod | Operating cost | Verdict |
|---|---|---|---|
| A. One cluster, two namespaces | Shared control plane, nodes, ingress, Argo CD | Lowest | Rejected. It is Pass 1 with public IPs and does not meet the requirement |
| B. Two clusters in one Hetzner project | Separate control planes and nodes. One API token and one firewall scope can reach both | Medium | Acceptable only if tokens cannot be separated, which should be checked first |
| C. Two clusters in two Hetzner projects, one Cloudflare zone | Separate clusters and tokens. The zone and the Git repository are the shared points | Medium | **Recommended starting point** |
| D. C plus a third small operations cluster or host for Infisical and monitoring | As C, plus shared services sit outside both | Highest | Choose only if the Infisical decision (section 4.8) needs it |

Option C depends on Hetzner API tokens being scoped per project. [[VERIFY: Hetzner Cloud API tokens are scoped to a single project]]

### Inside each cluster

| Question | Choose more nodes when | Choose fewer when |
|---|---|---|
| Control plane: 1 or 3 | The environment must survive losing a node without an operator, and you will run etcd properly | The target is an RTO you can meet by restoring from backup. Dev should stay at 1 |
| Workers separate from control plane | Measured load justifies it, or data volumes need isolation from control plane I/O | Measured use fits one server with headroom (section 7) |
| Data services stateful in cluster or managed elsewhere | You accept running HA Postgres (CloudNativePG is the path noted in research, untested here) | A single instance plus tested off-host backups meets the stated RPO and RTO |

Adding nodes does not make Plane highly available. All four data services are single-replica in chart 1.8.6's local setup, and a single-replica Postgres on a block volume is still a single point of failure. State an RPO and RTO first, then pick the node count.

**Recommendation.** Start with one server per environment if the measured sizing fits, and say plainly in the docs that this is not HA. Move prod to three nodes only with a stated availability target. This is a recommendation, not a result. The owner decides (section 12).

```mermaid
flowchart TB
  user["Browser and API clients"] --> cf["Cloudflare edge: DNS, TLS, optional Access"]
  gh["GitHub: public repository and CI"]
  ghcr["GHCR: images by digest"]
  gh --> ghcr

  subgraph devp["Hetzner project: dev"]
    devedge["Tunnel or load balancer"] --> devt["Traefik"]
    devt --> devplane["Plane dev: app and data services"]
    devargo["Argo CD"] --> devt
    devinf["Infisical (see section 4.8)"]
    devmon["Prometheus, Grafana, Loki"]
  end

  subgraph prodp["Hetzner project: prod"]
    prodedge["Tunnel or load balancer"] --> prodt["Traefik"]
    prodt --> prodplane["Plane prod: app and data services"]
    prodargo["Argo CD"] --> prodt
    prodinf["Infisical (see section 4.8)"]
    prodmon["Prometheus, Grafana, Loki"]
  end

  cf --> devedge
  cf --> prodedge
  gh -- "Argo CD polls" --> devargo
  gh -- "Argo CD polls" --> prodargo
  ghcr --> devplane
  ghcr --> prodplane
  devplane -- "encrypted backups" --> devs3["Object storage, dev credentials"]
  prodplane -- "encrypted backups" --> prods3["Object storage, prod credentials"]
  prodmon -- "alerts" --> pager["Real receiver, external dead-man check"]
  devmon -- "alerts" --> pager
```

### Independence test

Treat dev and prod as independent only when all of these hold. Each is a gate in section 11.

- Destroying the dev cluster, its state, and its credentials leaves prod serving. [[VERIFY: prod stays healthy while dev is destroyed]]
- No credential that dev holds can read or change anything in prod. [[VERIFY: dev Hetzner, Infisical, S3, and Argo credentials are refused against prod]]
- No pod in dev has a route to a pod or data service in prod. [[VERIFY: connection from dev to prod node and service addresses fails]]

The Git repository, GHCR, and the Cloudflare account remain shared. That is a deliberate residual dependency, and a Cloudflare token scoped to one zone cannot separate dev from prod records in that zone.

## 3. What carries over unchanged

"Unchanged" means the design and files move as they are. It does not mean they are proven. Runtime behaviour needs the same evidence again on real nodes.

| Item | Files | Why it carries |
|---|---|---|
| Plane release and chart | Contract section 1, `helm/plane/vendor/plane-ce-1.8.6` (byte-identical) | Independent of infrastructure |
| Render and commit | `scripts/render.sh`, `gitops/environments/`, CI render diff | Argo CD syncs plain manifests. No Helm or Kustomize at sync time |
| Sync waves | Contract section 6 | Ordering is a property of the workloads, including the migrator as a `Sync` hook, never `PreSync` |
| Secret contract | Contract section 8 | The six Secrets, hex passwords, `FILE_SIZE_LIMIT` in bytes, bucket `uploads`, never rotating `SECRET_KEY` |
| Workload hardening | `helm/plane/components/hardening` | UIDs, probes, limits, and no service account tokens. Adjust limits only from measurement |
| AppProject model | `gitops/bootstrap/chart/templates/appprojects.yaml` | `platform` holds cluster scope, Plane projects hold namespaced workloads. Namespace lists change (section 4.13) |
| Conftest policy | `policy/` | Still applies to rendered manifests. Host and environment rules need updating |
| CI scripts | `scripts/ci/*`, `.github/workflows/ci.yml` | No cluster access. Runs the same scripts as `make ci` |
| Dashboards and alert rules | `monitoring/manifests/shared` | `NodeFilesystem*` alerts should become meaningful, unlike on kind |
| Backup and restore logic | `scripts/backup.sh`, `scripts/restore.sh` | Dump format, checks, and proofs carry. The destination and how the scripts reach the cluster change (section 4.7) |
| Pinned versions | `tools.lock`, Terraform lock files, image digests | Lock files gain a platform if CI or nodes need one |

## 4. What must change, per component

Appendix 13 lists the exact lines. Paths and line numbers are as of commit `f733b87`.

### 4.1 kind to real nodes

| | Pass 1 | Pass 2 |
|---|---|---|
| Cluster creation | `scripts/cluster-up.sh`, `infrastructure/kind/cluster.yaml.tmpl` | Terraform creates servers, and a chosen distribution creates Kubernetes (open decision D2) |
| Kubernetes | v1.36.4 | Exact version pinned. Check support for the Argo CD line in use before changing it |
| Lifecycle | `make down`, `make up`, `make destroy` | Rewrite. `scripts/down.sh` and `scripts/destroy.sh` assume kind and local state |
| Architecture | arm64 only | Decide (D3). `scripts/ci/build-images.sh` passes `--platform linux/arm64`, and `.github/workflows/images.yml` runs on `ubuntu-24.04-arm` |
| Disk protection | kind disables image GC and eviction (critique section 5) | Kubelet defaults return. Size disks so garbage collection and eviction do not fire in normal use |
| `guard_disk` | Guards the Mac's disk, because the VM cannot see it | Replace with node-level alerts. Keep it for scripts that write to the operator's machine |

Hetzner has no managed Kubernetes offering as far as the author knows. [[VERIFY: whether Hetzner offers managed Kubernetes at migration time]]

`externalTrafficPolicy: Local` in `helm/values/traefik.yaml` is safe today only because there is one node, as its comment says. On more than one node it blackholes traffic to nodes without a Traefik pod unless a load balancer health-checks that node. Change it deliberately.

### 4.2 Storage class and CSI

| Item | Pass 1 | Pass 2 action |
|---|---|---|
| Plane data | `storageClass: standard` in both overlays' `values.yaml`, four lines each | Set the real class before first sync. `volumeClaimTemplates` are immutable |
| Infisical data | `storageClassName: standard` at `infisical/manifests/postgres.yaml:124`, `redis.yaml:112` | Same |
| Prometheus, Alertmanager, Loki | Default class | Name the class explicitly, as the Plane overlays do |
| PVC sizes | `local-path` ignores them. Comments call Loki's `2Gi` "a label" | **Now enforced.** Set real sizes and alert on them. `retentionSize` must stay below volume size |
| Volume permissions | Non-root writes are expected to work because local-path uses mode 0777 | Block volumes will not have 0777 directories. `infisical/manifests/{postgres,redis}.yaml` set `fsGroup`, but `helm/plane/components/hardening` does not, so Plane's non-root Postgres, Valkey, RabbitMQ, and Silo need it added. [[VERIFY: each Plane data service writes to its volume on the chosen CSI]] |
| Scheduling | One node | Block volumes attach to one node in one location. Keep pods and volumes co-located |

The expected driver is the Hetzner Cloud CSI driver, with block volumes as ReadWriteOnce. [[VERIFY: current Hetzner CSI driver name, version, minimum volume size, and arm64 support]]

Compare Postgres on a network block volume with the server's local disk before choosing. [[MEASURE: Postgres write latency on Hetzner volume versus local disk]]

### 4.3 Local registry to a real registry

| Item | Pass 1 | Pass 2 |
|---|---|---|
| Branded images | `localhost:5001/wayline/*` by digest | GHCR by digest. `images.yml` already pushes there |
| Local copy step | `scripts/ci/copy-to-local-registry.sh` | Remove. Digests in Git point straight at GHCR |
| Pull-through caches | `infrastructure/local-services`, `infrastructure/kind/containerd-certs.d` | Remove. Node pulls use real registries |
| Docker Hub limits | Mitigated through `mirror.gcr.io` | Nodes share a public IP, and anonymous limits apply. Decide: authenticated pulls through kubelet config, a mirror in GHCR, or retain `mirror.gcr.io` as a containerd mirror |
| Pull auth | None | Public packages need none. Private packages need `imagePullSecrets` on the `plane` ServiceAccount, sourced from Infisical |
| Digest kind | Index digests for upstream, one plain manifest for branded (`--provenance=false --sbom=false`) | Keep. On x86, branded builds must become multi-arch and digests change |

In the overlays at this commit, Plane images are still `docker.io/makeplane/*`, not Wayline images, and `apps/wayline/` is partial and uncommitted, with no `images.txt`. Contract section 5 states the intended end state. [[VERIFY: branded images are built, pushed, and referenced in helm/plane/overlays/*/kustomization.yaml]]

The GHCR limits noted in `.github/workflows/README.md` apply to a private repository. Public packages are free per `cicd-security.md`. [[VERIFY: current GHCR limits for public and private packages]]

### 4.4 Git daemon to GitHub as Argo's source

**This is not a one-value change, despite what `infrastructure/terraform/modules/argocd/variables.tf` says.** The value `git_repo_url` reaches the root Application and AppProject `sourceRepos`, but 13 child Application files hard-code `git://plane-git/plane-platform.git` (14 lines). If you change only the variable, the projects refuse those children.

| Task | Detail |
|---|---|
| Parameterise children | Render `gitops/applications` from a value, or generate per-cluster files (section 4.13). Pick one and make CI check it |
| Transport | Use HTTPS. The repo-server NetworkPolicy allows 443 to public addresses, not SSH |
| Credentials | None for a public repository. For a private one, a read-only deploy key or GitHub App held outside Git |
| Remove the old path | `plane-git` Compose service, `gitops-publish.sh`, and the `9418` egress rule in `gitops/platform/network-policies/argocd.yaml:124-127` |
| Pre-promotion backup | **Moves.** Today `scripts/gitops-publish.sh:33-38` takes the prod-sim dump before publishing, and that is the only place a promotion merged on GitHub takes one. With GitHub as source, merging deploys directly and the dump does not happen. Contract section 5 requires it. See below |
| Detection delay | Argo CD polls. Decide whether a webhook is worth exposing an endpoint. [[MEASURE: time from merge to sync with polling]] |
| Enforced approval | A public repository on GitHub Free gets protected branches and required reviewers per `cicd-security.md`. [[VERIFY: GitHub plan features for public repositories at migration time]] |

Options for the pre-promotion dump:

| Option | Tradeoff |
|---|---|
| Scheduled backups plus a freshness check in the promotion PR | Simple. The dump is not immediately before the change, so state the gap |
| Argo `PreSync` hook running a backup Job | Immediate, but `PreSync` runs on a fresh install too, when Postgres does not exist. The Job must tolerate that |
| A CI job with cluster credentials | Gives GitHub write access to prod, which Pass 1 avoids on purpose. Not recommended |

### 4.5 NodePort to a load balancer or Cloudflare Tunnel

| | Hetzner load balancer | Cloudflare Tunnel |
|---|---|---|
| Inbound ports on nodes | 80 and 443 from the load balancer | None. `cloudflared` dials out |
| Bypassing Cloudflare | Possible unless the firewall allows only Cloudflare ranges or origin pulls are authenticated | Not possible through a public address, since none is open |
| New in-cluster owner | Cloud controller manager for the Service | `cloudflared` Deployment, its namespace, and its token in Infisical |
| Client IP | Needs PROXY protocol or trusted headers | `CF-Connecting-IP` and trusted forwarded headers from `cloudflared` |
| Failure mode | Depends on Hetzner LB and Cloudflare | Depends on `cloudflared` and Cloudflare |
| Cost | Monthly per load balancer | Check plan terms |

**Recommended starting point: Cloudflare Tunnel**, because it leaves no inbound application port and takes one piece of cloud controller work out of the first iteration. This is the author's judgement, not a test. Whichever is chosen, the same work is required:

- Trust forwarded headers, or uploads get `http://` URLs and Plane's throttle shares one bucket. `SECURE_PROXY_SSL_HEADER` is set in Plane's `settings/production.py`, and presigned URLs use `request.scheme`. Set `ports.web.forwardedHeaders.trustedIPs` in `helm/values/traefik.yaml` to the real proxy source only.
- Rewrite `traefik-ingress` in `gitops/platform/network-policies/traefik.yaml:51-54`. It allows `172.16.0.0/12` and `192.168.65.0/24`, both specific to Docker.
- Decide what happens to the websocket path through `/live`. Cloudflare's WebSocket support was read in its docs, and the behaviour through this stack is unproven. [[VERIFY: /live collaboration holds a WebSocket through Cloudflare, Traefik, and the buffering middleware for a 5 minute soak]]
- Check proxied request size limits against `FILE_SIZE_LIMIT=5242880`. [[VERIFY: Cloudflare request body limit on the chosen plan]]

Tunnel behaviour, client IP header, and pricing are from memory. [[VERIFY: Cloudflare Tunnel current terms, headers, and origin settings]]

### 4.6 Hostnames and TLS

Contract section 3 says Pass 2 terminates at Cloudflare and the origin, so there are two legs:

| Leg | Approach | To verify |
|---|---|---|
| Browser to Cloudflare | Cloudflare certificate | [[VERIFY: certificate coverage for the chosen hostname depth on the plan]] |
| Cloudflare to origin | Tunnel, or origin certificate with strict mode. Never flexible mode | [[VERIFY: origin mode rejects an invalid origin certificate]] |

A two-level name such as `plane.dev.example.com` may fall outside a free universal certificate, which usually covers one wildcard level. [[VERIFY: whether a universal certificate covers two subdomain levels]]

Plane-specific changes:

| Item | Detail |
|---|---|
| Chart TLS | Set `ssl.externalTermination: true` when TLS ends before Traefik. Keep `entryPoints: [web]`. The chart comment warns that the route otherwise never matches. `WEB_URL` then renders as `https://` |
| Cookies | The chart renders `CORS_ALLOWED_ORIGINS` as both `http://` and `https://`, and any `http:` origin drops `Secure` from session and CSRF cookies (`settings/common.py:187`). Override with an exact `https://<host>` through `plane-app-env`, which needs a contract section 8 change. Never use `*` |
| Override order | Research confirmed Secret after ConfigMap for the migrator. [[VERIFY: api and worker envFrom order lets the Secret override CORS_ALLOWED_ORIGINS]] |
| Cookie proof | [[VERIFY: session-id and csrftoken cookies carry Secure on the public host]] |
| Self-dial | See below |
| Public hostname | A public `plane.` hostname uses the upstream name. Decide (D9) with [the trademark position](docs/agpl-compliance.md#trademark-position-not-legal-advice) |

**Self-dial problem.** The API calls `copy_object` and fetches OAuth avatars against its own public host. `settings/storage.py` builds the endpoint from `request.scheme` and `request.get_host()` when `USE_MINIO=1`. In Pass 1, CoreDNS rewrites the host to Traefik and everything is plain HTTP. On HTTPS the same code dials `https://<host>`:

| Option | Effect |
|---|---|
| Allow the API egress to the public host through Cloudflare | Simple, no rewrite. Adds an internet path and hairpin latency. The NetworkPolicy needs an egress rule, which is what Pass 1 denied |
| Keep a CoreDNS rewrite to a Traefik TLS entrypoint | Needs a certificate the pod trusts for the public name. `modules/foundation` writes a kubeadm Corefile, so distribution matters |
| Keep Silo private and use a real object store with `USE_MINIO` unset | The client then uses `AWS_S3_ENDPOINT_URL`. It changes presigned URL behaviour and the `uploads` route. Needs a new read of `settings/storage.py` |

[[VERIFY: asset duplication returns 200 on the public host with the chosen option]]

**Bucket name.** The bucket must stay `uploads` (`bgtasks/export_task.py:68` strips `/uploads` from the domain). If bucket names are global at a hosted store, that name will be taken, which rules out a direct move to one without a Plane patch. [[VERIFY: bucket name uniqueness rules at Hetzner Object Storage and R2]]

Other hosts:

| Host today | Pass 2 |
|---|---|
| `plane.dev.localhost`, `plane.prod-sim.localhost` | Public, each on its own cluster |
| `argocd.localhost`, `grafana.localhost`, `infisical.localhost` | Not anonymous. Behind Cloudflare Access or a VPN. Each has its own login, which is not a reason to expose it |
| `prometheus.localhost`, `alertmanager.localhost` | **No login of their own**, as `monitoring/manifests/shared/ingress-routes.yaml` says. Never public without an auth layer |

Cloudflare Access availability and limits are from memory. [[VERIFY: Cloudflare Access plan terms for the number of operators]]

### 4.7 Backups to off-host object storage

Pass 1 writes to `.local/backups` on the laptop through `/backups`, a static hostPath PV per environment (`gitops/platform/backup-storage`). That is the same disk as the cluster. It protects against a deleted cluster, not a lost machine.

| Task | Detail |
|---|---|
| Destination | S3-compatible object storage in a different failure domain from the servers. Per-environment bucket and credentials |
| Mechanism | Replace the hostPath PV and PVC. The Job keeps `pg_dump -Fc`, the scratch-database restore check, and the rclone check, then uploads |
| Encryption | Client-side, before upload. `scripts/backup.sh` notes that dumps hold password hashes and plaintext API tokens. Keep the key out of the same bucket |
| Schedule | **Pass 1 has no CronJob.** `make backup` is manual. Add a schedule and an alert on backup age |
| Retention | `KEEP` defaults to 3 for dev and 5 otherwise, local only. Use lifecycle rules as well, and decide on object lock |
| Key escrow | `ENCRYPTION_KEY` and `SECRET_KEY` must be recoverable without the cluster. The manifest stores only truncated hashes on purpose |
| Quota | `persistentvolumeclaims` in `modules/foundation/main.tf` counts the backup PVC. Adjust if it goes |
| Volume snapshots | Useful as a second layer, not a substitute. They share the provider and are crash-consistent only |
| Restore | `scripts/restore.sh` uses local paths and `http://infisical.localhost` (`:664`). Rewrite both |

[[MEASURE: backup duration and size per environment]]

[[MEASURE: restore duration to a fresh cluster, as the RTO input]]

[[VERIFY: a backup restored into a newly created cluster passes tests/e2e/smoke.py]]

### 4.8 Infisical hosting and secret zero

Each environment has its own Infisical project in Pass 1, on one shared instance. Independent environments force a choice:

| Option | Independence | Cost | Note |
|---|---|---|---|
| One instance per cluster | Strongest. Each cluster's secrets die with it, so backups matter | Memory on each, estimate 610 to 990 MiB, summed from `infisical.md` rows in critique section 4 | **Recommended default.** Same chart path as Pass 1 |
| One instance on a separate operations host | Environments share a secret store, which is a shared failure and shared compromise | A third server | Requires Kubernetes Auth to reach each API server across networks, which widens API exposure |
| Hosted Infisical | Hands custody to a vendor | Plan pricing | The free tier's limits on hosted differ from the self-hosted limits. [[VERIFY: hosted Infisical limits and plan cost]] |

Limits to keep in mind for self-hosted, read in source at v0.167.6: no custom roles or RBAC, no native rotation, zero audit log retention. Per-project isolation with built-in `viewer` is the free-tier boundary, and `scripts/rotate.sh` is a demonstration script, not a rotation system.

Required changes:

| Item | Detail |
|---|---|
| Secret zero custody | `.local/secret-zero/` on a laptop does not work for two independent environments. Store `ENCRYPTION_KEY`, `AUTH_SECRET`, and DB passwords in a password manager or offline escrow, per environment. **Losing `ENCRYPTION_KEY` with the cluster makes every secret unrecoverable** |
| Bootstrap path | `scripts/infisical-bootstrap.sh` needs `http://infisical.localhost` from the operator's machine, and it keeps the admin token off the cluster. Keep that property, using a tunnel or port-forward |
| `ALLOW_INTERNAL_IP_CONNECTIONS=true` | `helm/values/infisical.yaml:44` relaxes SSRF protection globally, accepted only because the instance is single-user. Re-decide. With a private API server address the flag may still be needed |
| `SITE_URL` | `http://infisical.localhost` at `helm/values/infisical.yaml:47` |
| Kubernetes Auth | `kubernetes_host` and CA in `infisical/terraform/variables.tf`. A new cluster has a new CA, so rerun |
| Terraform state | `.local/terraform/infisical`. Holds IDs. Move to remote state with the rest. `*_wo` attributes and scripts keep values out, which should stay true |
| etcd at rest | `kind` etcd is unencrypted. Enable encryption at rest for Kubernetes Secrets. [[VERIFY: etcd encryption is on, using a read of a Secret directly from etcd]] |
| Backups | `scripts/backup.sh infisical` exists, and its destination moves with section 4.7 |

### 4.9 NetworkPolicy under a real CNI

Kindnet enforces policy after DNAT and before SNAT, fails open on setup errors, and exempts root sockets in the node's namespace (critique section 1.6). None of those details transfer. The policies were written against them, so expect failures rather than assume compatibility.

| Assumption in `gitops/platform/network-policies` | Under a real CNI |
|---|---|
| `172.16.0.0/12` is the node network (`traefik.yaml:3-10`, 15 `ipBlock` rules across files) | Replace with the node or private network CIDR. On Hetzner that range may overlap nothing, or everything, depending on the network you create |
| `192.168.65.0/24` is Docker Desktop's VM subnet | Remove |
| API server is reached as node IP on 6443 by `ipBlock` | Cilium does not apply CIDR rules to cluster nodes by default, and uses entities such as `kube-apiserver`. Standard `NetworkPolicy` may not express this. [[VERIFY: how Cilium treats ipBlock for the API server and node IPs in the chosen mode]] |
| NodePort source survives to Traefik | Differs with kube-proxy replacement and tunnel. Retest |
| `except: [10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16]` on repo-server egress | Still sound if Hetzner private networks use those ranges. Confirm hosts resolve outside them |
| Kubelet probes bypass policy | CNI-specific. Probes may need host or `remote-node` rules. [[VERIFY: probes pass under default-deny on the chosen CNI]] |

Test tooling is kindnet-specific too. `scripts/test-netpol.sh:177-183` checks `ds/kindnet`, its log line, and nftables tables through `docker exec`. Rewrite those checks. The matrix in `tests/network-policy-matrix.yaml` should run again unchanged except for hosts.

| CNI question | Note |
|---|---|
| Cilium vs. Calico | Research sized Cilium's agent at 300 to 500 MiB as a planning estimate, from a third-party 150 to 250 MB figure and reports at other scales. Calico was not assessed further |
| Fail-closed behaviour | Confirm what happens when the agent is down. [[VERIFY: behaviour of existing pods and new connections when the CNI agent is stopped]] |
| Kernel | [[VERIFY: chosen OS image and kernel meet the CNI's requirements]] |

The known cross-environment gap in Pass 1, an API asking Traefik for the other environment's hostname, goes away with separate clusters.

### 4.10 Monitoring retention

| Setting | Pass 1 | Pass 2 |
|---|---|---|
| Prometheus | `retention: 3d`, `retentionSize: 1GiB`, 2Gi PVC (`helm/values/kube-prometheus-stack.yaml`) | Pick from need, for example weeks in prod. Volume size is now enforced. [[MEASURE: Prometheus bytes per day per cluster]] |
| Loki | `retention_period: 72h`, filesystem, 2Gi, 640Mi limit (`helm/values/loki.yaml`) | Object storage backend if retained longer. [[MEASURE: Loki bytes per day per cluster]] |
| Alertmanager | 24h | Longer, on a real volume, to keep silences |
| Grafana | No persistence, state from Git | Keep. The password regenerates on each render, per `monitoring/README.md`, so manage it from Infisical or SSO |
| Log collection | Alloy as a Deployment through the API (`loki.source.kubernetes`) | Re-evaluate on many nodes. Clustering or a DaemonSet may be needed |
| Host metrics | node-exporter in `monitoring-agents` | Now reports real disks. Add alerts on volume fill |

Monitoring in each cluster fails with that cluster. An outside check is required (section 4.11).

### 4.11 Alert routing to real receivers

Pass 1 routes every alert to an in-cluster webhook, `alert-sink`, which prints lines. Nobody is paged.

| Task | Detail |
|---|---|
| Receivers | Replace `receivers` in `helm/values/kube-prometheus-stack.yaml:171-178`. Choose one per severity (D7). Remove `alert-sink` from prod |
| Credentials | Webhook URLs and keys are secrets. They must not be in values in a public repository. Use an Infisical-managed Secret referenced by Alertmanager |
| Watchdog | Route it to an external dead-man service, so a dead cluster raises an alert from outside. Pass 1 only logs it |
| Egress | The `alertmanager` policy in `gitops/platform/network-policies/monitoring.yaml` allows egress only to `alert-sink` on 8080, and has no DNS rule of its own in that block. Add a specific rule for the real receiver |
| Proof | `scripts/test-alert.sh` asserts on the sink. Rewrite to assert delivery. [[VERIFY: an injected failure reaches a person within the stated time]] |
| Noise | [[VERIFY: alert rules are quiet on a healthy cluster for 24 hours]] |

### 4.12 Plane application settings for real use

| Item | Pass 1 | Pass 2 |
|---|---|---|
| Email | No SMTP config and no egress rule. Password reset and invitations cannot send | Provide SMTP in Infisical and an egress rule. `EMAIL_FROM` defaults to Plane's own address, so replace it |
| Signup | Default | Set `ENABLE_SIGNUP` to match the audience |
| Telemetry | Off through `tests/e2e/smoke.py` and denied by NetworkPolicy | Keep off at admin creation. A hand-made admin gets telemetry on, because the form's parameter at `setup-form.tsx:67` is always true, so egress denial is the backstop. Also keep it denied after adding SMTP egress |
| `enable_drf_spectacular` | On in dev, off in prod-sim | Off wherever public |
| Terms, privacy | None | The owner must supply them if others use it |

### 4.13 Environments: `prod-sim` to `prod`, and split by cluster

Pass 1 assumes both environments in one cluster. `git grep` finds `prod-sim` in 52 tracked files outside docs and rendered manifests.

| Item | Change |
|---|---|
| `modules/foundation/main.tf` | Hard-codes both Plane namespaces, and `coredns_rewrites` is its only variable. Add a variable selecting the environment |
| `gitops/applications/` | Holds both environments' Applications, and the root Application syncs that path (`root-application.yaml:13`). Each cluster needs its own set. A per-cluster directory, such as `gitops/clusters/{dev,prod}/`, is a proposal |
| `gitops/bootstrap/chart/templates/appprojects.yaml` | Declares both projects. Render one per cluster |
| `gitops/platform/network-policies/` | Includes both Plane namespaces and `plane-dev-loadtest.yaml` |
| `gitops/platform/backup-storage/`, `infisical-operator-*` | Same |
| `infisical/terraform/main.tf` | Local map has both environments, and slug `prod` is inside each project already. Run one root per instance |
| Naming | Rename `prod-sim` to `prod` as one reviewed change. Namespace rename means new PVCs, so do it before any data exists |
| Promotion | `scripts/promote.sh` compares overlays in one repository, which does not depend on the cluster, since Git is the source. The dev digest record is still the rule |
| Scripts | `monitoring/ops/lib.sh:17-18`, `tests/e2e/smoke.py:38`, `scripts/status.sh:25`, `scripts/rotate.sh:58` hard-code hosts and context |

## 5. Terraform module interfaces

These are expected interfaces, not code. Root-level contracts, state, and acceptance tests are in [docs/future-hetzner.md](docs/future-hetzner.md). Provider versions seen in `infra-versions.md` were `hetznercloud/hcloud` 1.70.2 and `cloudflare/cloudflare` 5.28.1 in October 2026. Pin exact versions at the time of work. [[VERIFY: latest stable provider versions and that the resources below exist]]

### `modules/hetzner-network`

| Direction | Name | Type | Notes |
|---|---|---|---|
| Input | `name_prefix` | string | Includes the environment |
| Input | `location` | string | |
| Input | `network_cidr`, `subnet_cidr` | string | Must not overlap the pod or Service CIDR |
| Input | `admin_cidrs` | list(string) | No default, so it cannot silently be open |
| Input | `allow_inbound_http` | bool | False with Tunnel |
| Output | `network_id`, `firewall_id` | string | |
| Output | `node_cidr` | string | Replaces `172.16.0.0/12` in NetworkPolicies |

### `modules/hetzner-cluster`

| Direction | Name | Type | Notes |
|---|---|---|---|
| Input | `name_prefix`, `location`, `network_id`, `firewall_id` | string | |
| Input | `control_plane_count`, `worker_count` | number | Default from the sizing method, not memory |
| Input | `control_plane_server_type`, `worker_server_type` | string | Validated against measured need |
| Input | `image` | string | Pinned OS image |
| Input | `kubernetes_version` | string | Exact |
| Input | `ssh_public_keys` | list(string) | Public keys only |
| Output | `kubeconfig` | string, sensitive | See the state warning in `docs/future-hetzner.md` |
| Output | `kube_context` | string | Same name `environments/local` takes |
| Output | `node_ipv4`, `node_private_ipv4` | list(string) | |
| Output | `api_server_endpoint`, `cluster_ca_certificate` | string | The CA feeds `infisical/terraform` |
| Output | `storage_class_name` | string | Feeds overlay values |

The module may install the CCM, CSI, and CNI, or leave them to Argo CD. Contract section 4 allows only one owner. Anything needed before Argo CD can run (CNI) belongs here. CSI and CCM can go either way, and the choice must be recorded. [[VERIFY: Hetzner CCM and CSI install method and required token scopes]]

### `modules/hetzner-object-storage`

The Hetzner provider may not manage S3 buckets, in which case this module uses an S3-compatible provider with separate S3 credentials. [[VERIFY: how Hetzner Object Storage buckets and scoped keys are created through Terraform]]

| Direction | Name | Type | Notes |
|---|---|---|---|
| Input | `bucket_name`, `location` | string | |
| Input | `retention_days` | number | Lifecycle rule. Object lock is a decision |
| Output | `s3_endpoint`, `bucket` | string | Credentials go to Infisical by script, never to state or outputs |

### `modules/cloudflare-edge`

| Direction | Name | Type | Notes |
|---|---|---|---|
| Input | `zone_id` | string | |
| Input | `public_hostnames` | map(string) | Host to origin service |
| Input | `origin_mode` | string | `tunnel` or `load_balancer`. No flexible TLS |
| Input | `origin_ipv4` | list(string) | `load_balancer` only |
| Input | `access_protected_hostnames` | list(string) | Argo CD, Grafana, Prometheus, Alertmanager, Infisical |
| Input | `access_allowed_emails` | list(string) | |
| Output | `tunnel_id` | string | `tunnel` only |

The tunnel token must not be stored as an output or in state if avoidable. Generate it out of band and write it to Infisical by script. [[VERIFY: whether the Cloudflare provider can create a tunnel without keeping its secret in state]]

### Existing modules

| Module | Needed change |
|---|---|
| `modules/foundation` | Add an input selecting environments. Keep `coredns_rewrites` empty unless section 4.6's rewrite option is chosen. Its template is the kubeadm Corefile, and it overwrites a different distribution's config |
| `modules/argocd` | Input `values_file` already exists, so give each cluster its own values file. Add an input for the root path. Fix the variable description that claims one value is enough |

## 6. Accounts and credentials the owner must supply

No values belong in Git or chat. Every token below should be created with the narrowest scope available.

| Item | Purpose | Scope | Where it lives |
|---|---|---|---|
| Hetzner Cloud account, billing | Owner only | | |
| Hetzner project per environment | Blast radius | | |
| Hetzner API token per project | Terraform, CCM, CSI. Ideally separate tokens for Terraform and in-cluster use | Read and write, one project | `TF_VAR_hcloud_token` at runtime, password manager, Infisical for the in-cluster one |
| Hetzner Object Storage keys per environment | Terraform state, backups | One bucket each if scoping allows | Environment at runtime, Infisical |
| SSH key pair(s) | Node admin | Public key in Terraform | Private key on the operator's machine |
| `admin_cidrs` values | Firewall | | Variable, not secret, may be sensitive to publish |
| Domain, and Cloudflare account with the zone | DNS, TLS, Tunnel, Access | | |
| Cloudflare API token | Terraform | DNS and Tunnel for one zone and account | `TF_VAR_cloudflare_api_token` at runtime |
| GitHub repository settings | Public visibility, branch protection, Actions PR permission | Owner | GitHub |
| Docker Hub account and token, if authenticated pulls are chosen | Pull quota | Read-only | Infisical, kubelet config |
| Alert receiver accounts | Alerts, dead-man check | One integration each | Infisical |
| SMTP provider | Plane email | Send only | Infisical |
| Off-machine escrow for `ENCRYPTION_KEY`, `SECRET_KEY`, backup encryption key | Disaster recovery | One per environment | Password manager or offline |
| Legal review | AGPL, trademark, terms, privacy | | Owner's counsel |

## 7. Sizing method

Do not pick a server type from this document or from memory. Derive it from measurements on Pass 1, then re-measure on the target. Measurements on an arm64 Docker Desktop VM do not transfer exactly, particularly to x86, so the first Pass 2 cluster should be easy to resize.

### Inputs

Collect from [docs/resource-utilization.md](docs/resource-utilization.md), which holds results from `make status` and `make test-load`:

| Input | Source | Marker |
|---|---|---|
| Idle working set per workload | `kubectl top`, Prometheus `container_memory_working_set_bytes` | [[MEASURE: idle working set per pod]] |
| Peak working set per workload during first boot and load | Prometheus `max_over_time` over the run | [[MEASURE: peak working set per pod]] |
| CPU p95 per workload under load | `tests/load/run.sh` samples | [[MEASURE: CPU p95 per pod under load]] |
| Image store size on the node | Node disk, per architecture | [[MEASURE: image filesystem usage on the node]] |
| Data growth per day | PV usage over time | [[MEASURE: PV growth per day per service]] |
| Load the target must carry | Owner's expectation of users | Open decision D8 |

### Method

For each cluster, using only what that cluster runs:

```text
memory_needed = sum(peak working set of workloads, not limits)
              + node_overhead (kubelet, containerd, CNI, CSI, CCM, OS)
              + largest concurrent burst (migrator, backup Job, repo-server render)

memory_required = memory_needed / target_utilization

cpu_required    = sum(p95 CPU at target load) / target_utilization

disk_required   = images + PV totals at chosen retention + container logs + free space
                  needed to keep kubelet GC and eviction thresholds from firing
```

- `target_utilization` is the owner's judgement. 0.7 is a reasonable starting value because it leaves room for a rollout surge, and it has no measurement behind it.
- Then check limits against the node. Pass 1's limits are deliberately overcommitted, at about 107% of the VM by the critique's estimate. Decide whether that remains acceptable when a real user is affected by an OOM kill.
- `ResourceQuota` in `modules/foundation/main.tf` computes one surge pod per Deployment. Keep that when adjusting limits.
- With more than one node, add the failure case: the remaining nodes must hold the workloads, or state that they will not.
- Pick the smallest server type that meets all three, and record prices and specs from the current Hetzner page on the same day.

### Starting estimate

This is an estimate for sanity checking, not a result.

| Group, one cluster with one Plane environment and its own Infisical | Idle MiB, estimate |
|---|---:|
| Plane, one environment | 1,240 to 2,080 |
| Control plane and node agents | 750 to 1,300 |
| Container shims and pause, about 42 pods at 5 to 10 MiB | 210 to 420 |
| Traefik, metrics-server | 80 to 150 |
| Argo CD | 450 to 700 |
| Prometheus, Alertmanager, Grafana, operators | 620 to 1,040 |
| Loki, Alloy | 250 to 500 |
| Exporters, half of the two-environment figure | 25 |
| Infisical with its Postgres and Redis, one operator | 610 to 990 |
| CNI agent (Cilium planning guess from `cicd-security.md`) | 300 to 500 |
| **Total** | **4,535 to 7,705, about 4.4 to 7.5 GiB** |

Derived by taking one environment's rows from critique section 4, scaling per-pod overhead to one cluster, and adding the CNI guess. Control plane numbers came from a kind node and will differ by distribution. The critique's rows are themselves estimates anchored on a few measurements of related software on this host and one third-party figure for Plane v1.4.2. No Plane container had run when they were written. Replace all of this with measurement.

## 8. Security hardening required before real users

Pass 1 makes no claim of production readiness, and neither does this document. All of these are required, not suggested, before anyone other than the owner uses an instance.

| Area | Requirement | Pass 1 state |
|---|---|---|
| Source offer | Section 9 complete | Private repository, no `/source` route yet |
| Exposure | No anonymous admin UI. Prometheus and Alertmanager behind auth | Loopback only, no auth |
| TLS | HTTPS only, `Secure` cookies, HSTS at the edge | None |
| Origin | No direct origin path, or firewall limited to the edge | Not applicable |
| Node access | SSH key only, `admin_cidrs` set, API server not public | Not applicable |
| OS | Unattended security updates, a reboot plan | Docker Desktop VM |
| Kubernetes | etcd encryption at rest, audit logging on, supported version with a patch cadence | Neither |
| Pod Security | Move `enforce` from `baseline` to `restricted` per namespace after a per-workload test, except node-exporter | `baseline`, `restricted` as warn and audit |
| Workloads | Read-only root where possible. `KSV-0014` in `.trivyignore` expires 2027-02-01 | Not read-only |
| Secrets | Secret zero in escrow, Argo CD initial admin removed, Grafana password managed | Local files, generated passwords |
| Database | A non-superuser Plane role. `scripts/rotate.sh` notes the role is a shared superuser | Superuser |
| Argo CD | SSO or named accounts, RBAC, `server.insecure` reviewed | Admin only |
| Infisical | Re-decide `ALLOW_INTERNAL_IP_CONNECTIONS`, confirm cross-project denial | [[VERIFY: runtime cross-project 403 evidence]] |
| Network | Default-deny re-proven on the real CNI, fail-closed behaviour known, egress minimal | Design only. [[VERIFY: tests/network-policy-matrix.yaml result on the real CNI]] |
| Images | Scan gate that blocks. Sign images if the repository is public, since attestations become available | Scans in CI |
| Accepted risks | RabbitMQ 3.13 is out of community support. Re-decide. 4.2.9 is the candidate, 4.3 breaks Celery per upstream | Accepted for Pass 1 |
| Git | Clean `gitleaks` history before going public, branch protection with required review | Advisory only on GitHub Free private |
| Terraform | Remote encrypted state with separate keys per environment, lock tested | Local state |
| Backups | Encrypted, off-host, restore proven, alert on age | Manual, local |
| Abuse and privacy | Rate limits work with true client IP, an operator contact, terms, privacy, retention, and data location reviewed | None |
| Rollback | Rollback and restore drills repeated on real infrastructure | [[VERIFY: tests/drills results on Hetzner dev]] |

## 9. AGPL section 13

Read [docs/agpl-compliance.md](docs/agpl-compliance.md). This summary is engineering guidance, not legal advice.

- A modified version must offer its Corresponding Source to all users who interact with it over a network, at no charge. Patched branded images are modified versions.
- **The repository must be public, or source otherwise offered, before anyone other than the owner uses the instance.** `origin` is private today. A `/source` link to a private repository offers nothing to someone without access.
- Corresponding Source includes the pinned upstream ref, patches, overlay, codemod, build scripts, and Dockerfiles, not only application code.
- `/source` must lead to the exact commit of the running build. Automate the value at build time. [[VERIFY: /source resolves to the commit of the deployed digest, from a logged-out browser, on each surface]]
- Before the first outside user: pass the checklist in [docs/agpl-compliance.md](docs/agpl-compliance.md#checklist-before-the-first-other-user), including the `email.py` header decision and repository `LICENSE` and `NOTICE` files, which do not exist yet.

## 10. Cost items to price

No prices appear here on purpose. Check them on the provider's current pricing page on the day of the decision, and record date and region.

| Provider | Item | Unit to check |
|---|---|---|
| Hetzner | Servers, per type and architecture, per environment | Hourly and monthly cap |
| Hetzner | Block volumes | Per GiB per month |
| Hetzner | Primary IPv4 addresses | Per IP |
| Hetzner | Load balancers, if chosen | Per load balancer |
| Hetzner | Traffic allowance and overage | Per server, per TB |
| Hetzner | Object Storage | Base fee, storage, egress |
| Hetzner | Snapshots and backups, if enabled | Per GiB or percentage |
| Cloudflare | Domain registration or transfer | Per year |
| Cloudflare | Plan for the zone | Monthly |
| Cloudflare | Access seats, if beyond the free allowance | Per user |
| Cloudflare | R2, if used | Storage and operations |
| GitHub | Actions minutes on arm64 runners, Packages | Public versus private |
| Other | Docker Hub plan if authenticated pulls are needed | Monthly |
| Other | SMTP provider, alert receiver, dead-man service | Monthly |
| Other | Legal review | One-off |

Run dev and prod sizes through the sizing method first, so the price is for a measured need.

## 11. Phased migration plan with verification gates

Each phase has one exit gate. Do not start the next phase until evidence for the gate is in `docs/evidence/`, labelled PASS, FAIL, BLOCKED, or NOT RUN, per contract section 12. kind keeps working throughout, which makes it the rollback for every phase up to 3.

| Phase | Work | Exit gate |
|---|---|---|
| 0. Close Pass 1 | Finish validation, resolve markers, measure resources | `docs/validation.md` complete. `docs/resource-utilization.md` has measured values. Every BLOCKED item has a Pass 2 decision |
| 1. Remove hard-coding, on kind | Parameterise repo URL, hostnames, storage class, per-cluster Applications, foundation environments, CNI-specific tests. Everything stays on kind | `make up` then `make test` on kind give the same results as Phase 0. `make render` diff contains only intended lines |
| 2. Public source | Clean history, `LICENSE`, `NOTICE`, working `/source`, go public, public GHCR, protect `main`. Point kind's Argo CD at GitHub | `gitleaks` clean over full history. Kind syncs from GitHub. A logged-out browser reaches the exact commit's source |
| 3. Accounts and state | Owner supplies section 6 items. State buckets created | `terraform init` on each root, against real state. Two concurrent plans prove locking |
| 4. Dev infrastructure | Network, firewall, servers, Kubernetes, CNI, CSI | Nodes Ready. Policy sentinel: default-deny blocks and allow admits on a new connection. PVC survives pod move and node reboot. Digest pull from each registry path. External port scan shows only intended ports |
| 5. Dev platform | `modules/foundation`, `modules/argocd`, root Application, Infisical, secrets | All Applications Synced and Healthy. `tests/network-policy-matrix.yaml` executed with zero unexpected results. Cross-project 403 proven |
| 6. Dev edge | Cloudflare, TLS, forwarded headers, cookies, self-dial decision | `tests/e2e/smoke.py` on the public host, including upload, export, asset duplicate, and WebSocket soak. Cookies carry `Secure`. Origin refuses direct access. Client IP in logs is the real one |
| 7. Dev operations | Off-host backups, schedule, real receivers, dead-man | Backup restored into a **new** cluster and smoke tested. Injected failure reaches a person. Stopping the cluster triggers the dead-man. Rollback and failed-deploy drills executed |
| 8. Prod cluster | Repeat 4 to 7 with prod inputs, from a promotion PR with required review | Same gates, plus the independence test in section 2 |
| 9. Before first user | Load test at target, section 8 list, AGPL checklist, legal review | Every section 8 row resolved or accepted in writing by the owner. Measured numbers in the docs. No statement of production readiness without evidence for it |

Local data is test data, so the default is to start both clouds empty rather than migrate. If data must move, use `scripts/backup.sh` and `scripts/restore.sh`, keep `SECRET_KEY` the same, and expect encrypted config rows to decrypt silently to empty if it differs.

Reversal: phases 4 to 8 are `terraform destroy` plus restoring from off-host backups. Add `prevent_destroy` or a similar guard to prod volumes once data exists, and never point a dev credential at prod state.

## 12. Open decisions

Each needs an owner decision before the phase shown. Recommendations are the author's judgement, with no test behind them.

| # | Decision | Options | Recommendation | Needed by phase |
|---|---|---|---|---|
| D1 | Topology | Section 2, options B to D | C: two clusters, two projects | 3 |
| D2 | Kubernetes distribution | kubeadm, k3s, Talos, a community Terraform module | Choose after checking the CCM, CSI, and Cilium fit. kubeadm is closest to what `modules/foundation` assumes. No preference is proven | 4 |
| D3 | Architecture | arm64 (matches Pass 1 measurements and build), x86 (needs multi-arch builds) | arm64 if available in the chosen location. [[VERIFY: arm64 server availability by Hetzner location]] | 1 |
| D4 | Ingress | Tunnel or load balancer | Tunnel | 4 |
| D5 | Infisical | Per cluster, separate host, hosted | Per cluster | 5 |
| D6 | Data services | In-cluster single instance, CloudNativePG, external store | Single instance with tested off-host backups, plus a stated RPO and RTO | 5 |
| D7 | Alert receivers | Owner's choice of email, chat, or pager | One real channel plus an external dead-man | 7 |
| D8 | Target load and availability | Users, RPO, RTO | Owner must state these. The sizing method and D1 depend on them | 3 |
| D9 | Public hostname and name | `plane.` vs. a Wayline-named host | Wayline-named host, since the upstream name is not licensed for branding | 2 |
| D10 | Repository visibility | Public, or a separate source offer | Public | 2 |
| D11 | Object storage for uploads | Silo in cluster, external S3 | Silo first, since `uploads` is constrained by Plane code | 6 |
| D12 | `email.py` header | Leave as shipped, or apply upstream's change | Take legal advice. See [docs/agpl-compliance.md](docs/agpl-compliance.md#the-commercial-header-in-emailpy) | 2 |
| D13 | Plane version at migration | Stay on v1.4.3 or upgrade first | Stay. Change one thing at a time. Security fixes may override this | 1 |
| D14 | Hosted location and privacy | Hetzner location, data residency | Owner's decision, with legal input if real user data is held | 3 |

## 13. Appendix: local values hard-coded in the repository

Read at commit `f733b87`. Regenerate before Phase 1:

```bash
git grep -n -E 'localhost|plane-git|prod-sim|172\.16\.0\.0|192\.168\.65|storageClass|kind-plane-platform' \
  -- ':!docs' ':!gitops/environments' ':!helm/plane/vendor' ':!PASS2_HANDOFF.md'
```

| Value | Where |
|---|---|
| `git://plane-git/plane-platform.git` | 13 files in `gitops/applications/`, 14 lines. Default in `environments/local/variables.tf`, `gitops/bootstrap/chart/values.yaml` |
| Hostnames | `helm/plane/overlays/{dev,prod-sim}/values.yaml:4`, `helm/values/argocd.yaml:6,18`, `helm/values/infisical.yaml:47`, `helm/values/kube-prometheus-stack.yaml:109,144,203`, `gitops/bootstrap/argocd-route/ingressroute.yaml:17`, `infisical/manifests/ingressroute.yaml:16`, `monitoring/manifests/shared/ingress-routes.yaml:10,22,34`, `monitoring/manifests/environments/{dev,prod-sim}/kustomization.yaml`, `infisical/terraform/variables.tf`, `infrastructure/terraform/environments/local/main.tf` |
| Hostnames in tooling | `monitoring/ops/lib.sh:17-18`, `tests/e2e/smoke.py:38,921`, `scripts/status.sh:25`, `scripts/rotate.sh:58`, `scripts/restore.sh:664`, `scripts/logs.sh:10`, `tests/network-policy-matrix.yaml` |
| Entry point `web`, plain HTTP | `helm/plane/overlays/*/values.yaml`, all IngressRoutes above, `helm/values/argocd.yaml:89` (`server.insecure`) |
| `standard` storage class | `helm/plane/overlays/*/values.yaml:37-43`, `infisical/manifests/postgres.yaml:124`, `infisical/manifests/redis.yaml:112` |
| Docker network CIDRs | `gitops/platform/network-policies/*.yaml`, `scripts/cluster-up.sh:43-44` |
| `/backups` hostPath | `gitops/platform/backup-storage/*.yaml`, `infrastructure/kind/cluster.yaml.tmpl` |
| `localhost:5001` | `scripts/promote.sh`, `scripts/ci/copy-to-local-registry.sh`, `Makefile` (`images` target) |
| arm64 only | `scripts/ci/build-images.sh`, `.github/workflows/images.yml` |
| Kindnet checks | `scripts/test-netpol.sh:177-183`, `tests/gates/day1.sh` |
| Alert sink | `helm/values/kube-prometheus-stack.yaml:171-178`, `monitoring/manifests/shared/alert-sink.yaml`, `scripts/test-alert.sh` |
| Local Terraform state | `infrastructure/terraform/environments/local/versions.tf`, `infisical/terraform/versions.tf` |
