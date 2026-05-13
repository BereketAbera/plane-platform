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
- **Traefik also allows `192.168.65.0/24`,** Docker Desktop's VM subnet, because the source address of NodePort traffic is known only at runtime.
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
| Fails open, silently | A broken dataplane looks like a working one. Only the sentinel catches it, and only when it is run. Between runs nothing watches for this |
| Layer 3 and 4 only | Traefik routes by Host header, so `plane-dev`'s api, which may reach Traefik, can request prod-sim's public host. The matrix records this as a known limit |
| `172.16.0.0/12` is broad | It covers every Docker network in the default pool, not just `kind`, on those named ports |
| Assumes Docker's default pool | A custom `default-address-pools` breaks it. The check in `cluster-up.sh` stops the bootstrap rather than failing later |
| Root on the node bypasses policy | `hostNetwork` pods are not evaluated. node-exporter runs that way, in `monitoring-agents` |
| No policies until Argo CD syncs | Namespaces exist from Terraform with no policy until wave -10 applies |
| Existing connections survive | A new rule does not cut an established connection |
| NodePort traffic from the host cannot be tested from a pod | `tests/e2e/smoke.py` covers that path instead |

**Namespace separation is not equivalent to independent production clusters.** Even with every rule working, both environments share a node, a kernel, an API server, etcd, a CNI, Traefik and Infisical. A container escape or a node-level failure affects both. NetworkPolicy reduces one class of risk. It does not create isolation of that kind.

Runtime items:

- Day-1 gate 2 records PASS on this host for three checks in a test namespace: traffic flows before any policy, default-deny blocks a new connection with a timeout, and an allow rule admits the labelled client. That step does not re-probe an unlabelled client, despite the word "only" in its output line. The node also shows the `kindnet-network-policies` nftables table ([evidence](../evidence/day1-gates.txt)). This shows enforcement exists on this kernel. It says nothing about the platform's own policy set.
- [[VERIFY: scripts/test-netpol.sh sentinel passes and the full matrix passes with every deny row ending in a timeout]]
- [[VERIFY: NodePort traffic reaches Traefik from an address inside the two allowed ranges, and which address it is]]
- [[VERIFY: operator token review works under default-deny with the node IP on 6443]]
- [[VERIFY: no kind issue 4222 connection stalls appear under the full policy set]]

The matrix holds 383 rows at the time of writing, 257 of them `deny`. Those counts are configuration, not results.
