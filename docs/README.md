# Documentation index

This is the documentation for Wayline, a customized Plane Community Edition v1.4.3 deployment. The application is Plane CE, not an original product. It runs in three environments:

| Environment | Where | How to reach it |
|---|---|---|
| `dev` | Namespace `plane-dev` of a kind cluster on the owner's Mac, started with `make up` | <http://plane.dev.localhost>, from the Mac only |
| `prod-sim` | Namespace `plane-prod-sim` of the same cluster, the target of local promotion, which simulates production | <http://plane.prod-sim.localhost>, from the Mac only |
| Hosted production, `plane-prod` | One K3s node on the owner's Contabo VPS, since 2026-11-07 | <https://wayline.bereket.dev>, with <https://grafana.bereket.dev> and, from 2026-11-07, <https://infisical.bereket.dev>. Every other console through `make remote-ui TARGET=plane-prod UI=<name>` |

The local two share one cluster, so namespace separation there is not equivalent to independent production clusters. Hosted production is a cluster of its own, with no high availability. [environments.md](environments.md) says what differs, row by row.

**Read next:** the [repository README](../README.md) for the overview, status and quick start; [environments.md](environments.md); [architecture.md](architecture.md), with hosted production in [section 9](architecture.md#9-hosted-production); and [platform-contract.md](platform-contract.md), which is binding. To install and run each environment, [install.md](install.md), with hosted production's scripts in [scripts/hosted/README.md](../scripts/hosted/README.md).

The Hetzner and Cloudflare plan of Pass 1 was not built, and no Hetzner or Cloudflare resource exists. Hosted production went to Contabo, with DNS in Vercel through Terraform, and TLS in Traefik on the node with cert-manager and Let's Encrypt.

## How to read these documents

**Sources of truth, in order:**

1. [platform-contract.md](platform-contract.md) is binding for names, ownership, and ordering. If code and the contract disagree, one of them is a bug.
2. The code decides what actually happens.
3. [evidence/](evidence/README.md) decides what actually happened. A claim about runtime behaviour needs a capture there, with its date and command. By [the evidence rules](evidence/README.md#rules), a run still under `.local/evidence-raw/` has no result until `make publish-evidence` copies it, or `make remote-publish-evidence TARGET=plane-prod` for a run on hosted production.

**Result labels**, from [contract section 12](platform-contract.md#12-evidence-rule), as [validation.md](validation.md#status-values) defines them:

| Label | Meaning |
|---|---|
| PASS | The test ran, met its criterion, and its raw output is in [`docs/evidence/`](evidence/README.md) |
| FAIL | The test ran and the system misbehaved |
| BLOCKED | The test could not run or finish because something it depends on failed or is missing. This says nothing about the system under test |
| NOT RUN | The test was not attempted, or it was attempted and no evidence was captured |

A row reading PENDING names a hosted run planned for the night of 2026-11-07 that had not run when the page was written. It is not a result. Its run gives it one of the four labels, and that counts as a result once its evidence is in [`docs/evidence/`](evidence/README.md) ([contract section 12](platform-contract.md#12-evidence-rule)).

**Inline markers.** These documents were written alongside the code and reconciled against evidence as runs finished. They used two markers in double square brackets: VERIFY, for a claim depending on a runtime result not yet confirmed, and MEASURE, for a number not yet measured. On 2026-11-05 the cold install and the second full restore answered what they could, and each marker became its answer and citation, or a plain sentence saying no run read it ([summary](evidence/runs/clean-install-20261105T105546Z/summary.txt), [disk](evidence/runs/clean-install-20261105T105546Z/disk-after-install.txt), [restore](evidence/runs/restore-clean-20261105T124518Z.json)). If one is left, do not treat it as true.

**The last drill has finished.** `make drill-clean-restore CONFIRM=yes LOSE_CLUSTER=yes`, from 13:06Z to 13:35Z at `06b8be7`, read `RESULT PASS`, `make` exit 0, with every restore step PASS ([output](evidence/runs/BKP-6-20261105T130633Z-lose-cluster-make.txt), [log](evidence/runs/drill-clean-restore-20261105T130633Z.log), [BKP-6b](validation.md#7-backup-and-restoration)). `make test` then passed whole on the cluster it left, at `f30a7f5`, with `make ci`, the stubbed restore suite and a complete image scan beside it, and GitHub ran the push that followed. [validation.md](validation.md#read-this-first) has those results, among them the one planted defect that survived and the runs that lost a job to a 504.

To list what is still marked:

```bash
git grep -n -E '\[\[(VERIFY|MEASURE):' -- '*.md'
```

What the last markers asked, and where the answers are:

| Question | Answer |
|---|---|
| Disk growth of a first install, and host free disk around it | Host free went from 31 to 13 GiB on the cold install, in whole GiB by `df`, and [resource-utilization.md](resource-utilization.md#host-and-docker-storage) says what its defect added. The same with no defect: Not measured in Pass 1 |
| Time of a `make up` from a fresh clone | 955 s with the registry and caches kept. A full cold install with no defect has not been timed end to end, and [install.md](install.md#first-run) says what the one cold run did time, and why its 5,238 s is not a good figure |
| The CPU count of a first install | 12, the count the cold install ran at ([make-setup.txt](evidence/runs/clean-install-20261105T105546Z/make-setup.txt)). The floor of 4: Not measured in Pass 1 |
| `Docker.raw` before and after a delete | 38,276,744 KiB before that run's delete and 38,301,404 KiB after its restore, with a cluster back on the disk, at the top and bottom of [its output](evidence/runs/BKP-6-20261105T130633Z-lose-cluster-make.txt). Directly after a delete: Not measured in Pass 1 ([TEAR-5b](validation.md#10-clean-teardown-and-recreation)). After the cold install it read 40,060,992 KiB ([disk](evidence/runs/clean-install-20261105T105546Z/disk-after-install.txt)) |
| OPS-2b, OPS-4 and OPS-5 in [validation.md](validation.md) | No run is planned, so they stay open |

Plain sentences stand where Pass 1 has no answer. "Not tested in Pass 1" marks something this pass never ran and no later run in it will read, such as Safari. "Not measured in Pass 1" marks a number no run read, such as the disk a cold install with no defect needs. What a later run may still answer reads NOT RUN. "Unverified" or "Not measured" marks a question about Hetzner, Cloudflare or the Pass 2 that was planned for them, which hosted production on Contabo did not settle, because it did not use them. List them with `git grep -n -E 'Not tested in Pass 1|Unverified|Not measured' -- '*.md'`.

A number with no measurement behind it says "estimate" and how it was derived. Present-tense descriptions such as "the policy allows X" describe configuration. They do not say the behaviour has been observed.

## Start here

| If you want to | Read |
|---|---|
| See what this is and whether it works today | [README](../README.md), then [validation.md](validation.md) |
| Know how the three environments differ | [environments.md](environments.md) |
| Run the local platform | [install.md](install.md), then [runbooks/](runbooks/) |
| Run hosted production | [install.md](install.md#hosted-production) and [scripts/hosted/README.md](../scripts/hosted/README.md), then [runbooks/](runbooks/) |
| Understand the design | [architecture.md](architecture.md), then [technology-choices.md](technology-choices.md) and [adr/](adr/) |
| Read the build story, including what went wrong and what remains unproven | [case-study.md](case-study.md) |
| Know what it does not do | [known-limitations.md](known-limitations.md) |
| Know what only the owner can settle | [Owner decisions still open](../PASS2_HANDOFF.md#owner-decisions-still-open): D10, the public repository `/source` needs; D12, the replaced `email.py`; D16, the licence for platform code; D17, two GitHub Apps with access to the repository; and D18, whether to rename Wayline |
| Check license obligations | [agpl-compliance.md](agpl-compliance.md) |

## All documents

### Overview and design

| Document | Answers |
|---|---|
| [platform-contract.md](platform-contract.md) | What are the fixed names, owners, waves, and budgets? Binding |
| [architecture.md](architecture.md) | How do the layers fit, and why this way? |
| [technology-choices.md](technology-choices.md) | Why each component, and what was rejected? |
| [adr/](adr/) | Why was each significant decision made? |
| [environments.md](environments.md) | How do dev, prod-sim and hosted production differ, row by row, and why is namespace separation not the same as independent clusters? |
| [case-study.md](case-study.md) | What problem was solved, what was hard, what is proven? |

### Deploying and operating

| Document | Answers |
|---|---|
| [install.md](install.md) | How do I go from a clean machine to a running local platform, and from a bare VPS to hosted production? |
| [scripts/hosted/README.md](../scripts/hosted/README.md) | How is hosted production reached and run, and how do I get back in when locked out? |
| [terraform.md](terraform.md) | What does Terraform manage, and what does it not provision? |
| [kubernetes-helm.md](kubernetes-helm.md) | How is the upstream chart vendored, patched, and rendered? |
| [argocd.md](argocd.md) | How do projects, waves, sync, and promotion work? |
| [infisical.md](infisical.md) | How do secrets get from Infisical to pods, and what are the free-tier limits? |
| [data-operations.md](data-operations.md) | How do backup, restore, and rotation work? |
| [disaster-recovery.md](disaster-recovery.md) | What can be recovered, and from what? |
| [monitoring.md](monitoring.md) | What is scraped, what alerts, and how is delivery tested? |
| [monitoring-new-app.md](monitoring-new-app.md) | On hosted production, what does a new app get for free, and what does it add? |
| [runbooks/](runbooks/) | What do I do when a specific thing breaks? Hosted production adds its own [rollback](runbooks/hosted-rollback.md), [restore](runbooks/hosted-restore.md) and [lockout](runbooks/hosted-lockout.md) runbooks |

### Security and limits

| Document | Answers |
|---|---|
| [security.md](security.md) | What are the controls, what is enforced, and what is only a process? |
| [known-limitations.md](known-limitations.md) | What does this platform not do? |
| [agpl-compliance.md](agpl-compliance.md) | What do AGPL-3.0 and the upstream licenses require? |

### Results

| Document | Answers |
|---|---|
| [validation.md](validation.md) | What was tested, with which result? Authoritative status |
| [evidence/](evidence/README.md) | What are the raw captures behind those results? Its [branding](evidence/branding/README.md), [first browser session](evidence/branding/live-dev/README.md), [browser check after the restore](evidence/branding/live-final/README.md), [CI](evidence/ci/README.md), [image scan](evidence/security/README.md) and [promotion evidence](evidence/promotions/README.md) folders each have their own index |
| [resource-utilization.md](resource-utilization.md) | What does it really use, against the estimates, under what conditions, and what binds first under load? |

### Superseded plans

| Document | Answers |
|---|---|
| [PASS2_HANDOFF.md](../PASS2_HANDOFF.md) | What Pass 1 handed over, and the move to Hetzner Cloud and Cloudflare it planned. That move was not made: hosted production went to Contabo and Vercel. Its list of owner decisions still applies |
| [future-hetzner.md](future-hetzner.md) | What Terraform would have provided on Hetzner Cloud with independent dev and prod and Cloudflare. None of it was built, provisioned or tested |

### Component notes, next to the code

| Document | Covers |
|---|---|
| [infrastructure/terraform/README.md](../infrastructure/terraform/README.md) | Terraform layout and reasoning |
| [infrastructure/terraform/environments/prod/README.md](../infrastructure/terraform/environments/prod/README.md) | Hosted production's cluster root: namespaces, quotas, the CoreDNS rewrite, Argo CD |
| [infrastructure/terraform/environments/prod-host/README.md](../infrastructure/terraform/environments/prod-host/README.md) | Hosted production's VPS, read only, and its DNS records |
| [evidence/promotions/README.md](evidence/promotions/README.md) | The signed record of each set of digests dev ran, which hosted production's release checks |
| [adr/0017-infisical-public-route.md](adr/0017-infisical-public-route.md) | Why hosted production's Infisical has a public route for its one admin |
| [gitops/bootstrap/README.md](../gitops/bootstrap/README.md) | What Terraform applies so Argo CD has something to reconcile |
| [helm/plane/vendor/plane-ce-1.8.6/VENDOR.md](../helm/plane/vendor/plane-ce-1.8.6/VENDOR.md) | Provenance of the vendored upstream chart |
| [infisical/README.md](../infisical/README.md) | Infisical layer |
| [monitoring/README.md](../monitoring/README.md) | Monitoring layout and Grafana access |
| [tests/load/README.md](../tests/load/README.md) | The k6 load test and what it captures. Results are in [resource-utilization.md](resource-utilization.md) |
| [.github/workflows/README.md](../.github/workflows/README.md) | Workflows, and what GitHub Free does not enforce |
| [apps/wayline/README.md](../apps/wayline/README.md) | How the branded images are built from the pinned upstream source |
| [apps/wayline/MODIFICATIONS.md](../apps/wayline/MODIFICATIONS.md) | The dated record of what changed from upstream |
| [NOTICE.md](../NOTICE.md) | Upstream's notices, and the modified version's name and source |
