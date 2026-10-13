# Security

The security posture of a local, single-node, single-operator platform that runs Wayline, a customized Plane Community Edition v1.4.3 deployment, on kind. This is a learning and portfolio platform, local and production-inspired, and nothing here claims it is ready for production.

**Status on 2026-11-05.** This file describes configuration, and links the runs that bear on it: separation attempts between the environments ([environments.md](environments.md#what-real-attempts-showed)), the NetworkPolicy matrix, Infisical isolation, route tests, image scans, and CI ([ci evidence](evidence/ci/README.md), [security evidence](evidence/security/README.md)). Both environments ran the images built from `84b63d9`. Secret rotation has real runs in both environments ([below](#secret-rotation-runs)). A cluster reading with no later date comes from the cluster that `make drill-clean-restore CONFIRM=yes CLEAN_INSTALL_FIRST=yes` deleted before restoring into a new one. On the restored platform `make test` passed in full, from 08:34:55Z to 08:45:53Z: the gates, the NetworkPolicy matrix 418 of 418, Infisical isolation and rendered secrets, routes, e2e in both environments, and separation with 384 network and 97 state checks ([log](evidence/runs/MAKE-TEST-20261105T083455Z.txt)). A later drill ran the cold install and restored into a third cluster, with Infisical's isolation and rendered secrets passing on each ([cold install](evidence/runs/clean-install-20261105T105546Z/test-infisical.txt), [restored](evidence/runs/drill-clean-restore-20261105T105347Z.log)), and the install's own `SECRET_KEY` [refused a backup from another install](evidence/runs/clean-install-20261105T105546Z/restore-foreign-key-refused.txt). The full `make test` did not run on that cluster, the one the second restore built, because the next drill deleted it. Another drill, `LOSE_CLUSTER=yes`, from 13:06Z to 13:35Z, restored into a fourth, with Infisical's isolation and rendered secrets passing again, and read `RESULT PASS` ([output](evidence/runs/BKP-6-20261105T130633Z-lose-cluster-make.txt), [isolation](evidence/runs/infisical-isolation-20261105T133244Z-47821.txt), [rendered](evidence/runs/infisical-rendered-secrets-20261105T133244Z-47821.txt)). The final `make test` passed in full on that fourth cluster, from 14:00:19Z to 14:11:52Z at `f30a7f5`, with the same counts ([log](evidence/runs/MAKE-TEST-20261105T140019Z.txt)).

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
| A mistake by the operator | Yes | Guards on `destroy`, `restore`, `rotate` and prod-sim promotion. A restore with no `CONFIRM` [refused in prod-sim](evidence/runs/SEC-3-BKP-3-20261105T073240Z.txt) and changed nothing, and `make destroy` with none [refused](evidence/runs/TEAR-1-20261105T083304Z.txt) in a clean environment, exit 2, with the cluster still Ready. Git as source of truth |
| A secret committed to Git | Yes | gitleaks in `make ci` and CI, zero `kind: Secret` rule. gitleaks knows only its rules: a plane-dev session cookie in a k6 summary fit none of them and got past it and the evidence scrub. A read-through of the evidence caught it, and a new scrub rule now replaces such a value ([what happened](evidence/README.md#the-scrub), [control](evidence/runs/publish-evidence-session-control-1.txt)). The unpushed history was rewritten, so GitHub never held it, and the session was signed out ([record](evidence/history-rewrite.md)) |
| A malicious or hijacked CI dependency | Partly | SHA-pinned actions, and no cluster access from any workflow. `ci.yml` holds no secrets and read-only tokens. `images.yml`'s `Build and push` job runs the whole image build with a `packages: write` token, so a hijacked build dependency there could publish to GHCR. Its prune and digest bump jobs, and `promote-prod-sim.yml`, hold write tokens too ([CI hardening](#ci-hardening)) |
| Another device on the LAN | Yes | Host ports bind to `127.0.0.1` only. On 2026-11-05 `lsof` read 80, 443 and 5001 listening on `127.0.0.1` and on nothing else, and all three refused a connection on the LAN address ([readings](evidence/security/README.md#host-listeners)). One reading, with `lsof` under the owner's account, taken from the Mac itself and not from another device |
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
| Both operators, cluster-wide | `tokenreviews` and `subjectaccessreviews` create, through ClusterRole `iso-*-metrics-auth-role` and its binding. The third object the chart renders in scoped mode, ClusterRole `iso-*-metrics-reader`, grants `/metrics` get and is bound to nobody, so the operators answer no to it ([cluster-readings-2.txt](evidence/runs/cluster-readings-2.txt)) | Same |
| `plane-infisical-auth` in each Plane namespace | `system:auth-delegator`. No pod runs as it | `infisical/manifests/token-reviewer.yaml` |
| `plane` ServiceAccount, every Plane pod | No role bindings, no mounted token | `helm/plane/components/hardening/serviceaccounts.yaml` |
| `infisical-server` | The chart's Role over `jobs` read in `infisical`, and no mounted token, so the pod cannot use it. Kubernetes Auth reviews use the caller's token | `infisical/manifests/serviceaccount.yaml` |
| Grafana | Role over ConfigMaps and Secrets in `monitoring` only (`rbac.namespaced: true`): get, watch and list. Those Secrets include `kps-grafana`, `alertmanager-kps-alertmanager` and `kps-prometheus-token`. It gets no in the Plane namespaces ([cluster-readings-2.txt](evidence/runs/cluster-readings-2.txt)) | `helm/values/kube-prometheus-stack.yaml` |
| Prometheus, its operator, kube-state-metrics, Alloy, Argo CD controller and server, Traefik | Cluster-wide roles from their charts, not narrowed here. The Argo CD controller can do anything. Traefik and the Prometheus operator can list Secrets in every namespace, and the Argo CD server can get them. Prometheus, kube-state-metrics and Alloy can list pods everywhere, and not Secrets ([cluster-readings-2.txt](evidence/runs/cluster-readings-2.txt)) | `helm/values/*` |

AppProjects are owned by Terraform and not synced from Git, so a commit cannot edit what a project allows. A commit could set `project: platform` on a Plane Application. `policy/gitops.rego` refuses that in CI ([negative control](evidence/ci/ci-3-20261104T223937Z-negative-controls-local.log)), and on this GitHub plan a failing check cannot block a merge. See scenario 10 in [environments.md](environments.md#failure-scenarios). Each cluster-scoped binding above is deployed under `platform`.

Conftest enforces the token rule. `policy/workloads.rego` denies a workload without `automountServiceAccountToken: false`, except a named allow-list of the two operator Deployments. The allow-list is keyed on name, so a manifest cannot exempt itself through a label.

The operator's Role is broad inside its namespace: it can read every Secret there and mint a token for any ServiceAccount there. So a compromised operator owns its environment. Scoped mode limits that to one environment and goes no further. It does nothing about the chart accounts in the last row: a compromised Traefik, Prometheus operator or Argo CD controller reads both environments' Secrets.

Measured with `kubectl auth can-i` on 2026-11-04, for the two operators, `plane-infisical-auth`, `plane` and `default`: each operator reads Secrets and mints tokens at home and gets no in the other namespace, in `infisical` and across all namespaces, and the others cannot read Secrets ([infisical-rbac-1.txt](evidence/runs/infisical-rbac-1.txt), [state 2](evidence/runs/plane-prod-sim-separation-state-2.txt)). On 2026-11-05 the kubeconfig and every ServiceAccount in the table were asked again, and the table now says what the API server answered, which corrected Grafana's Secrets, the operators' `/metrics` and `infisical-server`'s Role ([cluster-readings-2.txt](evidence/runs/cluster-readings-2.txt)). `can-i` reads an account's rights, not what its process does with them.

## Pod Security Admission

Terraform creates every namespace and sets these labels.

| Namespace | Enforce | Warn and audit | Why not tighter |
|---|---|---|---|
| `argocd` | `baseline` | `restricted` | Upstream charts, not verified against `restricted` |
| `traefik` | `baseline` | `restricted` | Same |
| `monitoring` | `baseline` | `restricted` | Same |
| `monitoring-agents` | `privileged` | `restricted` | node-exporter needs `hostNetwork` and `hostPID`. It is the only workload here |
| `infisical` | `baseline` | `restricted` | Chart-rendered server |
| `plane-dev` | `baseline` | `restricted` | Hardening targets `restricted`. The per-workload test passed on upstream images, the label has not moved, and the test has not been repeated on the branded images |
| `plane-prod-sim` | `baseline` | `restricted` | Contract: tighten only after a per-workload non-root test passes. It passed on upstream images, and the label has not moved |

`kube-system` is kind's and carries no PSA label from this repository.

`baseline` is what is enforced. `warn` shows at admission. `audit` writes to the API server's audit log, and no audit backend is configured on this kind cluster, so that label leaves nothing to read. The Plane workloads are configured to meet `restricted`: `helm/plane/components/hardening` sets `runAsNonRoot`, a per-image UID, `seccompProfile: RuntimeDefault`, `allowPrivilegeEscalation: false` and `capabilities: {drop: [ALL]}` on every Plane Deployment, StatefulSet and Job. Backup and restore Jobs follow the same shape and mount a PVC rather than a `hostPath`, so they pass admission.

Running as non-root has a cost that only a cold install showed. Under umask 077 every file in a build context was 0600, the build kept those modes, and web, admin, space and api crashed at start, with Permission denied in the logs of web, admin and api, because their users could not read their own files. Every build step had passed. `b4f6cc9` runs `chmod -R a+rX` on each context under `apps/wayline/`, which also means those files are readable by every user in the image and on this host. That is source and build output, and `.local/`, with secret zero at mode 0600, is outside it. The Plane workloads that came up after the fix passed the first smoke in both environments ([rebuild](evidence/runs/INST-1-cold-rebuild-20261105T122036Z.txt), [dev](evidence/runs/clean-install-20261105T105546Z/e2e-dev-first.txt), [prod-sim](evidence/runs/clean-install-20261105T105546Z/e2e-prod-sim-first.txt)). Nothing checks an image's file modes, so the fix has no test of its own. [Known limitations](known-limitations.md#what-real-runs-found) has the finding.

Read-only root filesystem is not set on Plane application containers. `.trivyignore` accepts `KSV-0014` until 2027-02-01 for that reason. The Infisical data pods and the backup Jobs do set it, in `infisical/manifests/` and `scripts/backup.sh`. What the operators' chart sets has no file here ([what each reading rests on](known-limitations.md#security)).

Measured on 2026-11-04, on upstream images in both environments: each Plane container with a shell reported its configured UID, Silo was read from its pod spec, and a server-side dry run of `enforce=restricted` gave no warnings ([dev](evidence/runs/plane-dev-psa-1.txt), [prod-sim](evidence/runs/plane-prod-sim-host-and-identity-1.txt)). The finished migrator was read from its pod spec too, in dev that day and in prod-sim on 2026-11-05, still on upstream's image ([cluster-readings-1.txt](evidence/runs/cluster-readings-1.txt)). That meets the condition in contract section 2 for tightening `plane-prod-sim`, and the label has not moved. The branded images, which both environments now run, have not had the dry run repeated.

## NetworkPolicy model

Every namespace this platform owns has a `default-deny` for ingress and egress, plus `allow-dns`, plus rules for what really flows. All policies live in `gitops/platform/network-policies/` and sync at wave -10 under the `platform` project. Plane projects cannot create or change them.

| Path | Policy |
|---|---|
| Browser to any UI | NodePort to Traefik, from `172.16.0.0/12` on 8000 and 8443. Measured source on this host: `172.24.0.1`, the kind gateway ([traefik-nodeport-source-1.txt](evidence/runs/traefik-nodeport-source-1.txt)) |
| A pod to an internal UI | NetworkPolicy lets the api reach Traefik, and Middleware `node-network-only` answers 403 ([routes-after-3.txt](evidence/runs/routes-after-3.txt)) |
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

`tests/network-policy-matrix.yaml` declares the expected reachability: 126 allow rows and 292 deny rows since `01ab74c`. `make test-netpol` runs it. A deny passes only on a timeout, because connection refused means the packet arrived. A row that cannot prove anything, such as a DNS failure, reads INCONCLUSIVE, which is never a pass. Since `01ab74c` each probe also has references at the same moment: the node dials each target, and the pod resolves a cluster name, so a target that is down no longer reads as a block.

The final run, inside `make test` at `f30a7f5` with both environments on the final images, ended at about 2026-11-05T14:06:52Z with 418 PASS, 0 FAIL and 0 INCONCLUSIVE: all 126 allow rows connected, all 292 deny rows ended in a timeout, none needed anything outside the cluster, and no deny row passed with no reference ([tsv](evidence/runs/netpol-20261105T140145Z.tsv), [log](evidence/runs/MAKE-TEST-20261105T140019Z.txt)). The run inside the `make test` before it, ended at 08:40:48Z, read the same ([tsv](evidence/runs/netpol-20261105T083542Z.tsv), [log](evidence/runs/MAKE-TEST-20261105T083455Z.txt)).

| Source namespace | Rows | Result in that run |
|---|---:|---|
| `plane-dev` | 153 | 153 PASS |
| `plane-prod-sim` | 151 | 151 PASS |
| `monitoring` | 50 | 50 PASS |
| `traefik` | 28 | 28 PASS |
| `argocd` | 19 | 19 PASS |
| `infisical` | 14 | 14 PASS |
| `kube-system` | 3 | 3 PASS |

On the first cluster the whole matrix read 418 PASS, 0 FAIL and 0 INCONCLUSIVE at 2026-11-05T01:08Z, 02:38Z and 04:19Z, before the final images were promoted ([01:08Z](evidence/runs/netpol-20261105T010838Z.tsv), [02:38Z](evidence/runs/netpol-20261105T023831Z.tsv) with [its log](evidence/runs/harness-make-test-netpol-3.txt), [04:19Z](evidence/runs/netpol-20261105T041921Z.tsv) with [its log](evidence/runs/harness-make-test-netpol-4.txt)). A run at 02:25Z read 412 PASS, 0 FAIL and 6 INCONCLUSIVE, exit 2: the 6 are deny rows to the Infisical Service, which had no ready endpoint during another agent's `make restore ENV=infisical`, and that is not a pass ([tsv](evidence/runs/netpol-20261105T022535Z.tsv), [its log](evidence/runs/harness-make-test-netpol-2.txt)). A deny PASS is a timeout while both references answered, so it cannot rule out loss only on that pod's path to that target. This shows policy behaviour inside one cluster, and it does not make namespaces equivalent to independent clusters.

### kindnet limits

kindnet enforces NetworkPolicy through kube-network-policies. These limits come from reading `pkg/dataplane/controller.go` at the pinned commit, and they shape how to test and how far to trust the result.

| Limit | Consequence |
|---|---|
| **Fails open and silently.** `FailOpen: true`, errors log `skipping network policies` and traffic continues | A broken dataplane looks like everything working. `scripts/test-netpol.sh` runs a sentinel first: kindnet log check, a positive control, then a denied connection in a throwaway namespace. Between runs, alert `KindnetSkippedNetworkPolicies` watches that one line. It was proven with a synthetic line, not a real failure ([h18-synthetic-2.txt](evidence/runs/h18-synthetic-2.txt), [kindnet-hold-2.txt](evidence/runs/kindnet-hold-2.txt)) |
| Only the first packet of a new connection is evaluated | Existing connections survive a new policy. Each test needs a new connection |
| `meta skuid 0 accept`: root sockets in the node's network namespace skip evaluation | Never test from a `hostNetwork` pod. Kubelet probes bypass policy |
| Evaluated after DNAT and before SNAT | Policies see pod IP and target port. The API server appears as the node IP on 6443 |
| `hostNetwork` pods are not treated as pods | The `monitoring-agents` policies do not constrain node-exporter. Prometheus's own egress rule is the control |
| Host-source CIDR cannot be pinned | Docker picks the kind network per machine, so rules allow Docker's default pool, `172.16.0.0/12`, on named ports. `scripts/cluster-up.sh` fails if the network falls outside it |

Known gaps that NetworkPolicy cannot see:

- The api may reach Traefik, and Traefik routes by Host header. A compromised api could request the other environment's public hostname, and in the final `make test` the real api pods did, getting that host's public surface: 200 on `/api/instances/`, 401 on `/api/users/me/`, 403 listing the bucket ([state](evidence/runs/separation-state-20261105T140019Z-56547.txt)). Pod-to-pod paths between the environments timed out in all 120 rows each way ([network](evidence/runs/separation-network-20261105T140019Z-56547.txt)), but this path through Traefik exists. The internal UIs on the same Traefik answer such a pod with 403.
- `node-network-only` reads a source address. A pod with free egress reached Prometheus through `host.docker.internal:80`, which leaves through the Mac and returns as the host ([h17-doors-free-egress-2.txt](evidence/runs/h17-doors-free-egress-2.txt)). Plane pods time out on that door, but only NetworkPolicy holds it.
- `kube-system` has no namespace default-deny. It holds kind's own components, which this platform does not own.

The day-1 gate, on 2026-11-04 with the platform's 60 policies loaded, recorded 17 passed and 0 failed in a throwaway namespace: positive controls, a default-deny and an allow rule that each time out an unlabelled client while a reference answers that client and the node reaches the target ([day1-gates-20261104T231136Z.txt](evidence/day1-gates-20261104T231136Z.txt)). Loss only on the target's own path would read the same as a block, and the script says so. The final run, inside `make test` at `f30a7f5` with 60 policies loaded again, recorded 17 passed and 0 failed ([gates](evidence/runs/gates-20261105T140019Z-56547.txt)), as the one before it did on the restored platform ([gates](evidence/runs/gates-20261105T083455Z-37296.txt)).

## Resource limits

Limits exist for stability first. They are also the only defence against one environment starving the other, and an incomplete one.

| Control | Value | Source |
|---|---|---|
| Per-workload memory | Contract section 10, for example api 256/768 MiB, Postgres 128/512 MiB | `helm/plane/components/hardening/patches/*` |
| ResourceQuota per Plane namespace | 2732 Mi requests, 7984 Mi limits, 24 pods, 6 PVCs | `infrastructure/terraform/modules/foundation/main.tf` |
| LimitRange per Plane namespace | Default 64/256 Mi, maximum 1 Gi per container | Same |
| Conftest rule | A rendered workload with no memory limit fails CI. Third-party charts only warn | `policy/workloads.rego`, `policy/charts.rego` |
| Host disk guard | `guard_disk`, 10 GiB free by default, in scripts | `scripts/lib/common.sh` |

The quota counts each Deployment twice, because a rolling update surges one extra pod, and a quota that fits only steady state makes a rollout fail with "exceeded quota". There is no CPU quota: the contract budgets no CPU, and a CPU quota would reject any pod without a CPU request.

What this leaves open:

- Memory limits sum above the VM's memory by design. On 2026-11-05 the limits of the 56 running pods summed to 15,812 MiB, 113% of the 13.63 GiB the VM reports, with etcd, the API server and the other control plane containers unlimited on top ([cluster-readings-1.txt](evidence/runs/cluster-readings-1.txt)). A real peak can trigger the OOM killer across environments.
- Quotas and limits act per namespace or per container. Node pressure does not. kind disables eviction and image GC, so a full disk produces write errors, not evictions.
- No disk quota exists. kind's `standard` class ignores PVC capacity.
- The pod quota budgets the exporters since `bc8bb91`. All seven Plane Deployments surging at once reached 21 of 24 pods with no `FailedCreate` ([plane-dev-rollout-quota-1.txt](evidence/runs/plane-dev-rollout-quota-1.txt)). Every Deployment surging, exporters included, with the migrator, a backup and an ad-hoc pod would be 26, over the quota, by static count ([quota-budget-1.txt](evidence/runs/quota-budget-1.txt)). A backup Job while exporters and rolling updates run was not tested in Pass 1.
- CPU has no quota, and a CPU limit can set the ceiling. With no think time on dev, Postgres sat at its 500 m limit, throttled in 98% to 100% of CFS periods, and requests stopped rising at about 8.9 a second. Prod-sim's CPU and memory did not move in those minutes, and the VM had at most 2.49 of its 12 CPUs busy, so this does not test one environment starving the other ([load results](resource-utilization.md#load-results-dev)).

Highest VM use so far, with both environments running: 10.93 GiB of the 13.63 GiB, at 2026-11-05T01:50:00Z, in 60-second Prometheus readings of the whole VM from 00:35Z ([timeline](evidence/runs/LOAD-3-20261105T074543Z-timeline.json)). What ran in that minute was not read. The 5-second samples from the node, which ended at about 00:06Z, topped out at 10.49 GiB at 23:23:42 on 2026-11-04, in a low-load separation run while replaced Argo CD pods overlapped. In those samples the top under both smokes and the matrices was 9.87 GiB, and under the restart drills 9.90 GiB. Swap reached 0.60 GiB, and about 1 GiB of each of those figures is the owner's unrelated containers. A quiet reading on 2026-11-05 was `kubectl top` node 8,331 MiB and `docker stats` node 8.155 GiB ([memory](evidence/runs/plane-prod-sim-memory-1.txt), [snapshot](evidence/runs/plane-prod-sim-snapshot-final-1.txt)). Prometheus, Loki and Infisical's Postgres touched their cgroup limits, with 0 OOM kills ([limits-breakdown-1.txt](evidence/runs/limits-breakdown-1.txt)). Those samples predate the load tests. On the restored cluster, with nothing else started on it, the VM averaged 8.65 GiB idle, and topped 8.90 GiB at 5, 10 and 20 virtual users with think time and 9.05 GiB with none, with no OOM event and no restart ([against the VM](resource-utilization.md#against-the-vm)). On the first cluster, with prod-sim being rotated and restored in the same minutes, the same test read 10.33 GiB ([results](evidence/runs/load-20261105T073241Z/results.json)). That says nothing about a higher load.

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

A cross-project read returns 403. On 2026-11-04 each reader got 403 on the other project, on list, single read and slug lookup, from the host and from a pod in each namespace, while the same token read its own with 200. 28 rows passed ([infisical-isolation-3.txt](evidence/runs/infisical-isolation-3.txt)). A login as the other environment's identity gets 401. The final `make test`, at `f30a7f5`, read the same with the projects, identities and values back from backup: 28 rows of 28 ([isolation](evidence/runs/infisical-isolation-20261105T140019Z-56547.txt)), and 88 of 88 on the rendered Secrets ([rendered](evidence/runs/infisical-rendered-secrets-20261105T140019Z-56547.txt)), as the one before it did on the first restored cluster ([isolation](evidence/runs/infisical-isolation-20261105T083455Z-37296.txt), [rendered](evidence/runs/infisical-rendered-secrets-20261105T083455Z-37296.txt)).

### Secret rotation runs

`make rotate` changes one value, the Postgres password, through Infisical. Its first real runs were on 2026-11-05, on the final images, with the owner's approval.

| Run | Result | Error window | Evidence |
|---|---|---|---|
| Dev | PASS | A signed-in session read 500 on 38 of its 1,002 reads, all from 07:23:51Z to 07:24:29Z, about 38s, and the frontends stayed 200. The script's anonymous probe read 39 of 62 over 60s, and it counts throttling as failure too, so it overstates | [log](evidence/runs/rotate-dev-20261105T072345Z.log), [watch](evidence/runs/SEC-2-20261105T072331Z-watch.txt), [old password](evidence/runs/SEC-2-20261105T072331Z-old-value.txt) |
| Prod-sim | PASS | Only the anonymous probe ran: 37 of 60 over 39s. No signed-in session was watched | [log](evidence/runs/rotate-prod-sim-20261105T073240Z.log) |
| Prod-sim, killed with SIGKILL 4 seconds in, then `RESUME=yes` | PASS | Anonymous probe on the resume: 46 of 55 over 57s | [record](evidence/runs/SEC-4-20261105T073843Z.txt), [log](evidence/runs/rotate-prod-sim-20261105T073847Z.log) |
| Prod-sim on the restored cluster, killed with SIGKILL 4 seconds in, then `ROLLBACK=yes` | PASS | Anonymous probe on the rollback: 12 of 61 over 36s | [record](evidence/runs/SEC-4b-20261105T084615Z.txt), [log](evidence/runs/rotate-prod-sim-20261105T084620Z.log) |

Postgres refused the replaced password in each, and `SECRET_KEY` did not move. In the 16 minutes after dev's rollout Argo CD started one sync operation, for GITOPS-4's replica change, so there was no sync loop ([watch](evidence/runs/SEC-6-20261105T072331Z-application-watch.txt)). The rollback had `SKIP_BACKUP=yes`, so it took no Infisical backup. This shows one password on test data, and nothing about any other secret or about Jobs in flight. `SECRET_KEY` itself [cannot be rotated](known-limitations.md#application-what-is-customized-and-what-is-not).

## Image pinning

| Rule | Enforcement |
|---|---|
| Plane workloads by `@sha256:` | `policy/environments.rego` denies otherwise, on rendered manifests |
| Upstream images from `docker.io` by index digest, never `artifacts.plane.so` | `policy/plane.rego` bans that registry |
| Platform chart images | Digests in `helm/values/*`. `policy/charts.rego` denies a chart image with no digest, including images a Prometheus operator takes on its command line or from a resource, and warns on a missing memory limit |
| `kindest/node` by digest | `infrastructure/kind/cluster.yaml.tmpl` |
| Compose services by digest, and the Git daemon's base image | `infrastructure/local-services/compose.yaml`, `infrastructure/local-services/git-daemon/Dockerfile` |
| Chart versions exact | Argo CD `targetRevision`, Terraform `version`, and the Plane chart vendored byte-identical with its sha256 recorded |
| CLI tools by checksum | `tools.lock`, `scripts/install-tools.sh` |
| GitHub Actions by commit SHA | Workflows. `zizmor` audits them |
| `kind load` | Forbidden. It is reported to fail on this host's containerd image store (kind issue 3795), and that was not reproduced here, because nothing calls it |

Pulls go through pull-through caches declared in `infrastructure/kind/containerd-certs.d/`. A digest makes the mirror safe to trust for content. It does not make the content safe.

Contract section 5 specifies branded images at `localhost:5001/wayline/*`. Both overlays reference web, admin, space and backend there by digest, with the same digests: the images built from `84b63d9`, in dev since `29316f2` and in prod-sim since `9c8e098`. `live` stays upstream's in both.

The local registry has no authentication and listens on `127.0.0.1:5001`. Anyone local can push a new tag. Pods reference digests, so a new tag changes nothing already pinned.

## Container scanning

What `scripts/ci/security.sh` runs in CI and in `make ci`:

| Tool | Scope |
|---|---|
| `gitleaks git`, `gitleaks dir` | Git history and working tree |
| `trivy config` | Kubernetes, Terraform and Dockerfile misconfiguration in the repo. HIGH and CRITICAL fail |
| `trivy fs --scanners vuln,secret` | Lockfiles and secrets in the repo. It found none of the application's lockfiles, because that source lands in `.build`, which it skips |

Images are scanned by `scripts/ci/scan-images.sh`, through `make scan-images`, which is not part of `make ci`. It reads every image the platform runs from its registry for arm64, plus the Wayline builds, and their source lockfiles when `.build/plane-src` is on disk. It fails only on a CRITICAL finding with a fix in an image built here, on an image it could not scan, or on a result of another platform, and reports the rest. `images.yml` has a step that runs it on what was just pushed. That step has run twice, on real runners.

| Run | Scope | Result |
|---|---|---|
| [`scan-images-20261105T140048Z`](evidence/security/scan-images-20261105T140048Z/README.md) | All 31 targets, the complete run at `f30a7f5`, on the build both environments run, with no lockfile row | PASS, exit 0: no image we build has a CRITICAL with a fix, and every target on its list was scanned. 15 CRITICAL, 515 HIGH, 768 MEDIUM, 378 LOW, 120 UNKNOWN across all targets |
| [`scan-images-20261104T215437Z`](evidence/security/README.md) | 36 of 36 targets, the first complete run | FAIL on the policy: 5 CRITICAL with a fix, in `wayline/backend` and `wayline/space`, all inherited from upstream's images. 26 CRITICAL, 600 HIGH, 837 MEDIUM across all targets |
| [`scan-images-20261104T235800Z`](evidence/security/README.md) | The 5 targets built here, from `1563cbf` | PASS, exit 0: no image we build has a CRITICAL with a fix. `wayline/backend` 4 HIGH, `wayline/space` 30 HIGH. The source lockfile row still lists 1 CRITICAL, proxy-addr 2.0.7, which no bundle ships |
| [`scan-images-20261105T020423Z`](evidence/security/scan-images-20261105T020423Z/README.md) | The same 5 targets, from `ec45e21` | PASS, exit 0, with the same findings: none added and none gone |
| [`scan-images-20261105T025857Z`](evidence/security/scan-images-20261105T025857Z/README.md) | The same 5 targets, from `b2ba587` | PASS, exit 0, with the same findings |
| [`scan-images-20261105T052024Z`](evidence/security/scan-images-20261105T052024Z/README.md) | The same 5 targets, from `84b63d9`, the build both environments run | PASS, exit 0, with the same findings, on the same database as the run before |
| Step `Scan what was just pushed`, [run 41975430939](evidence/ci/README.md) | The 4 images on GHCR, from `9c8e098`, which are not the digests deployed | Exit 0 on a real runner. Only the table in the log remains, because the raw results stayed on the runner |
| Step `Scan what was just pushed`, [run 42044273310](evidence/ci/ci-4-20261105T142148Z-run-42044273310.log) | The 4 images on GHCR, from `76e98ee`, which are not the digests deployed, and the source lockfiles | Exit 0 on a real runner, with the same counts, the lockfile row at 1 CRITICAL and 31 HIGH. Only the table in the log remains |

In the complete run at `f30a7f5` these have a CRITICAL with a fix, reported only: postgres 15.19 and 16.15 in `gosu`, rabbitmq 3.13.7 in `libcrypto3` and `libssl3`, plane-live in proxy-addr, storybook and tinypool, and argocd v3.5.7 in `git-lfs` and `kustomize`. The first complete run also listed plane-backend and plane-space, which no longer run here and stay build inputs, so the later run did not scan them. A reading of five tags, postgres 15.19, valkey, rabbitmq 3.13.7, silo and argocd v3.5.7, found no newer digest under any ([image-pins-h50-1.txt](evidence/runs/image-pins-h50-1.txt)). Infisical's image has 5 CRITICAL with no fix. `redis:7.2.17-alpine` is on an end-of-life Alpine, where trivy warns that its OS findings may be incomplete. RabbitMQ 3.13 is an end-of-life series, kept because Celery attaches 0 consumers on 4.3 (upstream chart PR 304).

What this does not cover: local services outside the cluster manifests (the registry, `plane-git`, the kind node), and old package bytes left in the `FROM` layers of `wayline/space`, the backend having none since it was flattened. The complete run at `f30a7f5` has no lockfile row, because `.build/plane-src` was not on disk, so it did not read the frontends' dependencies. Every run on this Mac in the table above used the database updated 2026-11-04T19:02Z, so none of them knows a newer advisory. The zeros for web and admin cover OS packages only, because their clients are bundles with no package metadata. A finding means a version is listed as affected, and nobody has checked whether any of them can be reached here. `scripts/ci/build-images.sh` sets `--provenance=false --sbom=false`, so built images carry no SBOM or provenance. [The README](evidence/security/README.md) has the detail.

`make scan-images-hosted` scans what hosted production runs, as this checkout says: each line of `policy/hosted-images.txt`, which is what the hosted tree and its charts name, each line of `policy/hosted-system-images.txt`, which is K3s's own images and those of the probe pods that `make remote-netpol`, `make remote-test` and `make remote-restore-test` start, and each image in `gitops/environments/prod/manifests.yaml`, 45 in all. `validate-manifests.sh` holds the second list to the image list of K3s's release for `target.yaml`'s `k3s_version`, less what `k3s-config.yaml` disables, and to the probe scripts' pins. Each image is read from its registry for `linux/amd64`, an index for its `linux/amd64` child. It never reads the cluster, and it reports and fails as `make scan-images` does. `SCAN_HOSTED_RELEASE=origin/deploy/plane-prod` also reads the render on the branch hosted Argo CD syncs, which a refused or pending release leaves behind main, and the report says whether that branch's two trees differ from this checkout's. Wayline's images on GHCR are private, so it needs Docker logged in to `ghcr.io` with a token holding `read:packages`. `.github/workflows/scan-hosted.yml` runs it every Monday and on dispatch, with `contents: read`, `packages: read` and that comparison, and keeps the report and the raw results as an artifact for 30 days. In that job no image starts after 55 minutes, each try at one may take 10, and the step stops at 80, so the report is kept inside the job's 90 minutes. It has not run on GitHub yet.

What the hosted scan does not cover: K3s pulls its own images by tag, so each digest in `policy/hosted-system-images.txt` is the one its tag named when it was added, and only the node can say which it holds. The K3s binary, with containerd, kube-router and the Kubernetes components it embeds, is no image, and nothing here scans it. Hosted Argo CD is what Terraform last applied, and the list holds what this checkout's module names. An image someone starts by hand with `kubectl` is in no list.

The four runs of `make scan-images-hosted` so far listed 39, before K3s's own images and the probes were added, and none read all of them. On this Mac on 2026-11-07, with the database updated 2026-11-06T18:59Z, other work took the disk below the scan's 2 GiB floor twice, and Docker Desktop's credential helper took up to 19 minutes a call. With Docker's login, the four Wayline images have no CRITICAL finding: `wayline/space` has 32 HIGH and `wayline/backend` 4, each with a fix, and web and admin none. With no login, 30 of the 35 upstream images read 16 CRITICAL and 419 HIGH. A CRITICAL with a fix is in postgres 15.19 and 16.15 (Go's `stdlib` in `gosu`), rabbitmq 3.13.7 (`libcrypto3`, `libssl3`), plane-live (`proxy-addr`, `storybook`, `tinypool`) and restic 0.19.1 (OpenSSH), and Infisical has 5 with none. argocd, postgres-exporter, thanos, kube-state-metrics and metrics-server were not read. Later that day the six images the second list added were read on their own, through trivy as the scan calls it and on the same database, all six as `linux/amd64`: curl 8.17.0 has 2 CRITICAL, CVE-2026-31789 in `libcrypto3` and `libssl3`, fixed in 3.5.6-r0, and 28 HIGH, CoreDNS 1.14.7 23 HIGH and local-path-provisioner v0.0.37 16, each with a fix, and the two busybox images and pause none. The raw results stay in `.local/evidence-raw/` on that Mac.

Trivy runs from the pinned binary in `tools.lock`, never through `trivy-action`, whose tags were force-pushed with malware in March 2026 (GHSA-69fq-xp46-6x23).

`.trivyignore` holds one accepted finding with an expiry, so it gets reviewed.

`make ci` exited 0 in a clean clone of `f30a7f5` on 2026-11-05, with 149 of 149 stubbed scenarios, made from this checkout because that commit was not yet pushed ([output](evidence/runs/ci-2-20261105T140005Z-clean-clone-f30a7f5.txt)), and in clean clones from GitHub of `9c8e098` and `0dde813`, each with 132 ([log](evidence/ci/ci-2-20261105T061644Z-make-ci.log), [exit code](evidence/ci/ci-2-20261105T061644Z-make-ci.rc)). On this Mac 45 of 45 planted defects were caught at `cc88450` ([negative controls](evidence/runs/negative-controls-alerts-track-3.txt)), after 33 of 33 at `283b51a` ([earlier](evidence/ci/ci-3-20261104T223937Z-negative-controls-local.log)). On a real runner the count is 21 of 21, at `b350fdc`, and it has not run there since.

## CI hardening

| Measure | Where |
|---|---|
| `permissions: {}` at workflow level, each job states its own | All workflows |
| `contents: read` on lint, manifests and security jobs. No secrets, no cluster | `ci.yml` |
| `persist-credentials: false` on every checkout | All workflows |
| Actions pinned to commit SHA | All workflows |
| No `pull_request_target` | All workflows |
| Write tokens only in the jobs that open a pull request, push to GHCR, or delete old versions from GHCR (`prune`) | `images.yml`, `promote-prod-sim.yml` |
| `actionlint`, `zizmor`, `shellcheck`, `hadolint`, `tflint` | `scripts/ci/lint.sh` |
| Render drift, kubeconform, conftest, promtool, promotion invariant, stubbed promotion flows | `scripts/ci/validate-manifests.sh` |
| One owner per resource | `scripts/ci/ownership.sh` |
| Workflows call the same scripts as `make` | So a local run and a CI run share one implementation |
| CI never touches the cluster | Argo CD reads the local Git remote in Pass 1 |

On GitHub, recorded in [docs/evidence/ci/](evidence/ci/README.md) with run URLs:

| Workflow | Result | What it does not show |
|---|---|---|
| `ci.yml` | PASS on all three jobs at `6edde64` on 2026-11-05, and on the 6 pushes up to `0dde813`, four on 2026-11-04 and two on 2026-11-05. At `76e98ee` and `7cde05a` it lost a job to a 504 fetching a pinned tool, before any check in that job ran ([what happened](evidence/ci/README.md#the-504-on-a-pinned-tool)). One run with a planted `kind: Secret` went red, and 21 of 21 planted defects were caught on a real runner | No job on `on: pull_request`: GitHub holds the run for a pull request a workflow opens, with no jobs, and nobody has approved one. A commit after `6edde64` is covered by no run here |
| `images.yml` | Runs 41975430939 at `9c8e098` and 42044273310 at `76e98ee`, on `ubuntu-24.04-arm`: each built four images, walked them clean in a throwaway registry and again on GHCR, scanned them with exit 0, and published them as four private packages. The first opened pull request 1, the second force-updated it, and it stays open and unmerged. An earlier run, 41903137226, succeeded building nothing | With no credentials all four packages answered 401, at the first build, and the API that states a package's visibility was not read, because the local token lacks `read:packages`. `Build only` on a pull request has not run, neither prune deleted anything, and nothing has copied those digests to the local registry. They are not the digests deployed |
| `promote-prod-sim.yml` | Refused an invented digest and another image's digest (runs 41976950402, 41977025314). With the repository setting on since 2026-11-05, run 41977114312 opened pull request 2, closed unmerged as a test | No promotion pull request has been reviewed, merged or published. The real prod-sim promotions ran with `make promote` on this Mac |
| `wayline-upstream-check.yml` | NOT RUN | |

## GitHub Free limits

The repository is private on the GitHub Free plan. On that plan GitHub provides **no environments with required reviewers, no protected branches, no rulesets, no code owners, and no artifact attestations** for private repositories. The branch protection and ruleset APIs answer 403 here ([plan-facts](evidence/ci/plan-facts-20261104T204023Z.txt)), and the rest comes from GitHub's documentation.

**So prod-sim approval is a process, not a control.**

- `promote-prod-sim.yml` opens a pull request. A person merging it is the approval.
- GitHub cannot enforce that. Anyone with write access can merge their own pull request, push straight to `main`, or skip CI. `CODEOWNERS` does nothing on this plan, by GitHub's documentation, so it does not even request a review. That has not been tried on a pull request.
- A failing check does not block a merge.
- A pull request opened with `GITHUB_TOKEN` runs no CI of its own: GitHub holds the `ci` run with no jobs, as `action_required` ([record](evidence/ci/ci-1-20261105T060416Z-pull-request-runs.txt)). So those workflows run validation themselves before opening it.
- The repository setting that lets workflows create and approve pull requests has been on since 2026-11-05, which `promote-prod-sim.yml` needs ([plan facts](evidence/ci/plan-facts-20261105T062632Z.txt)). So a workflow's token could approve a pull request too, and here an approval enforces nothing anyway.
- Check suites from two third-party GitHub Apps, `netlify` and `builder-io-integration`, sit queued on pushed commits. As GitHub describes those Apps, netlify can have `contents` read, and Builder.io `contents`, `administration` and `workflows` write. What each installation really covers was not read, because the token gets 403 on installations ([record](evidence/ci/br-3-20261105T060937Z-apps.txt)). So their access is inferred from those check suites, and nothing shows that only the owner can read this repository. What to do about them is one of the [owner decisions still open](known-limitations.md#owner-decisions-still-open).

What is enforced lives in scripts: `scripts/promote.sh` and `scripts/ci/check-promoted-digests.sh` refuse a prod-sim digest never recorded for dev under that image, and `scripts/lib/dev-check.sh` refuses one `plane-dev` is not running, Synced and Healthy. `make gitops-publish` warns about commits that are not on `origin/main`, and goes on. Someone with shell access can bypass a script too. A script is a safeguard against mistakes, not a security boundary.

In Pass 1 a merge changes nothing running. It reaches the cluster only when someone pulls `main` and runs `make gitops-publish`.

## What is not protected

Plainly, so nobody assumes otherwise.

| Not protected | Consequence |
|---|---|
| Etcd at rest | Secrets are base64, not encrypted, on the node's disk |
| `.local/` | Secret zero, kubeconfig and the admin token are plain files. Permissions stop other users, not the same user |
| Backups | Plaintext API tokens and password hashes, unencrypted, on the same disk as everything else. No off-machine copy unless done by hand |
| TLS | None. All HTTP, in the cluster and at the ingress. The operator talks to Infisical in cleartext. Session cookies and tokens cross loopback unencrypted. Pass 2 terminates TLS at Cloudflare and the origin |
| UIs | Prometheus and Alertmanager have no authentication. They rely on loopback binding, and on a source-address list against pods. A local process or a page in a local browser may reach `*.localhost` |
| Git remote | `git://` is unauthenticated and unencrypted, with no signature verification. Whoever can write `.local/git` controls what Argo CD deploys |
| Registry | No authentication on `127.0.0.1:5001` |
| Audit | Infisical stores no audit logs on this tier. Kubernetes audit logging is not configured |
| Runtime detection | No Falco or equivalent. No admission control beyond PSA |
| Image content | A CVE scan runs by hand and in `images.yml`, and fails only on what is built here. Upstream images keep the findings above. No signature check, no SBOM |
| Tenant isolation | One kernel, one node, one etcd. See [Read this first](#read-this-first) |
| Availability | One node, one replica of everything. See [disaster-recovery.md](disaster-recovery.md) |
| Postgres least privilege | One shared superuser role per environment. The exporter connects with it too |
| Valkey | No password. A NetworkPolicy is the only control, and kindnet can fail open |
| SSRF | `ALLOW_INTERNAL_IP_CONNECTIONS=true` relaxes it across Infisical |
| Secret rotation | One value, on demand, by script, with an error window, about 38s for a signed-in session in dev ([runs](#secret-rotation-runs)) |
| Supply chain of upstream code | Plane, Infisical and chart contents are trusted as of their digest |

Limitations in full: [known-limitations.md](known-limitations.md). Test status: [validation.md](validation.md).
