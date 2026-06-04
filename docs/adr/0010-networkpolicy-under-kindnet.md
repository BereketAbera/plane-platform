# 0010. NetworkPolicy under kindnet, and its limits

**Status:** Accepted, 2026-11-04. Runtime validation pending where marked.

## Context

Two environments in one cluster need a network boundary. The usual answer is to replace the CNI with Calico or Cilium, which costs memory on a laptop that is already tight.

kind v0.33.0's kindnetd wires in `kube-network-policies` (`images/kindnetd/cmd/kindnetd/main.go`, research, 2026-11-04), and the kernel has the nftables features it needs. So enforcement is available with no extra component. The catch is how it behaves, as read from `pkg/dataplane/controller.go` at the pinned commit:

| Behaviour | Source | Consequence |
|---|---|---|
| `FailOpen: true`. Errors log `skipping network policies` and continue | `main.go` | If setup breaks, everything flows and nothing visibly fails |
| Evaluated in `postrouting`, priority `srcnat - 5`, after DNAT and before SNAT | lines 521-530 | Rules see pod IP and target port. Egress to the API server appears as the node IP on 6443, not `10.96.0.1:443` |
| `meta skuid 0 accept` | lines 633-647 | Root sockets in the node's network namespace skip evaluation. A `hostNetwork` pod proves nothing |
| Only new connections, since `StrictMode` is unset | lines 33-40 | Applying a policy does not cut an open connection, and each test needs a new one |

## Decision

Keep kindnet, and enforce NetworkPolicy through it. Treat enforcement as something that must be demonstrated on every run, not assumed.

- **Default deny in every platform namespace**, ingress and egress, with explicit allows, in `gitops/platform/network-policies/`. `kube-system` gets no namespace default-deny, because it holds kind's own components. Only metrics-server has a policy there.
- **The `platform` AppProject owns all policies**, at wave -10. Plane projects cannot create or change one. So a compromised Plane Application cannot open its own network.
- **Node-sourced traffic uses `172.16.0.0/12`,** Docker's default pool, on named ports only: 6443, 9418, 10250 and NodePort traffic to Traefik. Docker assigns the `kind` network a free `/16` that differs per machine, so a committed manifest cannot pin it. `scripts/cluster-up.sh` fails if the network is outside that range.
- **Traefik also allows `192.168.65.0/24`,** Docker Desktop's VM subnet, because the source address of NodePort traffic is known only at runtime. (Removed on 2026-11-04, once a run had measured it. See the last section.)
- **A sentinel comes first.** `scripts/test-netpol.sh` is written to prove in a throwaway namespace that a policy blocks, and that the script can tell a block from other failures. Only then does it run `tests/network-policy-matrix.yaml`.
- **Verdicts are strict.** A `deny` passes only on a timeout, because a refusal means the packet arrived. A DNS failure is inconclusive and fails the run.

## Alternatives considered

| Alternative | Why not |
|---|---|
| Calico or Cilium | Stronger and better known, and closer to what Pass 2 might use. More memory on the node. Calico remains the fallback if kindnet enforcement proves unreliable. Not measured here |
| No NetworkPolicy, namespaces only | No network boundary between environments at all |
| Policies shipped inside each Plane Application | Lets an environment change its own boundary. CRITIQUE.md C9 moved them to the `platform` project |
| Pinning the exact Docker `/16` | Differs per machine, so committed manifests would break elsewhere |

## Consequences

These limits apply however well the policies are written.

| Limit | Effect |
|---|---|
| Fails open, silently | A broken dataplane looks like a working one. The sentinel catches it when it is run. Between runs, alert `KindnetSkippedNetworkPolicies` watches for kindnet's one log line, added on 2026-11-04. It sees only that line, and it has been proven with a synthetic line, not a real failure |
| Layer 3 and 4 only | Traefik routes by Host header, so `plane-dev`'s api, which may reach Traefik, can request prod-sim's public host. The matrix records this as a known limit |
| `172.16.0.0/12` is broad | It covers every Docker network in the default pool, not just `kind`, on those named ports |
| Assumes Docker's default pool | A custom `default-address-pools` breaks it. The check in `cluster-up.sh` stops the bootstrap rather than failing later |
| Root on the node bypasses policy | `hostNetwork` pods are not evaluated. node-exporter runs that way, in `monitoring-agents` |
| No policies until Argo CD syncs | Namespaces exist from Terraform with no policy until wave -10 applies |
| Existing connections survive | A new rule does not cut an established connection |
| NodePort traffic from the host cannot be tested from a pod | `tests/e2e/smoke.py` covers that path instead |

