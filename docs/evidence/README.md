# Evidence

This directory holds the raw output behind every result in [validation.md](../validation.md) and every
measured number in [resource-utilization.md](../resource-utilization.md). Contract section 12 makes it binding:
a claim in the docs needs evidence here, captured from a real run with its date and command.

## Rules

1. **Evidence is raw output.** It is what the command printed or wrote. It is never summarized, reformatted,
   reordered or trimmed by hand. A summary belongs in the doc that links to the file.
2. **Secrets are scrubbed, and that is the only edit publishing makes.** A secret value becomes `<redacted>`, and
   everything else stays byte for byte. [The scrub](#the-scrub) says which values, and the index says how many were
   replaced. If a file needs more than that, do not commit it.
3. **Failed runs stay.** A FAIL or BLOCKED run is evidence too. Commit it, and link it from the row. A later PASS
   adds a file. It does not replace the earlier one.
4. **No file, no result.** A run with no file here stays NOT RUN in the matrix, however it went.
5. **Date and command go in the index when the file lacks them.** Do not add them to the raw file.

Status values are exactly PASS, FAIL, BLOCKED and NOT RUN. [validation.md](../validation.md) defines them.

## Layout

```text
docs/evidence/
  README.md           this file, including the index
  day1-gates*.txt     day-1 gate runs, copied here by hand when they ran
  cluster-up-*.log    the first cluster creation log
  runs/               published copies of .local/evidence-raw/, under the names the runs gave them
    MANIFEST.tsv      per file: when the raw file was last written, bytes published, replacements
  branding/           Wayline image builds, checks and screens. live-dev/ is the first real browser session
  ci/                 GitHub Actions runs and make ci
  security/           image scans
```

Files are not named after test rows, except the `ci-<row>-` files in `ci/`. A row in [validation.md](../validation.md)
links to the file it rests on. Names in `runs/` come from the run: `<entry point>-<env>-<UTC start>.<ext>` when a script
chose the name, and `<topic>-<n>.<ext>` when whoever ran the test did. A run that writes a directory, such as the load
test, keeps its own file names under `runs/<directory>/`.

`branding/`, `ci/` and `security/` are copied by hand, and each has a README that says what its files are.
`security/` keeps its one complete scan in full. When a later complete scan arrives, the earlier failing one keeps its
summary files and gives up its `images/*.json`, and the latest stays whole. That has not happened yet: the other two runs
there are an early stop at 2 of 35 images and a final run of the 5 targets built here, which did not scan the upstream
images again.

Not everything in `runs/` is one command's plain output. Many files are transcripts put together by whoever ran the test,
with `#` comment lines and written headers. A few left things out when they were captured, and say so in their own text:
`infisical-idempotency-1.txt` (digests removed), `kps-render-diff-1.txt` (values masked), `wayline-backend-check.txt` (steps
cut down) and `plane-prod-sim-separation-state-*.txt` (Valkey run ids cut to 8 hex). Those edits came before publishing.
Read a file before citing it.

## Publishing

Scripts write raw output to `.local/evidence-raw/`, which is gitignored. Nothing reaches this directory on its own, because
`.local/` also holds real secrets.

```bash
# 1. Copy, scrub and scan. Read what it prints.
make publish-evidence

# 2. Read what changed, and open any new image. Commit it only then.
git status --short docs/evidence/runs

# 3. Add a line to the index below if a new prefix appeared, then link the file from the doc that needs it.
```

`scripts/publish-evidence.sh` copies each regular file to `runs/` under the same name, overwriting the earlier copy.

- **It copies** text up to 2 MiB, and screenshots (`.jpg`, `.jpeg`, `.png`). An image cannot be scrubbed, so read it first.
- **It skips**, with a printed line: anything else that is not text, files over 2 MiB, hidden files, links, the file types
  `.gitignore` keeps out as secrets or dumps, and `scan-images-*` directories, which go to `security/` by hand. Its
  [README](security/README.md) lists the replacements a scan needs.
- **It never deletes** a file in `runs/`. A raw file that is gone keeps its copy.
- **It is safe to run again.** Each copy is made from its raw file, so the same input gives the same bytes and leaves
  modification times alone.
- **It fails** on any gitleaks finding over `runs/`, gating on the exit code of gitleaks itself. It prints the file, line and
  rule, not what matched. The copy stays on disk, uncommitted, so fix it before going on: add the value to the scrub, or,
  for a real false positive, add a narrow path rule with a comment to `.gitleaks.toml`.

The run on 2026-11-05 found no real false positive, so `.gitleaks.toml` did not change. Gitleaks flagged 21 lines in
`infisical-idempotency-1.txt`, `infisical-seed-partial-1.txt` and `infisical-prod-sim-crs-1.txt`, and the identifier rule below
covers them.

Scan a copy, never a relative path under `.local/`. `.gitleaks.toml` allowlists `^\.local/`, so `gitleaks dir .local/evidence-raw`
exits 0 with findings in it. The same directory by absolute path gave 32 on 2026-11-05.

The script has a negative control, on a scratch copy with real values planted from each source and a gitleaks-shaped
token: [publish-evidence-control-1.txt](runs/publish-evidence-control-1.txt), 61 checks and 0 failed, and the
[script that ran it](runs/publish-evidence-control-script-1.txt). [publish-evidence-check-1.txt](runs/publish-evidence-check-1.txt)
holds the checks by hand on what it published, including that the exact values in `.local/test-accounts.env` are absent from
`docs/evidence/`. Those values were never in the raw files, so that check shows they did not get in. The negative control is
what shows they would be replaced.

### What each entry point writes

| Entry point | Raw output in `.local/evidence-raw/` | Notes |
|---|---|---|
| `scripts/test.sh` (`make test`, `make test-e2e`) | `test-<stamp>.txt` | One line per test with its label and evidence path. The full form also writes `gates-<stamp>.txt`, `infisical-isolation-<stamp>.txt` and `infisical-rendered-secrets-<stamp>.txt`, and each e2e run writes `smoke-<env>-<stamp>.json` |
| `tests/gates/day1.sh` (`make gates`) | stdout only | The first lines give the UTC date, command, commit and context. Capture it with a redirect, not a pipe, so the exit status stays its own |
| `tests/e2e/smoke.py` | `smoke-<env>-<run>.json`, or `--evidence <path>` | Credentials go to `.local/test-accounts.env`, not here |
| `scripts/test-netpol.sh` (`make test-netpol`) | `netpol-<stamp>.tsv` | One line per matrix row, written only once its sentinel has passed |
| `scripts/test-alert.sh` (`make test-alert`) | `alert-test-<env>-<stamp>.json` | Timings for each stage |
| `tests/load/run.sh` (`make test-load`) | `load-<run>/` | `results.json`, `job.yaml`, `k6.log`, `k6-summary.json`, `prometheus.json`, `samples.jsonl` and snapshots. Read `job.yaml` and `k6.log` before committing them |
| `tests/drills/*.sh` (`make drill-*`) | `drill-<name>-<stamp>.log` | `failed-deploy`, `clean-restore` or `pod-restart-<env>`. The pod restart drill also writes `drill-pod-restart-<env>-baseline.json` and one JSON per StatefulSet |
| `scripts/rotate.sh` (`make rotate`) | `rotate-<env>-<stamp>.log`, `rotate-<env>-<stamp>.probe` | The script writes results and counts, never values |
| `scripts/restore.sh` (`make restore`, `make restore-clean`) | `restore-<env>-<stamp>.json`, `restore-smoke-<env>-<stamp>.json` | A clean restore writes `restore-clean-<stamp>.json` and `restore-clean-smoke-<env>-<stamp>.json` |
| `scripts/ci/scan-images.sh` (`make scan-images`) | `scan-images-<stamp>/` | Not copied by `make publish-evidence`. It goes to `security/` by hand |
| `scripts/lib/dev-check.sh`, through `make promote`, `make rollback` and `make gitops-publish` | `promotion-overrides.log` | A line for each `OVERRIDE_DEV_CHECK` or `SKIP_DEV_CHECK`, with the digests and the reason. A local promotion with an override writes two lines, one from `promote.sh` and one from its publish |
| `apps/wayline/assets/generate.mjs` | `wayline-assets-sheet.png` | Contact sheet of the generated images |
| `scripts/backup.sh` (`make backup`) | Nothing. It writes `.local/backups/<env>/<id>/manifest.json` and `SHA256SUMS` | To publish a backup's record, copy only these two files to `.local/evidence-raw/` under a name that says which backup. The manifest holds a truncated key hash, never the key. Never copy the dumps |

### Never copy these

| Path | Why |
|---|---|
| `.local/secret-zero/` | Infisical's encryption key, auth secret and database password. `rotate.sh` also keeps its journal here, holding old and new passwords until a rotation ends |
| `.local/test-accounts.env` | Generated test credentials |
| `.local/evidence-scrub-values` | Every value the scrub has seen, including old ones, base64-encoded, mode 0600 |
| `.local/kubeconfig` | Cluster admin access |
| `.local/backups/` dumps | `scripts/backup.sh` notes that dumps hold password hashes and plaintext API tokens |
| `.local/terraform/` | Terraform state |

## The scrub

**Values.** Exact values from three places, collected without printing them: `.local/test-accounts.env`, every file under
`.local/secret-zero/` (the whole file, or each string in a JSON file), and, when the cluster answers, every Secret in
`plane-dev`, `plane-prod-sim`, `infisical`, `monitoring` and `argocd`, decoded. A password inside a URL counts on its own. So
does each value's base64 form, which is how `kubectl get secret -o yaml` prints it. With no cluster, the script says the
scan was limited to local files.

**Not treated as secrets.** Anything under 8 characters. Ordinary words such as `infisical` or `plane-prod-sim`: lower-case
or capitalized, joined by `-`, `_`, `.` or a space. Numbers up to 15 digits, ISO timestamps, and URLs with no credentials or
query in them. Anything over 64 KiB or holding a NUL byte, such as a Helm release blob. Random mixed-case letters are not
ordinary words, because `argocd-redis` has a password like that, but a real password made only of lower-case words would
not be scrubbed. On 2026-11-05 what this left alone was database names and users, a namespace, slugs, a display name, plain
URLs and a timestamp, listed by name in the check file.

**Replacing.** Each value becomes `<redacted>`, longest first, as bytes. The script prints only how many files changed and
how many replacements it made, never a value. `runs/MANIFEST.tsv` has the count per file.

**Identifiers.** Infisical's record ids and Kubernetes uids are not credentials, but gitleaks reads them as credentials in lines
such as `SECRET_KEY id=<uuid>` and `plane-app-keys uid=<uuid>`. So a UUID in the shape of gitleaks' `generic-api-key` rule, a
keyword, up to 20 characters and then `=`, is redacted too, keeping the rest of the line. Allowlisting that shape would also let a
real key through in the same position. Any other UUID stays.

**Remembered values.** Every value goes into `.local/evidence-scrub-values`. Without that, a stopped cluster, a rotated
password or a new install would put a value back into its copy the next time the raw file was published. The negative
control shows both sides of that.

**What the 2026-11-05 run changed.** 116 replacements in 19 files. 95 were exact values: the Infisical project, identity and
organization ids, and the Infisical admin email in a test stub in `dr-harness-source-1.txt`. 21 came from the identifier rule. No
password, key or token from those sources was in any raw file. One effect on reading: in `infisical-seed-partial-1.txt` the two
diff lines for `LIVE_SERVER_SECRET_KEY` now read the same, though the original ids differ, which is what that diff shows. The
9 images were read by eye: Grafana dashboards, the upstream Plane sign-in page, a public board and the asset contact sheet,
with no secret visible.

**What this does not prove.** A clean run says that no known value and nothing gitleaks recognizes is in the copies. A session
cookie or a one-off token that is in no source and fits no gitleaks rule would pass. In the negative control, with the cluster
values unknown to the scrub, gitleaks flagged 1 of 7. A search of the copies on 2026-11-05 for cookies, authorization headers,
URLs with credentials, private keys and token-like assignments found none with a value. That search is in the check file. It was a
one-time check, and it is not part of the script.

## Index

### Top-level files

One row per file. Date and command come from the file itself when it records them. Otherwise the row says where they
came from.

| File | Test rows | Result | Date | Command | Commit | Edits |
|---|---|---|---|---|---|---|
| [day1-gates.txt](day1-gates.txt) | G1-1 to G5-2 | 9 PASS, 0 FAIL, as printed by the file | 2026-11-04 21:49:52 +0300, from the modification time of the source file. The output carries no date | `tests/gates/day1.sh`, inferred from the output format. The output does not record the command, or whether `make gates` called it | Script added in `0f7ba03`, committed one second after that time | None. Byte-identical to `runs/day1-gates-2.txt`. Scanned with gitleaks, and read in full: no secrets. The hashes in it are an image digest and the commit of a throwaway Git repository |
| [day1-gates-20261104T184733Z.txt](day1-gates-20261104T184733Z.txt) | G5-1, earlier run | 8 PASS, 1 FAIL, as printed by the file | 2026-11-04 21:47:33 +0300, from the modification time of the source file, which is also the time in the name. The output carries no date | `tests/gates/day1.sh`, inferred from the output format, before the fix to its name lookup | Before `0f7ba03`, which holds the fixed script | None. Byte-identical to `runs/day1-gates-1.txt`. Scanned with gitleaks, and read in full: no secrets |
| [day1-gates-20261104T205542Z.txt](day1-gates-20261104T205542Z.txt) | Gates 1, 2 and 5, later run with the platform's NetworkPolicies loaded | 14 passed, 0 failed, as printed by the file | 2026-11-04T20:55:42Z, from the file | `tests/gates/day1.sh`, from the file | `d3bcbe2103fd`, from the file | None known. No raw copy is left to compare it with. Scanned with gitleaks |
| [day1-gates-20261104T220155Z.txt](day1-gates-20261104T220155Z.txt) | Gates 1, 2 and 5, later run with the reference server and mirror log checks | 17 passed, 0 failed, as printed by the file | 2026-11-04T22:01:55Z, from the file | `tests/gates/day1.sh`, from the file | `234a2b942f32`, from the file | None. Byte-identical to `runs/day1-gates-20261104T220155Z.txt`. Scanned with gitleaks |
| [day1-gates-20261104T231136Z.txt](day1-gates-20261104T231136Z.txt) | Gates 1, 2 and 5, later run with the node's witness on every deny row | 17 passed, 0 failed, as printed by the file | 2026-11-04T23:11:37Z, from the file | `tests/gates/day1.sh`, from the file | `fbfd7c5c87c6`, from the file | None known. No raw copy is left to compare it with. Scanned with gitleaks |
| [cluster-up-20261104T184521Z.log](cluster-up-20261104T184521Z.log) | None. Backs the status line in the [README](../../README.md) | Exit status not recorded. The last line reports `cluster ready` | 2026-11-04 21:45:21 +0300, from the modification time of the source file, which is also the time in the name | `scripts/cluster-up.sh`, inferred from the output format | Not recorded | None, so it keeps terminal color codes and the build host's home path. Byte-identical to `runs/cluster-up-1.log`. Scanned with gitleaks, and read in full: no secrets |

The earlier gate run printed 8 passed and 1 failed. The failing line was "pods resolve the Docker-network name". A comment
in `tests/gates/day1.sh` attributes that failure to the test itself: busybox `nslookup` exits non-zero on the first NXDOMAIN
from a search domain, and the fix was a trailing dot on the name.

### Directories with their own README

| Directory | What it holds |
|---|---|
| [branding/](branding/README.md) | The Wayline image builds, digests, checks and rendered screens |
| [branding/live-dev/](branding/live-dev/README.md) | The first real browser session on the branded images in plane-dev |
| [ci/](ci/README.md) | GitHub Actions runs, `make ci`, negative controls and promotion flow tests, by row |
| [security/](security/README.md) | `scripts/ci/scan-images.sh` runs: one complete, one stopped early, and the final run of what is built here |

### `runs/`, by topic

One line per filename prefix. [MANIFEST.tsv](runs/MANIFEST.tsv) lists every file, with when its raw file was last written and how
many replacements it took. A later publish can add a prefix before this table has a line for it.

Many files give their date and command in their first lines. Otherwise the date is the last write in `MANIFEST.tsv`, which is when
a capture ended or the file was copied, not always when the run started. A time in a file name is the start. If neither the
file nor the line below names the command, it is not recorded, so say that when citing the file.

| Prefix | What it holds |
|---|---|
| `argo-controller-limit-` | A `terraform apply` that raised the Argo CD application controller's memory limit, with the workloads after it. Some of its read commands failed under zsh, and the file shows that |
| `argocd-` | Argo CD behaviour: Lua health checks, statically and on the real server (`-lua-`), chart render and repo-server memory (`-render-`), wave gating, Terminating operations, a restart under default-deny |
| `bootstrap-` | First bring-up of the foundation: `scripts/up.sh` stage by stage with `UP_STOP_AFTER` (`-up-`), the Application timeline, memory and `kubectl top` samples |
| `branded-dev-smoke-` | `make test-e2e ENV=dev` terminal output on the branded images, the run behind `smoke-dev-20261105T001213Z.json` |
| `cluster-up-` | The first kind cluster creation. The same bytes as `../cluster-up-20261104T184521Z.log` |
| `cpu-throttling-` | Where `CPUThrottlingHigh` went pending or firing, from `ALERTS` over 3.6 hours |
| `day1-gates-` | `tests/gates/day1.sh` runs, of which `-1` and `-2` are the same bytes as `../day1-gates-20261104T184733Z.txt` and `../day1-gates.txt`. Also proofs of the script on scratch copies: injected faults and signals (backlog item H46), and a reviewer's logs, which describe the script before `f878bca` (`-adversarial-`) |
| `dr-` | Disaster recovery work: backups and retention, in-place Infisical restores (`-inplace-restore-`), rehearsals in throwaway places (`-fresh-instance-rehearsal-`, `-plane-restore-rehearsal-`), the plan and its refusals, and the harness's stubbed scenarios and source. None of these is a full clean restore |
| `drill-` | `tests/drills/*.sh` logs: pod restart in dev and prod-sim, with a JSON per StatefulSet, and one clean-restore run with `PLAN_ONLY=yes`, which stops before the delete |
| `foundation-logs-` | Log level counts and errors for Traefik and metrics-server after the bring-up |
| `h16-` | Backlog item H16, `ArgoSyncFailed` during a retry loop: a throwaway Application on the real controller, when the alert fired, metrics, operation durations, promtool, validation |
| `h17-` | H17, the allow list on internal routes: what the other doors do with free egress, whether a missing Middleware fails closed, Infisical isolation from the host, the ownership check, validation |
| `h18-` | H18, the alert on kindnet logging that it skips network policies: a synthetic line, Loki, validation |
| `h43-` | H43, Argo CD reading a Prometheus with no ready pod as Progressing: reproductions before and after, the Lua check, `terraform plan` and `apply` |
| `h49-` | H49, the operator's Thanos default: digest, mirror path, rendered flag, policy result |
| `harness-` | Test harness work on 2026-11-05: smoke in dev, the worker control in prod-sim, `tests/separation/` network and state, Celery's source read from the worker image. Some ran on an uncommitted `smoke.py`, as the file says |
| `imagetools-local-` | How `docker buildx imagetools inspect` and `kubectl --ignore-not-found` answer for something absent |
| `infisical-` | The secrets layer: first boot, bootstrap, idempotency, isolation and rendered Secrets (with a stamp in the name when `scripts/test.sh` wrote them), Kubernetes Auth TLS, RBAC, restarts, tamper, token renewal, rate limit, admin recovery |
| `kindnet-` | The kindnet alert on a synthetic pod, firing and held across an Alloy restart |
| `kps-render-diff-` | `helm template kube-prometheus-stack` twice and the diff: what the chart generates anew each time. Values masked at capture |
| `limits-breakdown-` | Which memory touched the limits: cgroup files and 4 hours of Prometheus data |
| `logs-sh-tails-` | `scripts/logs.sh` exit codes and line counts, with no log contents (H46) |
| `make-dry-run-` | `make -n` for the targets |
| `manifests-static-` | `kubeconform`, `validate-manifests.sh` and `ownership.sh` on the GitOps manifests, with no cluster |
| `missing-rule-evaluations-` | Why `PrometheusMissingRuleEvaluations` goes pending on a healthy Prometheus |
| `monitoring-` | Monitoring: dashboards, targets, rules, probes, LogQL and memory; Loki limit and replay tests; Alloy and Grafana under restart and load; the alert path with a temporary rule; six Grafana screenshots (`monitoring-ui-*.jpg`) |
| `negative-controls-` | `scripts/ci/negative-controls.sh` for the route allow list and the Thanos rule |
| `netpol-` | `scripts/test-netpol.sh`: a TSV per run by UTC start, terminal output by source namespace (`-foundation-`, `-infisical-`), and checks from real pods |
| `plane-dev-` | Plane in dev before the branded images were promoted at `4f622e3`: first boot, smoke, PSA dry run, rollouts and quota, startup, memory, worker, `/live`, cookie attributes, public board, PDF export, page duplicate, the pod restart drill, the NetworkPolicy matrix, two screenshots of the upstream UI |
| `plane-prod-sim-` | Plane in prod-sim on upstream images: first boot, smoke, concurrent load with dev, separation attempts between the environments (network and state, with the scripts saved as `*-script.py.txt`), pod restart drills, worker and broker restart, memory samples, snapshots, and the proposed `smoke.py` patch |
| `publish-evidence-` | The negative control for `scripts/publish-evidence.sh`, the script that ran it, and the check by hand of what it published |
| `quota-budget-` | Plane pods' requests against the quota in `modules/foundation`, from rendered manifests |
| `registry-memory-` | H39, how much memory `plane-registry` needs during a push, on scratch containers |
| `render-m4-m7-` | `make render`, `render.sh --check`, kubeconform, conftest and negative controls from the render fixes |
| `restore-` | JSON from `scripts/restore.sh` for the in-place Infisical restores: each step with its status |
| `routes-` | `tests/routes/internal-routes.sh` before and after the allow list (H17) |
| `shellcheck-ops-` | shellcheck and bash 3.2 syntax on the entry-point scripts |
| `smoke-` | JSON from `tests/e2e/smoke.py`, by environment and UTC start. `smoke-dev-20261104T225624Z.json` is a FAIL, 37 of 38 |
| `status-real-` | `make status` on the cluster, before Argo CD was installed |
| `terraform-` | Terraform and TFLint static checks, and mock-provider tests on a throwaway copy |
| `test-` | `scripts/test.sh` summaries: one line per test with its label and evidence path, by UTC start |
| `test_` | Scenario tests of the entry points with stubbed commands (`-stub-`), with no cluster. They show the scripts' logic and nothing about the platform |
| `traefik-` | Routes through Traefik, and the source address seen at the NodePort |
| `validate-manifests-ops-` | `scripts/ci/validate-manifests.sh` during the entry-point work |
| `wayline-` | Early branding builds and checks. `wayline-assets-sheet.png` is the contact sheet of generated images. The final build is in [branding/](branding/README.md) |
