# Troubleshooting

Problems with the platform itself: bringing it up, networking, images and tools. Plane's own behaviour is in [Plane app debugging](plane-app-debugging.md).

Preamble for raw commands:

```bash
export PATH="$PWD/.tools/bin:$PATH" KUBECONFIG="$PWD/.local/kubeconfig"
NODE=plane-platform-control-plane
```

Start with `make status`. It only reads, and it prints node, Applications, pods not ready, endpoints, memory and host disk. A first boot has states that look broken and are not: see [install.md](../install.md#what-looks-broken-but-is-expected).

Index:

- [kind network outside 172.16.0.0/12](#kind-network-outside-172160012)
- [Tool not found, or the wrong cluster](#tool-not-found-or-the-wrong-cluster)
- [Port 80, 443 or 5001 is taken](#port-80-443-or-5001-is-taken)
- [Hostnames do not resolve](#hostnames-do-not-resolve)
- [UIs time out, or everything through Traefik fails](#uis-time-out-or-everything-through-traefik-fails)
- [NetworkPolicy seems not to be enforced](#networkpolicy-seems-not-to-be-enforced)
- [Image pull errors](#image-pull-errors)
- [Pods rejected by Pod Security or quota](#pods-rejected-by-pod-security-or-quota)
- [Infisical bootstrap or operator problems](#infisical-bootstrap-or-operator-problems)
- [`kubectl top` fails](#kubectl-top-fails)
- [Terraform problems](#terraform-problems)

## kind network outside 172.16.0.0/12

**Symptom.** `scripts/cluster-up.sh` stops with `kind network is <subnet>, outside 172.16.0.0/12 that NetworkPolicies allow`.

**Why.** Docker gives the `kind` network a free `/16`, which differs per machine. NetworkPolicies do not pin that network. They allow Docker's default pool, `172.16.0.0/12`, for node-sourced traffic: API server on 6443, Git on 9418, and NodePort traffic to Traefik. A custom daemon pool would break those silently, so the script stops here.

**Diagnose.**

```bash
docker network inspect kind --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}'
docker info --format '{{json .DefaultAddressPools}}'
docker network inspect kind --format '{{range $id, $c := .Containers}}{{$c.Name}} {{end}}'
```

**Fix.** Pick one:

1. Put the daemon back on a pool inside `172.16.0.0/12`. In Docker Desktop, edit Settings, Docker Engine, `default-address-pools`. Then recreate the network. It is shared by everything attached to it, so check the list from the last command first:

   ```bash
   make destroy CONFIRM=yes
   REPO_ROOT="$PWD" docker compose -f infrastructure/local-services/compose.yaml down
   docker network rm kind
   make up
   ```

2. Keep your pool and change the policies: replace `172.16.0.0/12` in `gitops/platform/network-policies/` and in `scripts/cluster-up.sh`, then commit and publish. This changes a contract value (section 3), so update the contract too.

**Confirm.** `make up` prints `kind network <subnet> is inside 172.16.0.0/12`.

**Do not** remove the check in `scripts/cluster-up.sh`. The failure it prevents shows up later as unexplained timeouts.

## Tool not found, or the wrong cluster

**Symptom.** `kubectl: command not found`, a version skew warning, or `kubectl` answering about another cluster.

**Why.** Pinned tools live in `.tools/bin`. The kubeconfig lives in `.local/kubeconfig`. Scripts set both, but your shell does not.

```bash
make setup
export PATH="$PWD/.tools/bin:$PATH" KUBECONFIG="$PWD/.local/kubeconfig"
kubectl config current-context
```

The context must be `kind-plane-platform`. If the file is gone and the cluster exists:

```bash
kind export kubeconfig --name plane-platform --kubeconfig .local/kubeconfig
```

**Do not** merge this into `~/.kube/config`. The design keeps it out on purpose.

## Port 80, 443 or 5001 is taken

**Symptom.** `kind create cluster` fails to bind, the registry does not start, or `scripts/prereqs.sh` reports a holder.

```bash
lsof -nP -iTCP:80 -sTCP:LISTEN
lsof -nP -iTCP:443 -sTCP:LISTEN
lsof -nP -iTCP:5001 -sTCP:LISTEN
```

**Fix.** Stop that service. Ports are fixed by the kind template and the Compose file, and contract section 3 relies on them. Port 80 needs `com.docker.vmnetd`, installed by Docker Desktop.

**Do not** change the `listenAddress` from `127.0.0.1`. Kind's default of `0.0.0.0` would expose UIs with no login to the network.

## Hostnames do not resolve

**Symptom.** `plane.dev.localhost` fails in a browser or from a tool.

**Why.** `*.localhost` should resolve to loopback with no `/etc/hosts` entry. curl handles it itself. Browsers differ.

```bash
curl -sS -o /dev/null -w '%{http_code}\n' http://plane.dev.localhost/
curl -sS -o /dev/null -w '%{http_code}\n' -H 'Host: plane.dev.localhost' http://127.0.0.1/
dscacheutil -q host -a name plane.dev.localhost
```

If only the second works, it is your resolver or browser. Chromium resolved them in the browser session on 2026-11-05 ([live-dev](../evidence/branding/live-dev/README.md)). Safari could not be driven from that session, so it has not been tried (`.local/evidence-raw/AUTH-4-20261105T062750Z.txt`, not yet published). [[VERIFY: *.localhost works in Safari; Chrome and Firefox are the fallback]]

**Inside pods** the rule differs. CoreDNS rewrites `plane.dev.localhost` and `plane.prod-sim.localhost` to Traefik, because the API dials its own public host. Terraform owns the rewrite. The API pod resolved its host to Traefik's Service address on 2026-11-04, and a worker, with no policy route to Traefik, timed out ([plane-dev-copy-object-path-1.txt](../evidence/runs/plane-dev-copy-object-path-1.txt)).

```bash
kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' | grep rewrite
```

**Do not** add these to `/etc/hosts`. It hides resolver problems and is not needed.

## UIs time out, or everything through Traefik fails

**Symptom.** All hosts hang or fail, including `argocd.localhost`.

**Why, most to least likely.**

| Cause | Check |
|---|---|
| Traefik is not up yet | `kubectl -n traefik get pods`, `make status` |
| NodePort source is not allowed by `traefik-ingress` | Policy allows `172.16.0.0/12`. See below |
| Node port mapping missing | `docker port "$NODE"` |
| Route missing | `kubectl get ingressroute -A` |

NodePort traffic reaches Traefik with the kind gateway as its source, so a default-deny in `traefik` must allow an `ipBlock`, not only the node. Measured on 2026-11-04 with conntrack: the source is `172.24.0.1` on this host, and with `172.16.0.0/12` removed from the live policy the host's request timed out until self-heal put it back ([traefik-nodeport-source-1.txt](../evidence/runs/traefik-nodeport-source-1.txt)). `192.168.65.0/24` was allowed at first too, and that test showed it was not the source, so it is gone.

**A UI answers 403.** Argo CD, Grafana, Prometheus, Alertmanager and Infisical each have a `node-network-only` Middleware that admits only `172.16.0.0/12`. The host gets 200, and a pod gets 403 from Traefik, which is correct ([routes-after-2.txt](../evidence/runs/routes-after-2.txt)). `scripts/test.sh routes` checks both sides. A route that names a missing Middleware answers 404, so it fails closed ([h17-fail-closed-1.txt](../evidence/runs/h17-fail-closed-1.txt)).

Compare the node's view with the host's, and leave the policies in place while you do. From the node:

```bash
docker exec "$NODE" curl -sS -o /dev/null -w '%{http_code}\n' -H 'Host: plane.dev.localhost' http://127.0.0.1:30080/
docker exec "$NODE" nft list table inet kindnet-network-policies | head -40
kubectl -n traefik logs deploy/traefik --tail=30
```

Note that `meta skuid 0 accept` means root sockets in the node's network namespace skip policy evaluation, so the first command can pass while real traffic is dropped. Never use a `hostNetwork` pod or a root process on the node to test policy.

## NetworkPolicy seems not to be enforced

**Why this needs care.** kindnet enforces policy through nftables with `FailOpen: true`. Errors log `skipping network policies` and traffic continues, so a broken dataplane looks like a working one. Only new connections are evaluated. The day-1 gates test a throwaway policy, not the platform's own ([day1-gates-20261104T231136Z.txt](../evidence/day1-gates-20261104T231136Z.txt)). `make test-netpol` tests the platform's.

```bash
make test-netpol
make test-netpol FROM_NS=plane-dev
kubectl -n kube-system logs daemonset/kindnet --tail=200 | grep -i 'skipping network policies'
docker exec "$NODE" nft list tables
```

Of `kube-system`, Loki gets only kindnet's `skipping network policies` line, so use `kubectl logs` here.

**What the alerts see.** Alloy counts kindnet's lines. `KindnetSkippedNetworkPolicies` fires on that one line, and `KindnetLogsNotRead` fires when no line has been counted for 15m, so the tail itself is watched. They see nothing else, so `make test-netpol`, which sends real traffic, stays the real check. `KindnetSkippedNetworkPolicies` was proved with a synthetic line from a scratch pod, firing to resolved, not a real kindnet failure ([h18-synthetic-2.txt](../evidence/runs/h18-synthetic-2.txt), [kindnet-hold-1.txt](../evidence/runs/kindnet-hold-1.txt)). `KindnetLogsNotRead` has only gone pending, and a synthetic line cannot exercise it.

The count stands for a pod name, so `KindnetSkippedNetworkPolicies` can stick after kindnet's container restarts healthy in the same pod. Run `make test-netpol`. If it passes, replace the pod:

```bash
kubectl -n kube-system delete pod -l app=kindnet
```

The count stops applying 5 minutes after its pod has gone. On a scratch pod the resolved line reached the sink 321s after the delete ([kindnet-hold-1.txt](../evidence/runs/kindnet-hold-1.txt)). In the other direction, an in-place Alloy restart forgets the count, so the rule holds it for 3 days. `monitoring/README.md` has the detail.

**When testing by hand:**

- Assert a deny by **timeout**, with a new connection.
- Test from an ordinary pod, never from `hostNetwork`.
- Do not trust a test on an existing connection.

`make test-netpol` proves its sentinel in a throwaway namespace first. A deny row passes only on a timeout, and INCONCLUSIVE is never a pass: `scripts/test-netpol.sh` exits 0 when every row passed, 1 when a row or the sentinel failed, and 2 when nothing failed but a row was INCONCLUSIVE. There is one exception: a row that needs something outside the cluster still reads INCONCLUSIVE offline, and does not make the run non-zero, when neither of the node's two readings reached the target. If either reached it, the row counts, so a flaky outside target can give exit 2. So an exit 0 can carry such rows. On an exit 0, read how many the summary says "need something outside the cluster".

`make test-netpol` passes its full allow and deny matrix. On 2026-11-05 at 04:19Z it exited 0 with 418 PASS, 0 FAIL and 0 INCONCLUSIVE, none needing anything outside the cluster, and no deny row passing without a reference: `plane-dev` 153, `plane-prod-sim` 151, `monitoring` 50, `traefik` 28, `argocd` 19, `infisical` 14 and `kube-system` 3 (`.local/evidence-raw/harness-make-test-netpol-4.txt`, `.local/evidence-raw/netpol-20261105T041921Z.tsv`, not yet published). A deny PASS is a timeout while both references answered, so it cannot rule out loss only on that pod's path to that target. That run came before the final images were promoted. Earlier runs, published and by source namespace, are [`plane-dev`](../evidence/runs/netpol-20261104T232752Z.tsv), [`plane-prod-sim`](../evidence/runs/netpol-20261104T233304Z.tsv), [`monitoring`](../evidence/runs/netpol-20261104T221150Z.tsv) and [`infisical`](../evidence/runs/netpol-20261104T215857Z.tsv).

**Fallback, if enforcement really fails.** The research names Calico, at the cost of more memory. That would be a change to the kind config and to the contract.

## Image pull errors

| Symptom | Cause | Fix |
|---|---|---|
| Pods sit in `ContainerCreating` for minutes, one after another | The kubelet pulls one image at a time. Four new images took 175s, 216s, 52s and 5s in turn on the first boot, 448s for the last ([plane-prod-sim-firstboot-1.txt](../evidence/runs/plane-prod-sim-firstboot-1.txt)) | Wait. The rollout deadline is 600s, and a retry recovers a miss, about a minute after it (`.local/evidence-raw/DEP-1-20261105T062323Z-timeline.txt`) |
| `ErrImagePull` with 429 | Docker Hub quota. The window is not settled: docs say 100 per 6 hours, while the header showed a 3600-second window | The mirror chain falls back to Hub. Wait, or read `ratelimit-remaining` |
| Blob 404 from `mirror.gcr.io` | The mirror has the manifest but not the blob. It was seen for `plane-live` and the operator during research | containerd should fall through to the `server` in `hosts.toml`. Check `infrastructure/kind/containerd-certs.d/docker.io/hosts.toml` |
| `localhost:5001/wayline/...` not found | Branded digest was never pushed. Dev's overlay names these since `4f622e3`, and prod-sim's since `0af8956` | `make images`, or `scripts/ci/copy-to-local-registry.sh`. Promotion checks this unless `SKIP_REGISTRY_CHECK=yes`, and `make up` checks it before it publishes. A rebuild can give other digests, and `make up` then prints what to do |
| A push to `plane-registry` dies, or the container restarts | A push fills the container's memory with dirty page cache. Its limit is 512m since a real push was OOM-killed at 128m ([registry-memory-1.txt](../evidence/runs/registry-memory-1.txt)) | It restarts by itself. Push again, and leave its `registry-data` volume alone: the branded images exist nowhere else |
| Digest resolves, pull fails with connection errors | `plane-registry` or a `plane-mirror-*` is stopped, or not on the `kind` network | See below |
| A pod uses a tag with no digest | Policy violation. Every image is pinned by digest | Run `make ci` |

```bash
docker ps --filter name=plane- --format '{{.Names}} {{.Status}}'
docker network inspect kind --format '{{range $id, $c := .Containers}}{{$c.Name}} {{end}}'
docker exec "$NODE" crictl pull docker.io/library/busybox:1.37.0@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec
docker exec "$NODE" cat /etc/containerd/certs.d/docker.io/hosts.toml
```

`docker login` on the Mac does not help pods. kind nodes pull with their own containerd, and a mounted config must hold real `auths`, with no credential helper.

**Do not** use `kind load`. It cannot work with this host's containerd image store (kind #3795, contract section 5).

## Pods rejected by Pod Security or quota

| Message | Cause | Fix |
|---|---|---|
| `violates PodSecurity "baseline:latest"` | A pod uses `hostPath`, `hostNetwork` or privileged | Only `monitoring-agents` is `privileged`. Backup pods mount a PVC backed by a static hostPath PV, to stay compatible |
| `exceeded quota` | ResourceQuota is computed in `infrastructure/terraform/modules/foundation/main.tf`: 2732Mi requests, 7984Mi limits and 24 pods per Plane namespace. All seven Deployments surging at once reached 21 pods, 2412Mi and 6960Mi, with no `FailedCreate` ([plane-dev-rollout-quota-1.txt](../evidence/runs/plane-dev-rollout-quota-1.txt)). The sum for everything at once, with both exporters surging, the migrator, a backup and an ad-hoc pod, is 26 pods, 2760Mi and 8064Mi, which is over ([quota-budget-1.txt](../evidence/runs/quota-budget-1.txt)). That is arithmetic on the renders, and no run has put a backup on a full surge | Wait for the rollout, or update the Terraform table and apply |
| `container has runAsNonRoot and image will run as root` | Image has no `USER`, and the patch sets none | Set `runAsUser` in the hardening patch |
| `Read-only file system` | A path needs an `emptyDir` | Add it in the hardening patch |

Warn and audit are `restricted`, and enforce is `baseline`. A server dry run of `restricted` gave no warning for the running pods in either Plane namespace on 2026-11-04, and each workload ran as its intended non-root UID ([plane-dev-psa-1.txt](../evidence/runs/plane-dev-psa-1.txt), [plane-prod-sim-host-and-identity-1.txt](../evidence/runs/plane-prod-sim-host-and-identity-1.txt)). That is the test contract section 2 asks for before tightening prod-sim. No label has changed.

```bash
kubectl -n plane-dev describe resourcequota
kubectl get events -A --field-selector reason=FailedCreate --sort-by=.lastTimestamp | tail
```

## Infisical bootstrap or operator problems

| Symptom | Cause | Fix |
|---|---|---|
| Bootstrap stops on an `InfisicalAuth` mismatch | Rendered overlay disagrees with `plane-infisical-auth` or the identity Secret | Fix the overlay. The error names the field |
| Infisical killed for memory at first boot | Not seen: 602 migrations in 11.5s, a peak of 807 MiB of 1 GiB, and 0 OOM kills ([infisical-firstboot-1.txt](../evidence/runs/infisical-firstboot-1.txt)) | See [Memory pressure](memory-pressure.md) |
| Pods wait in `CreateContainerConfigError` | Secret not synced yet | `kubectl -n plane-dev get infisicalstaticsecrets`, operator logs |
| Operator crash-looping in `plane-prod-sim` only | CRDs arrive from the dev release. Predicted from the chart, and not seen on the first boot | Recovers once they exist |
| 403 on secrets | Identity or project mismatch. Per-project isolation is the free-tier boundary | Check `.local/secret-zero/infisical-machine.json` values against the overlay, without printing secrets |
| 429 | Not expected here. The rate limiter is not registered on self-hosted: 240 reads in 4s from one address all answered 200 ([infisical-rate-limit-1.txt](../evidence/runs/infisical-rate-limit-1.txt)). The scripts' `Retry-After` handling has never run for real | Look for something in front of Infisical |
| Token review fails on a new cluster | Kubernetes Auth stores the old cluster's CA | Re-run `scripts/infisical-bootstrap.sh` |

```bash
kubectl -n infisical get pods
curl -s -o /dev/null -w '%{http_code}\n' http://infisical.localhost/api/status
kubectl -n plane-dev logs -l app.kubernetes.io/name=secrets-operator --tail=30
kubectl -n plane-dev get infisicalstaticsecrets -o json | jq -r '.items[] | "\(.metadata.name) \(.status.conditions // [] | map("\(.type)=\(.status)") | join(","))"'
```

More in `infisical/README.md`, including its recovery table.

## `kubectl top` fails

**Why.** It needs metrics-server, wave -8, with `--kubelet-insecure-tls` because kind's kubelet certificates are not signed by the cluster CA. metrics-server is the one platform workload outside the contract's namespace table: it runs in `kube-system`.

```bash
kubectl -n kube-system get deploy metrics-server
kubectl get apiservice v1beta1.metrics.k8s.io
```

## Terraform problems

| Symptom | Cause | Fix |
|---|---|---|
| Plan wants to create what exists | State lost. State lives in `.local/terraform/`. `make destroy` removes `.local/terraform/local` on purpose, and keeps `.local/terraform/infisical`, because a clean restore needs it | Import, or rebuild |
| Plan is against resources that are gone | Cluster deleted by hand | Remove the stale state with `make destroy CONFIRM=yes SKIP_BACKUP=yes`. It tolerates a missing cluster |
| Infisical project slug conflict | A destroyed project keeps its slug for 14 days | Use a fresh instance |

Terraform here creates namespaces and labels, quotas, the CoreDNS rewrite, the Argo CD release, projects and the root Application. It does **not** create the cluster, which is the kind CLI, or the workloads, which are Argo CD. See [Terraform](../terraform.md).

## Still stuck

Gather this before asking:

```bash
make status
kubectl get events -A --sort-by=.lastTimestamp | tail -30
kubectl -n argocd get applications
docker stats --no-stream
df -h .
```

Check Secrets and tokens are not in what you share.
