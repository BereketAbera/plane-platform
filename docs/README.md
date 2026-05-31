# Documentation index

This is the documentation for a customized Plane Community Edition v1.4.3 deployment, run locally on kind. The application is Plane CE, not an original product. Pass 1 runs on one laptop and provisions nothing in the cloud.

The [repository README](../README.md) has the overview, status table, and quick start.

## How to read these documents

**Sources of truth, in order:**

1. [platform-contract.md](platform-contract.md) is binding for names, ownership, and ordering. If code and the contract disagree, one of them is a bug.
2. The code decides what actually happens.
3. [evidence/](evidence/README.md) decides what actually happened. A claim about runtime behaviour needs a capture there, with its date and command.

**Result labels**, from [contract section 12](platform-contract.md#12-evidence-rule):

| Label | Meaning |
|---|---|
| PASS | Ran, met the expected result, evidence captured |
| FAIL | Ran, did not meet the expected result, evidence captured |
| BLOCKED | Could not run, and the blocker is named |
| NOT RUN | Has not been attempted |

**Inline markers.** These documents were written alongside the code and are reconciled against evidence as runs finish. On 2026-11-05 the open ones are mostly what has not run yet: a clean install, teardown and recreation, a full restore, secret rotation, the failed-deploy drill, the load test, `make test-alert`, and everything about Hetzner and Cloudflare.

| Marker | Meaning |
|---|---|
| VERIFY, in double square brackets | A claim that depends on a runtime result not yet confirmed. Do not treat it as true |
| MEASURE, in double square brackets | A number that has not been measured yet |

To list what is still open:

```bash
git grep -n -E '\[\[(VERIFY|MEASURE):' -- '*.md'
```

A number with no measurement behind it says "estimate" and how it was derived. Present-tense descriptions such as "the policy allows X" describe configuration. They do not say the behaviour has been observed.

## Start here

| If you want to | Read |
|---|---|
| See what this is and whether it works today | [README](../README.md), then [validation.md](validation.md) |
| Run it | [install.md](install.md), then [runbooks/](runbooks/) |
| Understand the design | [architecture.md](architecture.md), then [technology-choices.md](technology-choices.md) and [adr/](adr/) |
| Read the build story, including what went wrong and what remains unproven | [case-study.md](case-study.md) |
| Know what it does not do | [known-limitations.md](known-limitations.md) |
| Plan the move to Hetzner | [PASS2_HANDOFF.md](../PASS2_HANDOFF.md), then [future-hetzner.md](future-hetzner.md) |
| Check license obligations | [agpl-compliance.md](agpl-compliance.md) |

## All documents

### Overview and design

| Document | Answers |
|---|---|
| [platform-contract.md](platform-contract.md) | What are the fixed names, owners, waves, and budgets? Binding |
| [architecture.md](architecture.md) | How do the layers fit, and why this way? |
| [technology-choices.md](technology-choices.md) | Why each component, and what was rejected? |
| [adr/](adr/) | Why was each significant decision made? |
| [environments.md](environments.md) | How do dev and prod-sim differ, and why is namespace separation not the same as independent clusters? |
| [case-study.md](case-study.md) | What problem was solved, what was hard, what is proven? |

### Deploying and operating

| Document | Answers |
|---|---|
| [install.md](install.md) | How do I go from a clean machine to a running platform? |
| [terraform.md](terraform.md) | What does Terraform manage, and what does it not provision? |
| [kubernetes-helm.md](kubernetes-helm.md) | How is the upstream chart vendored, patched, and rendered? |
| [argocd.md](argocd.md) | How do projects, waves, sync, and promotion work? |
| [infisical.md](infisical.md) | How do secrets get from Infisical to pods, and what are the free-tier limits? |
| [data-operations.md](data-operations.md) | How do backup, restore, and rotation work? |
| [disaster-recovery.md](disaster-recovery.md) | What can be recovered, and from what? |
| [monitoring.md](monitoring.md) | What is scraped, what alerts, and how is delivery tested? |
| [runbooks/](runbooks/) | What do I do when a specific thing breaks? |

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
| [evidence/](evidence/README.md) | What are the raw captures behind those results? Its [branding](evidence/branding/README.md), [first browser session](evidence/branding/live-dev/README.md), [CI](evidence/ci/README.md) and [image scan](evidence/security/README.md) folders each have their own index |
| [resource-utilization.md](resource-utilization.md) | What does it really use, against the estimates, and under what conditions? |

### Next pass

| Document | Answers |
|---|---|
| [PASS2_HANDOFF.md](../PASS2_HANDOFF.md) | What does Pass 2 inherit, and what must it do first? Nothing cloud in it exists yet |
| [future-hetzner.md](future-hetzner.md) | What must Terraform provide on Hetzner Cloud with independent dev and prod and Cloudflare? Nothing there is built, provisioned or tested |

### Component notes, next to the code

| Document | Covers |
|---|---|
| [infrastructure/terraform/README.md](../infrastructure/terraform/README.md) | Terraform layout and reasoning |
| [gitops/bootstrap/README.md](../gitops/bootstrap/README.md) | What Terraform applies so Argo CD has something to reconcile |
| [helm/plane/vendor/plane-ce-1.8.6/VENDOR.md](../helm/plane/vendor/plane-ce-1.8.6/VENDOR.md) | Provenance of the vendored upstream chart |
| [infisical/README.md](../infisical/README.md) | Infisical layer |
| [monitoring/README.md](../monitoring/README.md) | Monitoring layout and Grafana access |
| [tests/load/README.md](../tests/load/README.md) | The k6 load test |
| [.github/workflows/README.md](../.github/workflows/README.md) | Workflows, and what GitHub Free does not enforce |
| [apps/wayline/README.md](../apps/wayline/README.md) | How the branded images are built from the pinned upstream source |
| [apps/wayline/MODIFICATIONS.md](../apps/wayline/MODIFICATIONS.md) | The dated record of what changed from upstream |
| [NOTICE.md](../NOTICE.md) | Upstream's notices, and the modified version's name and source |