**Namespace separation is not equivalent to independent production clusters.** Even with every rule working, both environments share a node, a kernel, an API server, etcd, a CNI, Traefik and Infisical. A container escape or a node-level failure affects both. NetworkPolicy reduces one class of risk. It does not create isolation of that kind.

Runtime items:

- Day-1 gate 2 records PASS on this host on 2026-11-04, with the platform's 60 policies loaded, in a test namespace: traffic flows before any policy, default-deny times out a new connection while a reference answers the same client and the node reaches the target, and under the allow rule the labelled client connects while an unlabelled one times out. The node also shows the `kindnet-network-policies` nftables table ([day1-gates-20261104T231136Z.txt](../evidence/day1-gates-20261104T231136Z.txt)). Loss only on the target's path would read the same as a block, and the script says so. This shows enforcement exists on this kernel. It says nothing about the platform's own rules.
- The sentinel passes before every run of `scripts/test-netpol.sh`. Rows from both Plane namespaces, `monitoring` and `infisical` pass with every deny row ending in a timeout. Rows from `argocd`, `traefik` and `kube-system` have no published run on the complete platform, so the whole matrix is not proven yet. One run on 2026-11-05 did cover all 418 rows, with all 292 deny rows ending in a timeout, and its file is still in `.local/evidence-raw/`. [Security](../security.md#networkpolicy-model) has the table. [[VERIFY: scripts/test-netpol.sh sentinel passes and the full matrix passes with every deny row ending in a timeout]]
- NodePort traffic reaches Traefik from `172.24.0.1`, the kind gateway, inside `172.16.0.0/12`. The second range played no part ([traefik-nodeport-source-1.txt](../evidence/runs/traefik-nodeport-source-1.txt)).
- Operator token review works under default-deny with the node IP on 6443 ([infisical-isolation-3.txt](../evidence/runs/infisical-isolation-3.txt), [netpol-real-pods-1.txt](../evidence/runs/netpol-real-pods-1.txt)).
- [[VERIFY: no kind issue 4222 connection stalls appear under the full policy set]]

The matrix holds 418 rows since `01ab74c`, 292 of them `deny`. Those counts are configuration, not results.

## What we found when we ran it

Added 2026-11-05. The decision stands. kindnet enforced the full policy set on the real cluster, and no row needed a change of CNI.

- **The second range was never needed.** With `172.16.0.0/12` removed from the live policy, a request from the host timed out while `192.168.65.0/24` was still allowed, so `2d77243` removed it. Self-heal restored the live policy within 6s of being turned back on.
- **Evaluation is after DNAT, as read.** Dialling `10.96.0.1:443` connects under a rule that allows only 6443, and repo-server, with no such rule, times out ([netpol-real-pods-1.txt](../evidence/runs/netpol-real-pods-1.txt)).
- **A timeout alone was not enough.** A probe's timeout cannot tell a policy from a target that is down, and an allow row to a Service with no ready endpoint read as a FAIL. Since `01ab74c` each probe has references at the same moment, and such rows read INCONCLUSIVE ([harness-netpol-fixtures-1.txt](../evidence/runs/harness-netpol-fixtures-1.txt)). The results above predate that for the Plane namespaces.
- **One more way out.** A scratch pod with free egress reached Prometheus through `host.docker.internal:80`, because that leaves through the Mac and comes back as the host ([h17-doors-free-egress-2.txt](../evidence/runs/h17-doors-free-egress-2.txt)). The matrix has denied that for Plane workloads since `01ab74c`.
- **Valkey's `Possible SECURITY ATTACK` log line is this test.** The matrix's HTTP probes cause it, and one direct request reproduced it ([plane-prod-sim-valkey-security-line-1.txt](../evidence/runs/plane-prod-sim-valkey-security-line-1.txt)).
