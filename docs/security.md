# Security

The security posture of a local, single-node, single-operator platform that runs Wayline, a customized Plane Community Edition v1.4.3 deployment, on kind. This is a learning and portfolio platform. Nothing here is a claim of production readiness.

**Status.** This file describes configuration. `docs/evidence/` holds no security result yet. A day-1 gate run exists in raw form at `.local/evidence-raw/day1-gates-2.txt`, covering digest pulls and a basic kindnet default-deny. None of the platform's own NetworkPolicies were loaded in that run. Static checks have run during development, but their output is not in `docs/evidence/` either. Each runtime-dependent statement carries a `[[VERIFY: ...]]` marker.

## Read this first

**Namespace separation is not equivalent to independent production clusters.** `plane-dev` and `plane-prod-sim` share one API server, one etcd, one node, one kernel, one container runtime, one Traefik, one Argo CD, one Infisical, one Prometheus, and one Docker VM. A kernel or runtime escape, a cluster-admin mistake, a noisy neighbour that exhausts the node, or a Docker VM disk failure affects both. "prod-sim" means a production simulation of process and configuration. It provides no production isolation. Independent environments arrive only in Pass 2, on separate infrastructure. See [future-hetzner.md](future-hetzner.md).

**GitHub approval here is a process, not a control.** See [GitHub Free limits](#github-free-limits).

## Threat model

### What is worth protecting

| Asset | Where | Why it matters |
|---|---|---|
| `ENCRYPTION_KEY` and other secret zero | `.local/secret-zero/`, Secret `infisical-secrets` | Decrypts every stored secret |
| Infisical admin token | `.local/secret-zero/infisical-admin.json` | Reads and writes every secret, capped at 90 days |
| Plane secret values | Infisical, then Kubernetes Secrets in etcd | Database, broker and object store access |
| Plane `SECRET_KEY` | Same | Binds encrypted config rows to their database |
| Cluster-admin kubeconfig | `.local/kubeconfig` | Everything in the cluster |
| Backups | `.local/backups/` | Password hashes and **plaintext API tokens**, not encrypted |
| Deployment source | `.local/git/plane-platform.git` | Whatever is on `main` there, Argo CD deploys |

### Who the design considers

| Actor | In scope | How the design responds |
|---|---|---|
| A compromised workload in one environment trying to reach the other, or Infisical | Yes | NetworkPolicy, per-environment identity, no API tokens in pods, non-root, dropped capabilities |
| A mistake by the operator | Yes | Guards on `destroy`, `restore`, `rotate` and prod-sim promotion. Git as source of truth |
| A secret committed to Git | Yes | gitleaks in `make ci` and CI, zero `kind: Secret` rule |
| A malicious or hijacked CI dependency | Partly | SHA-pinned actions, no secrets in CI jobs, read-only tokens, no cluster access from CI |
| Another device on the LAN | Yes | Host ports bind to `127.0.0.1` only. [[VERIFY: lsof on the host shows ports 80, 443 and 5001 listening on loopback only]] |
| A malicious process running as the same macOS user | **No** | It can read `.local/` and own everything. Nothing here defends against it |
| Physical theft of the laptop | **No** | Depends on full-disk encryption, which this repository does not check |
| A container escape to the node | **No** | The node is one container on one Docker VM, holding both environments |
| Malicious images from upstream | Partly | Digest pinning stops silent substitution. It does not vet what the digest contains |

## RBAC

| Principal | Rights | Source |
|---|---|---|
| `.local/kubeconfig`, `kind-plane-platform` | Cluster-admin, written by kind | `scripts/cluster-up.sh`. The user's `~/.kube/config` is never touched |
| Argo CD project `platform` | All namespaces, cluster-scoped resources, CRDs, NetworkPolicies. Not `Namespace`, `ResourceQuota`, `LimitRange` | `gitops/bootstrap/chart/templates/appprojects.yaml` |
| Argo CD project `plane-dev` | `plane-dev` only, namespaced only. Not `NetworkPolicy`, `ResourceQuota`, `LimitRange`. Source: the local Git repo only | Same |
| Argo CD project `plane-prod-sim` | As above, for `plane-prod-sim` | Same |
| Operator `iso-dev-controller-manager` | Role in `plane-dev`: Secrets and ConfigMaps read and write, `serviceaccounts/token` create, patch workloads, Infisical CRs | Chart with `scopedRBAC: true` |
| Operator `iso-prod-sim-controller-manager` | Same, in `plane-prod-sim` | Same |
| Both operators, cluster-wide | `tokenreviews` and `subjectaccessreviews` create, `/metrics` get. Three cluster-scoped objects the chart renders in scoped mode | Same |
| `plane-infisical-auth` in each Plane namespace | `system:auth-delegator`. No pod runs as it | `infisical/manifests/token-reviewer.yaml` |
| `plane` ServiceAccount, every Plane pod | No role bindings, no mounted token | `helm/plane/components/hardening/serviceaccounts.yaml` |
| `infisical-server` | No role bindings, no mounted token. Kubernetes Auth reviews use the caller's token | `infisical/manifests/serviceaccount.yaml` |
| Grafana | Role over ConfigMaps in `monitoring` only (`rbac.namespaced: true`) | `helm/values/kube-prometheus-stack.yaml` |
| Prometheus, its operator, kube-state-metrics, Alloy, Argo CD controller, Traefik | Cluster-wide roles from their charts. Not enumerated or narrowed here | `helm/values/*` |

AppProjects are owned by Terraform and not synced from Git, so an Application in Git cannot widen its own permissions. Each cluster-scoped binding above is deployed under `platform`.

Conftest enforces the token rule. `policy/workloads.rego` denies a workload without `automountServiceAccountToken: false`, except a named allow-list of the two operator Deployments. The allow-list is keyed on name, so a manifest cannot exempt itself through a label.

The operator's Role is broad inside its namespace: it can read every Secret there and mint a token for any ServiceAccount there. So a compromised operator owns its environment. Scoped mode limits that to one environment and goes no further.

[[VERIFY: kubectl auth can-i results for each principal above match this table on the running cluster]]

## Pod Security Admission

Terraform creates every namespace and sets these labels.

| Namespace | Enforce | Warn and audit | Why not tighter |
|---|---|---|---|
| `argocd` | `baseline` | `restricted` | Upstream charts, not verified against `restricted` |
| `traefik` | `baseline` | `restricted` | Same |
| `monitoring` | `baseline` | `restricted` | Same |
| `monitoring-agents` | `privileged` | `restricted` | node-exporter needs `hostNetwork` and `hostPID`. It is the only workload here |
| `infisical` | `baseline` | `restricted` | Chart-rendered server |
| `plane-dev` | `baseline` | `restricted` | Hardening targets `restricted`, enforcement waits for a per-workload test |
| `plane-prod-sim` | `baseline` | `restricted` | Contract: tighten only after a per-workload non-root test passes |

`kube-system` is kind's and carries no PSA label from this repository.

`baseline` is what is enforced. `warn` shows at admission. `audit` writes to the API server's audit log, and no audit backend is configured on this kind cluster, so that label leaves nothing to read. The Plane workloads are configured to meet `restricted`: `helm/plane/components/hardening` sets `runAsNonRoot`, a per-image UID, `seccompProfile: RuntimeDefault`, `allowPrivilegeEscalation: false` and `capabilities: {drop: [ALL]}` on every Plane Deployment, StatefulSet and Job. Backup and restore Jobs follow the same shape and mount a PVC rather than a `hostPath`, so they pass admission.

Read-only root filesystem is not set on Plane application containers. `.trivyignore` accepts `KSV-0014` until 2027-02-01 for that reason. The Infisical data pods, the backup Jobs and the operators do set it.

[[VERIFY: all 12 Plane workloads start and run as their configured non-root UID in both environments]]

[[VERIFY: Plane pods produce no PodSecurity restricted warnings at admission]]

## NetworkPolicy model

Every namespace this platform owns has a `default-deny` for ingress and egress, plus `allow-dns`, plus rules for what really flows. All policies live in `gitops/platform/network-policies/` and sync at wave -10 under the `platform` project. Plane projects cannot create or change them.

| Path | Policy |
|---|---|
| Browser to any UI | NodePort to Traefik, from `172.16.0.0/12` or `192.168.65.0/24` on 8000 and 8443 |
| Traefik to web, admin, space, live | Allowed on 3000 |
| Traefik to api, Silo | Allowed on 8000, 9000 |
| App tier to Postgres, Valkey, RabbitMQ, Silo | api, worker, beat and migrator only, on 5432, 6379, 5672, 9000 |
| live to api, Valkey | Allowed on 8000, 6379 |
| api to its own public host | Through the CoreDNS rewrite to Traefik, on 8000. Needed for `copy_object` and OAuth avatars |
| Backup Jobs | To Postgres and Silo only. Label `app.kubernetes.io/component: backup` |
| Operator | To Infisical on 8080, to the API server on 6443 |
| Prometheus | To exporters and metrics ports on named ports |
| Argo CD | To the API server on 6443, to `plane-git` on 9418, to chart repositories |
| Infisical server | From Traefik and the two operators on 8080. To its own data, and to 6443 |
| Between `plane-dev` and `plane-prod-sim` | No rule, so denied |
| Plane to the internet | No rule, so denied. Plane's phone-home to `telemetry.plane.so` has no route |
| RabbitMQ management 15672, Silo console 9090 | Closed |

Valkey has no password in this chart (chart issue 113). The `valkey` NetworkPolicy is its only access control.

`tests/network-policy-matrix.yaml` declares the expected reachability: 126 allow rows and 257 deny rows. `make test-netpol` runs it. A deny passes only on a timeout, because connection refused means the packet arrived. A DNS failure is inconclusive and fails the run.

[[VERIFY: make test-netpol passes every allow and deny row on the running platform]]

### kindnet limits

kindnet enforces NetworkPolicy through kube-network-policies. These limits come from reading `pkg/dataplane/controller.go` at the pinned commit, and they shape how to test and how far to trust the result.

| Limit | Consequence |
|---|---|
| **Fails open and silently.** `FailOpen: true`, errors log `skipping network policies` and traffic continues | A broken dataplane looks like everything working. `scripts/test-netpol.sh` runs a sentinel first: kindnet log check, a positive control, then a denied connection in a throwaway namespace |
| Only the first packet of a new connection is evaluated | Existing connections survive a new policy. Each test needs a new connection |
| `meta skuid 0 accept`: root sockets in the node's network namespace skip evaluation | Never test from a `hostNetwork` pod. Kubelet probes bypass policy |
| Evaluated after DNAT and before SNAT | Policies see pod IP and target port. The API server appears as the node IP on 6443 |
| `hostNetwork` pods are not treated as pods | The `monitoring-agents` policies do not constrain node-exporter. Prometheus's own egress rule is the control |
| Host-source CIDR cannot be pinned | Docker picks the kind network per machine, so rules allow Docker's default pool, `172.16.0.0/12`, on named ports. `scripts/cluster-up.sh` fails if the network falls outside it |
| Host-source address at Traefik is known only at runtime | Both the kind range and Docker Desktop's `192.168.65.0/24` are allowed |

Known gaps that NetworkPolicy cannot see:

- The api may reach Traefik, and Traefik routes by Host header. A compromised api could request the other environment's public hostname. Pod-to-pod paths between the environments do not exist, but this path through Traefik does.
- `kube-system` has no namespace default-deny. It holds kind's own components, which this platform does not own.

A day-1 gate recorded a positive control, a default-deny blocking a new connection, and an allow rule admitting only a labelled client, in a throwaway namespace. [[VERIFY: copy .local/evidence-raw/day1-gates-2.txt into docs/evidence/ with date and command, otherwise remove this statement]]

## Resource limits

Limits exist for stability first. They are also the only defence against one environment starving the other, and an incomplete one.

| Control | Value | Source |
|---|---|---|
| Per-workload memory | Contract section 10, for example api 256/768 MiB, Postgres 128/512 MiB | `helm/plane/components/hardening/patches/*` |
| ResourceQuota per Plane namespace | 2704 Mi requests, 7904 Mi limits, 22 pods, 6 PVCs | `infrastructure/terraform/modules/foundation/main.tf` |
| LimitRange per Plane namespace | Default 64/256 Mi, maximum 1 Gi per container | Same |
| Conftest rule | A rendered workload with no memory limit fails CI. Third-party charts only warn | `policy/workloads.rego`, `policy/charts.rego` |
| Host disk guard | `guard_disk`, 10 GiB free by default, in scripts | `scripts/lib/common.sh` |

The quota counts each Deployment twice, because a rolling update surges one extra pod, and a quota that fits only steady state makes a rollout fail with "exceeded quota". There is no CPU quota: the contract budgets no CPU, and a CPU quota would reject any pod without a CPU request.

What this leaves open:

- Memory limits sum above the VM's memory by design. Estimate: about 107% of a 14 GiB VM, from summing the configured limits of all workloads. A real peak can trigger the OOM killer across environments.
- Quotas and limits act per namespace or per container. Node pressure does not. kind disables eviction and image GC, so a full disk produces write errors, not evictions.
- No disk quota exists. kind's `standard` class ignores PVC capacity.
- The pod quota does not budget the exporters. By static count, 14 steady pods, 7 surges and a backup reach 22 of 22, so one more pod would be rejected. [[VERIFY: a backup Job fits the pod quota while exporters and rolling updates run]]

[[MEASURE: peak memory of the whole platform against the VM, from kubectl top and docker stats]]

## Secret isolation

Full detail in [infisical.md](infisical.md).

| Boundary | Mechanism | Limit |
|---|---|---|
| Git to cluster | Rendered manifests hold zero `kind: Secret`. Conftest and CI enforce it | Host-only Secrets exist, applied by scripts |
| Dev to prod-sim, in Infisical | One project, identity and `viewer` membership per environment | A reader sees every secret in its own environment. Custom roles and folder RBAC are paid |
| Dev to prod-sim, in Kubernetes | Namespaced operators with scoped Roles, `allowed_namespaces` on the identity | Cluster-admin reads both |
| Workload to API server | No mounted token, except the two operators | |
| Terraform state | Secret values are not in any variable or state | State holds ids and the public cluster CA |
| Scripts | Tokens through a 0600 header file, bodies through stdin, `set +x` | A same-user process can still read files |

Values are visible in more places than Infisical: base64 in etcd, unencrypted at rest, and in the environment of each consuming process. Postgres is a shared superuser role.

[[VERIFY: cross-project read returns 403 or 404, per the evidence plan in infisical.md]]

## Image pinning

| Rule | Enforcement |
|---|---|
| Plane workloads by `@sha256:` | `policy/environments.rego` denies otherwise, on rendered manifests |
| Upstream images from `docker.io` by index digest, never `artifacts.plane.so` | `policy/plane.rego` bans that registry |
| Platform chart images | Digests in `helm/values/*` by convention. No policy enforces it: `policy/charts.rego` only warns on a missing memory limit |
| `kindest/node` by digest | `infrastructure/kind/cluster.yaml.tmpl` |
| Compose services by digest, and the Git daemon's base image | `infrastructure/local-services/compose.yaml`, `infrastructure/local-services/git-daemon/Dockerfile` |
| Chart versions exact | Argo CD `targetRevision`, Terraform `version`, and the Plane chart vendored byte-identical with its sha256 recorded |
| CLI tools by checksum | `tools.lock`, `scripts/install-tools.sh` |
| GitHub Actions by commit SHA | Workflows. `zizmor` audits them |
| `kind load` | Forbidden. It cannot work with this host's containerd image store (kind issue 3795) |

Pulls go through pull-through caches declared in `infrastructure/kind/containerd-certs.d/`. A digest makes the mirror safe to trust for content. It does not make the content safe.

Contract section 5 specifies branded images at `localhost:5001/wayline/*`. At commit f733b87 both overlays still reference `docker.io/makeplane/*` by digest, and the branding layer is being integrated. [[VERIFY: overlays reference localhost:5001/wayline by digest once the branding layer lands]]

The local registry has no authentication and listens on `127.0.0.1:5001`. Anyone local can push a new tag. Pods reference digests, so a new tag changes nothing already pinned.

## Container scanning

What `scripts/ci/security.sh` runs in CI and in `make ci`:

| Tool | Scope |
|---|---|
| `gitleaks git`, `gitleaks dir` | Git history and working tree |
| `trivy config` | Kubernetes, Terraform and Dockerfile misconfiguration in the repo. HIGH and CRITICAL fail |
| `trivy fs --scanners vuln,secret` | Lockfiles and secrets in the repo |

**What is not scanned: container images.** No script or workflow runs `trivy image` at commit f733b87. Neither the pinned upstream images nor built Wayline images are scanned for CVEs. `scripts/ci/build-images.sh` also sets `--provenance=false --sbom=false`, so built images carry no SBOM or provenance. This is a real gap. [[VERIFY: whether trivy image scanning has been added before this section is finalized]]

Known risk the scan would surface: RabbitMQ 3.13 is an end-of-life series, kept because Celery attaches 0 consumers on 4.3 (upstream chart PR 304). Infisical's image is large and carries many packages.

Trivy runs from the pinned binary in `tools.lock`, never through `trivy-action`, whose tags were force-pushed with malware in March 2026 (GHSA-69fq-xp46-6x23).

`.trivyignore` holds one accepted finding with an expiry, so it gets reviewed.

[[VERIFY: make ci passes at the final commit, and its output is saved to docs/evidence/]]

## CI hardening

| Measure | Where |
|---|---|
| `permissions: {}` at workflow level, each job states its own | All workflows |
| `contents: read` on lint, manifests and security jobs. No secrets, no cluster | `ci.yml` |
| `persist-credentials: false` on every checkout | All workflows |
| Actions pinned to commit SHA | All workflows |
| No `pull_request_target` | All workflows |
| Write tokens only in the jobs that open a pull request or push to GHCR | `images.yml`, `promote-prod-sim.yml` |
| `actionlint`, `zizmor`, `shellcheck`, `hadolint`, `tflint` | `scripts/ci/lint.sh` |
| Render drift, kubeconform, conftest, promotion invariant | `scripts/ci/validate-manifests.sh` |
| One owner per resource | `scripts/ci/ownership.sh` |
| Workflows call the same scripts as `make` | So a local run and a CI run share one implementation |
| CI never touches the cluster | Argo CD reads the local Git remote in Pass 1 |

[[VERIFY: the three workflows run green on GitHub, with run URLs recorded in docs/evidence/]]

## GitHub Free limits

The repository is private on the GitHub Free plan. On that plan GitHub provides **no environments with required reviewers, no protected branches, and no artifact attestations** for private repositories.

**So prod-sim approval is a process, not a control.**

- `promote-prod-sim.yml` opens a pull request. A person merging it is the approval.
- GitHub cannot enforce that. Anyone with write access can merge their own pull request, push straight to `main`, or skip CI. `CODEOWNERS` only requests a review.
- A failing check does not block a merge.
- A pull request opened with `GITHUB_TOKEN` does not trigger `on: pull_request`, so those workflows run validation themselves before opening it.

What is enforced lives in scripts: `scripts/promote.sh` and `scripts/ci/check-promoted-digests.sh` refuse a prod-sim digest never recorded for dev. Someone with shell access can bypass a script too. A script is a safeguard against mistakes, not a security boundary.

In Pass 1 a merge changes nothing running. It reaches the cluster only when someone pulls `main` and runs `make gitops-publish`.

## What is not protected

Plainly, so nobody assumes otherwise.

| Not protected | Consequence |
|---|---|
| Etcd at rest | Secrets are base64, not encrypted, on the node's disk |
| `.local/` | Secret zero, kubeconfig and the admin token are plain files. Permissions stop other users, not the same user |
| Backups | Plaintext API tokens and password hashes, unencrypted, on the same disk as everything else. No off-machine copy unless done by hand |
| TLS | None. All HTTP, in the cluster and at the ingress. The operator talks to Infisical in cleartext. Session cookies and tokens cross loopback unencrypted. Pass 2 terminates TLS at Cloudflare and the origin |
| UIs | Prometheus and Alertmanager have no authentication. They rely on loopback binding. A local process or a page in a local browser may reach `*.localhost` |
| Git remote | `git://` is unauthenticated and unencrypted, with no signature verification. Whoever can write `.local/git` controls what Argo CD deploys |
| Registry | No authentication on `127.0.0.1:5001` |
| Audit | Infisical stores no audit logs on this tier. Kubernetes audit logging is not configured |
| Runtime detection | No Falco or equivalent. No admission control beyond PSA |
| Image content | No CVE scan of images, no signature check, no SBOM |
| Tenant isolation | One kernel, one node, one etcd. See [Read this first](#read-this-first) |
| Availability | One node, one replica of everything. See [disaster-recovery.md](disaster-recovery.md) |
| Postgres least privilege | One shared superuser role per environment. The exporter connects with it too |
| Valkey | No password. A NetworkPolicy is the only control, and kindnet can fail open |
| SSRF | `ALLOW_INTERNAL_IP_CONNECTIONS=true` relaxes it across Infisical |
| Secret rotation | One value, on demand, by script, with an error window |
| Supply chain of upstream code | Plane, Infisical and chart contents are trusted as of their digest |

Limitations in full: [known-limitations.md](known-limitations.md). Test status: [validation.md](validation.md).
