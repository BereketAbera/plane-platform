# Troubleshooting

Problems with the platform itself: bringing it up, networking, images and tools. Plane's own behaviour is in [Plane app debugging](plane-app-debugging.md).

Preamble for raw commands:

```bash
export PATH="$PWD/.tools/bin:$PATH" KUBECONFIG="$PWD/.local/kubeconfig"
NODE=plane-platform-control-plane
```

Start with `make status`. It only reads, and it prints node, Applications, pods not ready, endpoints, memory and host disk.

Index:

- [kind network outside 172.16.0.0/12](#kind-network-outside-172160012)
- [`make up` or `make test` exits 127](#make-up-or-make-test-exits-127)
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

## `make up` or `make test` exits 127

**Symptom.** `./scripts/up.sh: No such file or directory`, or the same for `test.sh`.

**Why.** As of commit f733b87 the Makefile calls these scripts and they were not yet in the repository. Integration review B1 and B2 recorded this. [[VERIFY: scripts/up.sh and scripts/test.sh exist]]

**Fix.** Pull the latest `main`. If they are still missing, the design order is in [Clean rebuild](clean-rebuild.md#rebuild).

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

If only the second works, it is your resolver or browser. [[VERIFY: *.localhost works in Safari; Chrome and Firefox are the fallback]]

**Inside pods** the rule differs. CoreDNS rewrites `plane.dev.localhost` and `plane.prod-sim.localhost` to Traefik, because the API dials its own public host. Terraform owns the rewrite.

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
| NodePort source is not allowed by `traefik-ingress` | Policy allows `172.16.0.0/12` and `192.168.65.0/24`. See below |
| Node port mapping missing | `docker port "$NODE"` |
| Route missing | `kubectl get ingressroute -A` |

NodePort traffic reaches Traefik with its pre-SNAT source, so a default-deny in `traefik` must allow an `ipBlock`, not only the node (critique section 1.6). [[VERIFY: NodePort traffic is admitted by the traefik-ingress policy from this Docker Desktop setup]]

Compare the node's view with the host's, and leave the policies in place while you do. From the node:

```bash
docker exec "$NODE" curl -sS -o /dev/null -w '%{http_code}\n' -H 'Host: plane.dev.localhost' http://127.0.0.1:30080/
docker exec "$NODE" nft list table inet kindnet-network-policies | head -40
kubectl -n traefik logs deploy/traefik --tail=30
```

Note that `meta skuid 0 accept` means root sockets in the node's network namespace skip policy evaluation, so the first command can pass while real traffic is dropped. Never use a `hostNetwork` pod or a root process on the node to test policy.

## NetworkPolicy seems not to be enforced

**Why this needs care.** kindnet enforces policy through nftables with `FailOpen: true`. Errors log `skipping network policies` and traffic continues, so a broken dataplane looks like a working one. Only new connections are evaluated. The day-1 gates in [`docs/evidence/day1-gates.txt`](../evidence/day1-gates.txt) record a sentinel deny case on this host, with no platform deployed, so they say nothing about the platform's own policies.

```bash
make test-netpol
kubectl -n kube-system logs daemonset/kindnet --tail=200 | grep -i 'skipping network policies'
docker exec "$NODE" nft list tables
```

`kube-system` logs do not go to Loki, so use `kubectl logs` here.

**When testing by hand:**

- Assert a deny by **timeout**, with a new connection.
- Test from an ordinary pod, never from `hostNetwork`.
- Do not trust a test on an existing connection.

`make test-netpol` classifies a DNS failure as INCONCLUSIVE and exits non-zero. Read which it was. [[VERIFY: make test-netpol passes its full allow and deny matrix]]

**Fallback, if enforcement really fails.** The research names Calico, at the cost of more memory. That would be a change to the kind config and to the contract.

## Image pull errors

| Symptom | Cause | Fix |
|---|---|---|
| `ErrImagePull` with 429 | Docker Hub quota. The window is not settled: docs say 100 per 6 hours, while the header showed a 3600-second window | The mirror chain falls back to Hub. Wait, or read `ratelimit-remaining` |
| Blob 404 from `mirror.gcr.io` | The mirror has the manifest but not the blob. It was seen for `plane-live` and the operator during research | containerd should fall through to the `server` in `hosts.toml`. Check `infrastructure/kind/containerd-certs.d/docker.io/hosts.toml` |
| `localhost:5001/wayline/...` not found | Branded digest was never pushed | `make images`, or `scripts/ci/copy-to-local-registry.sh`. Promotion checks this unless `SKIP_REGISTRY_CHECK=yes` |
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
| `exceeded quota` | ResourceQuota is computed in `infrastructure/terraform/modules/foundation/main.tf`, with room for rollout surge. A backup or test pod can use up the last slot. [[VERIFY: quota fits exporters, surge and a backup Job at once; integration review m5 counted 22 of 22 pods]] | Wait for the rollout, or update the Terraform table and apply |
| `container has runAsNonRoot and image will run as root` | Image has no `USER`, and the patch sets none | Set `runAsUser` in the hardening patch |
| `Read-only file system` | A path needs an `emptyDir` | Add it in the hardening patch |

`restricted` warnings in namespace events are expected. Warn and audit are `restricted`, and enforce is `baseline`. Tighten prod-sim only after a per-workload test passes (contract section 2).

```bash
kubectl -n plane-dev describe resourcequota
kubectl get events -A --field-selector reason=FailedCreate --sort-by=.lastTimestamp | tail
```

## Infisical bootstrap or operator problems

| Symptom | Cause | Fix |
|---|---|---|
| Bootstrap stops on an `InfisicalAuth` mismatch | Rendered overlay disagrees with `plane-infisical-auth` or the identity Secret | Fix the overlay. The error names the field |
| Infisical OOM-killed at first boot | About 603 migrations under a 1 GiB limit | See [Memory pressure](memory-pressure.md) |
| Pods wait in `CreateContainerConfigError` | Secret not synced yet | `kubectl -n plane-dev get infisicalstaticsecrets`, operator logs |
| Operator crash-looping in `plane-prod-sim` only | CRDs arrive from the dev release | Recovers once they exist |
| 403 on secrets | Identity or project mismatch. Per-project isolation is the free-tier boundary | Check `.local/secret-zero/infisical-machine.json` values against the overlay, without printing secrets |
| 429 | Reads are limited to 60 and secret requests to 40 a minute per client IP | Scripts honour `Retry-After`. Wait |
| Token review fails on a new cluster | Kubernetes Auth stores the old cluster's CA | Re-run `scripts/infisical-bootstrap.sh` |

```bash
kubectl -n infisical get pods
curl -s -o /dev/null -w '%{http_code}\n' http://infisical.localhost/api/status
kubectl -n plane-dev logs -l app.kubernetes.io/name=secrets-operator --tail=30
kubectl -n plane-dev get infisicalstaticsecrets -o json | jq -r '.items[] | "\(.metadata.name) \(.status.conditions // [] | map("\(.type)=\(.status)") | join(","))"'
```

More in `infisical/README.md`, including its recovery table.

## `kubectl top` fails

**Why.** It needs metrics-server, wave -8, with `--kubelet-insecure-tls` because kind's kubelet certificates are not signed by the cluster CA. metrics-server runs in `kube-system`, which the contract's namespace table does not list.

```bash
kubectl -n kube-system get deploy metrics-server
kubectl get apiservice v1beta1.metrics.k8s.io
```

## Terraform problems

| Symptom | Cause | Fix |
|---|---|---|
| Plan wants to create what exists | State lost. State lives in `.local/terraform/`. `make destroy` removes it on purpose | Import, or rebuild |
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
