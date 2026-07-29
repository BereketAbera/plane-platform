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
  branding/           Wayline image builds, checks and screens. live-dev/ is the first real browser session,
                      and live-final/ is a real browser on the final images after a full restore
  ci/                 GitHub Actions runs and make ci
  security/           image scans
```

A row in [validation.md](../validation.md) links to the file it rests on. Names in `runs/` come from the run:
`<entry point>-<env>-<UTC start>.<ext>` when a script chose the name, `<row>-<UTC start>[-<part>].<ext>` for the validation runs of
2026-11-05, such as `SEC-2-20261105T072331Z-watch.txt`, and `<topic>-<n>.<ext>` when whoever ran the test did. `ci/` names its files
`<row>-<UTC start>-`. A run that writes a directory, such as the load test, keeps its own file names under `runs/<directory>/`.
A name with a row in it does not make a file a result: some of those files record a command the permission system refused, and each says
so in its first lines. The row says which file is the result.

`branding/`, `ci/` and `security/` are copied by hand, and each has a README that says what its files are.
`security/` keeps its latest complete scan in full, `scan-images-20261105T140048Z`. When a later complete scan arrives, the earlier one keeps its
summary files and gives up its `images/*.json`, and the latest stays whole. That has happened once: `scan-images-20261104T215437Z`, the failing
complete scan, gave up its `images/*.json` in `76e98ee`. The other runs there are an early stop at 2 of 35 images and four runs of the 5 targets
built here.

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
| `scripts/test.sh` (`make test`, `make test-e2e`) | `test-<stamp>-<pid>.txt` | One line per test with its label and evidence path. The full form also writes `gates-<stamp>-<pid>.txt`, `infisical-isolation-<stamp>-<pid>.txt`, `infisical-rendered-secrets-<stamp>-<pid>.txt`, `routes-<stamp>-<pid>.txt`, `separation-network-<stamp>-<pid>.txt` and `separation-state-<stamp>-<pid>.txt`, and each e2e run writes `smoke-<env>-<stamp>-<pid>.json`. `<pid>` is the process id, since `b8e6c65`, and runs before that have the stamp alone |
| `tests/gates/day1.sh` (`make gates`) | stdout only | The first lines give the UTC date, command, commit and context. Capture it with a redirect, not a pipe, so the exit status stays its own |
| `tests/e2e/smoke.py` | `smoke-<env>-<run>.json`, or `--evidence <path>` | Credentials go to `.local/test-accounts.env`, not here |
| `scripts/test-netpol.sh` (`make test-netpol`) | `netpol-<stamp>.tsv` | One line per matrix row, written only once its sentinel has passed |
| `scripts/test-alert.sh` (`make test-alert`) | `alert-test-<env>-<stamp>.json` | Timings for each stage |
| `tests/load/run.sh` (`make test-load`) | `load-<run>/` | `results.json`, `job.yaml`, `k6.log`, `k6-summary.json`, `prometheus.json`, `samples.jsonl` and snapshots. Read `job.yaml`, `k6.log` and `k6-summary.json` before committing them, because `setup_data` held a session in the run of 2026-11-05 |
| `tests/drills/failed-deploy-rollback.sh`, `failed-migrator.sh`, `clean-restore.sh`, `pod-restart-persistence.sh` (`make drill-*`, and the migrator drill has no target) | `drill-<name>-<stamp>.log` | `failed-deploy`, `failed-migrator`, `clean-restore` or `pod-restart-<env>`. The last line reads `RESULT PASS` or `RESULT FAIL`, and with `CLEAN_INSTALL_FIRST=yes` that line also counts the clean install, so read which stage failed. The first two also write `<log name>-alerts.tsv`. The pod restart drill also writes `drill-pod-restart-<env>-baseline.json` and one JSON per StatefulSet. Those have no stamp, so each drill overwrites them, and the copies from 2026-11-04 are now only in Git's history |
| `tests/drills/alert-rules.sh`, with no make target | `alert-rules-<env>-<stamp>.txt` | One data service at a time at 0 replicas, what Prometheus and the sink read, and a last line of `RESULT failures=<n>`. A rule that does not fire is a FAIL about that rule |
| `tests/drills/clean-install.sh` | `clean-install-<stamp>/` | `summary.txt`, which gives each step's exit status and ends with `Steps that failed: N`, one `<step>.txt` per step, and `clone-evidence/`, what the clone's own runs wrote. It writes no drill log and no `RESULT` line, and exits 0 only when no step failed. A row takes its status from its own step. `COLD_INSTALL=yes` adds `make-up-stops-on-new-digests.txt`, `make-promote-dev.txt`, `make-promote-prod-sim.txt` and `builder-prune.txt`. Since the run of 07:50:41Z both forms also write `app-timeline.txt`, first sync times from Argo CD's history, and `disk-after-install.txt`. In `clean-install-20261105T075041Z/` and `clean-install-20261105T105546Z/`, the step named `destroy-refused` got `CONFIRM=yes` from its drill, from the environment in the first and through `MAKEFLAGS` in the second, and really ran `make destroy`, so its file is a delete and not a refusal, as its first lines show. `1374c1e` clears both, and no published drill has that fix in it. `destroy-refused-line-check.txt` checks the line alone, under an outer `make` with `CONFIRM=yes`, against a stub target. `TEAR-1-20261105T083304Z.txt` is the refusal |
| `tests/drills/clean-restore-harness.sh` (`make drill-clean-restore-harness`), `tests/drills/clean-restore-mutants.sh` | stdout only | With commands stubbed. They end in `RESULT <n> passed, <n> failed` and `RESULT <n> caught, <n> survived, <n> did not apply`. The copies in `runs/`, `dr-harness-*`, `dr-mutants-*`, `dr4-evidence/`, `dr5-evidence/` and `final-harness-*/`, are what whoever ran them captured |
| `scripts/rotate.sh` (`make rotate`) | `rotate-<env>-<stamp>.log`, `rotate-<env>-<stamp>.probe` | The script writes results and counts, never values. A killed run and what follows it each write a pair, as in SEC-4 and SEC-4b |
| `scripts/restore.sh` (`make restore`, `make restore-clean`) | `restore-<env>-<stamp>.json`, `restore-smoke-<env>-<stamp>.json` | A clean restore writes `restore-clean-<stamp>.json` and `restore-clean-smoke-<env>-<stamp>.json`, beside one `restore-<env>-<stamp>.json` for Infisical and each environment |
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

**Session fields.** Since `28fc216`, the value of any JSON `"session"` field becomes `<redacted>`, keeping the field's name, because k6's
`setup_data` held a session cookie in that shape, as the publishes below record. Since `846f9e0` the same pattern also reads `session_id` and
`session-id`, JSON inside a JSON string, and the cookie form `session=...`, for a value that starts with at least 16 letters, digits, `_` or `-`. Anything
else in that position stays. The negative control for this rule is [publish-evidence-session-control-1.txt](runs/publish-evidence-session-control-1.txt),
with [its script](runs/publish-evidence-session-control-script-1.txt), at 2026-11-05T10:03:07Z, 0 failed: the three spellings of the JSON form are replaced, and
with the substitution taken out of a copy of the script they stay and gitleaks still exits 0, so this rule is all that stands in their way. By its
sha256 it ran on the script before `846f9e0`, and it lists the cookie form and JSON inside a JSON string as outside the pattern, so the wider
pattern has no control of its own yet.

**Remembered values.** Every value goes into `.local/evidence-scrub-values`. Without that, a stopped cluster, a rotated
password or a new install would put a value back into its copy the next time the raw file was published. The negative
control shows both sides of that.

**What the 2026-11-05 run changed.** 116 replacements in 19 files. 95 were exact values: the Infisical project, identity and
organization ids, and the Infisical admin email in a test stub in `dr-harness-source-1.txt`. 21 came from the identifier rule. No
password, key or token from those sources was in any raw file. One effect on reading: in `infisical-seed-partial-1.txt` the two
diff lines for `LIVE_SERVER_SECRET_KEY` now read the same, though the original ids differ, which is what that diff shows. The
9 images were read by eye: Grafana dashboards, the upstream Plane sign-in page, a public board and the asset contact sheet,
with no secret visible.

**The publishes of 2026-11-05T07:40Z and later.** [publish-evidence-final-1.txt](runs/publish-evidence-final-1.txt) records the first: 693 files in
`runs/`, 382 new or changed, gitleaks with no findings, and 43 files changed by the scrub with 238 replacements, by its own count. Two new images were read by
eye, `AUTH-4-20261105T062750Z-dev.jpg` and `-prod-sim.jpg`: a signed-in home page with a display name, and a sign-in form, with no secret visible. The next
are [publish-evidence-final-2.txt](runs/publish-evidence-final-2.txt), 718 files and 33 new or changed, and [publish-evidence-final-3.txt](runs/publish-evidence-final-3.txt),
830 files, 109 new or changed, 56 files changed by the scrub with 316 replacements, each with gitleaks reading no findings. `06b8be7` then published the cold install and its restore, among them the alert drills: 49 files with no images, 882 in `MANIFEST.tsv`, and 5 files changed by the scrub with 44 replacements, by that file's counts. No file records what that publish printed, so gitleaks' reading of it is not on record here. `2fc7e72` then published the last drill and the crash output of the cold install. `76e98ee` published the checks at `f30a7f5`, with no file of what that publish printed. Then, in `a9f181a`, the planted defects at `f30a7f5` and the retry checks: 951 files in `MANIFEST.tsv`, 3 new or changed, with gitleaks reading no findings ([what it printed](ci/publish-evidence-20261105T145421Z.txt)). And in `00813df`, the re-runs of the surviving defect: 955 files, 4 new or changed, the same reading ([what it printed](ci/publish-evidence-20261105T150341Z.txt)). Each printed the scrub line `66 files changed, 416 replacements`, which counts over every copy, and their new files took none, by `MANIFEST.tsv`.

One secret got through. k6's `setup_data` held a plane-dev session value, in `load-20261105T073241Z/k6.log` and `k6-summary.json`, in no source of the scrub and
fitting no gitleaks rule, as the next paragraph warns. Gitleaks did not catch it. A read-through of the evidence did. `28fc216` added the rule above, scrubbed the two
copies and keeps k6's session out of its output. It reached local evidence only. A scrub changes the working tree and not history, so the unpushed history was rewritten
at 2026-11-05T13:53Z, before any of it reached GitHub. The session still worked at 13:55Z, on plane-dev's local host, and was signed out then, after which it answered 401.
[history-rewrite.md](history-rewrite.md) is the record, and it maps every old commit id to its new one. An id inside a raw file under `runs/` is the id at the time that file was written, so read it through that map.

**What this does not prove.** A clean run says that no known value and nothing gitleaks recognizes is in the copies. A session
cookie or a one-off token that is in no source and fits no gitleaks rule would pass. In the negative control, with the cluster
values unknown to the scrub, gitleaks flagged 1 of 7. A search at 2026-11-05T00:53Z, of the copies that publish had made, for cookies, authorization headers,
URLs with credentials, private keys, token-like assignments and tokens with the shape of a generated secret found no secret.
That search is in the check file. It was a one-time check, and it is not part of the script, so it says nothing of the later
publishes, one of which let a secret through, as the paragraph above records. So reading the evidence stays part of publishing it, as step 2 above asks.

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
| [branding/live-final/](branding/live-final/README.md) | A real browser on the final images after a full restore, in both environments: a work item typed before the delete, a published board, the first sign-in on prod-sim, and both sessions at once |
| [ci/](ci/README.md) | GitHub Actions runs, `make ci`, negative controls and promotion flow tests, by row, with reads of what GitHub served, one `make status` and what the last publishes printed |
| [security/](security/README.md) | `scripts/ci/scan-images.sh` runs: two complete, the later one whole, one stopped early, and four runs of what is built here, the last on the final images |

### `runs/`, by topic

One line per filename prefix. [MANIFEST.tsv](runs/MANIFEST.tsv) lists every file, with when its raw file was last written and how
many replacements it took. A later publish can add a prefix before this table has a line for it.

Many files give their date and command in their first lines. Otherwise the date is the last write in `MANIFEST.tsv`, which is when
a capture ended or the file was copied, not always when the run started. A time in a file name is the start. If neither the
file nor the line below names the command, it is not recorded, so say that when citing the file.

| Prefix | What it holds |
|---|---|
| `AUTH-4-`, `AUTH-6-` | Browser readings on 2026-11-05: a dev session on the prod-sim host, with two screenshots, and the rollback half of a returning browser |
| `BKP-2-`, `BKP-6-` | Transcripts: `BKP-2-20261105T074322Z.txt` is the backup, restore and e2e in dev that row BKP-2 rests on. `BKP-6-20261105T074858Z-make.txt` is `make drill-clean-restore` with the clean install, the first whole run, which ends `RESULT FAIL` on one step of its clean install, with every restore step PASS. `BKP-6-20261105T130633Z-lose-cluster-make.txt` is `make drill-clean-restore CONFIRM=yes LOSE_CLUSTER=yes` at `06b8be7`, finished: the lines of its log, ending `RESULT PASS` and `make exit=0`, with every restore step PASS. Its top holds a reading of `Docker.raw` and `df -k /` from before the delete, and its bottom another from when the run ended, after its restore |
| `BR-3-`, `CI-1-`, `CI-2-`, `CI-4-`, `CI-5-`, `CI-6b-` | Raw copies of what `ci/` holds under names with a description, such as `ci-5-20261105T055743Z-pr-1.txt`. The two sampled by `cmp` are the same bytes. Cite `ci/` |
| `DEP-1-`, `DEP-2-`, `DEP-3-` | The failed deploy drill, the rollback and the failing migrator on 2026-11-05: `make` output, a side watcher's raw lines (`-watch`), what was derived from them (`-timeline`), and the helpers' source (`-source`) |
| `FINAL-` | Prod-sim's running images and a refused `make test-e2e`, at 06:28Z. `FINAL-e2e-prod-sim-*` is a refusal record |
| `GITOPS-4-` | Self-heal. `-073240Z` is the result. `-072541Z` holds a script error and proves nothing, and `-062155Z` is a refusal record, with its watcher (`-062127Z-watch`) |
| `INST-1-`, `INST-1b-`, `INST-3-` | `INST-1-cold-rebuild-20261105T122036Z.txt` is `make images` and both promotions, by hand, in the cold install's clone at `8770097`, that clone's copy of `b4f6cc9`, under `umask 077`, while the first `make up` still waited. Its first line says why. It holds no crash output and no `Terminating` patch. `INST-1b-crash-logs-20261105T121917Z.txt` holds both: a record copied by hand from the coordinating session's `kubectl` output, because the pods and the clone are gone, with its lines cut at 210 characters by that command. `INST-3-` is `./scripts/prereqs.sh`, exit 1 on disk with the cluster up. The later exit 0, with no cluster, is `clean-install-20261105T075041Z/make-setup.txt` |
| `LOAD-1-`, `LOAD-1b-`, `LOAD-3-` | `make test-load ENV=dev` terminal output and read-only captures for the resource tables: Prometheus series and windows, `df` per volume, Docker storage. `LOAD-1b-20261105T090247Z-run.txt` is the quiet run behind LOAD-1 and LOAD-2, with its results in `load-20261105T090247Z/` and `load-20261105T091213Z/`, and `LOAD-3-20261105T092547Z-*` and `LOAD-3-idle-*` go with it. `LOAD-1-20261105T073240Z-run.txt` and `LOAD-3-20261105T07*` are the earlier run on a busy machine, with its results in `load-20261105T073241Z/`. `LOAD-3-20261105T074440Z-pvc-df.txt` holds a script error on its `df` lines, repeated correctly at `074543Z` |
| `MAKE-TEST-` | `make test` terminal output in full. `MAKE-TEST-20261105T140019Z.txt` is the run at `f30a7f5`, on the cluster the last drill left, exit 0, with `make ci`, the restore suite and the image scan running beside it. `MAKE-TEST-20261105T083455Z.txt` is the run on the first restored cluster, exit 0. The parts' own files carry the same stamp: `gates-`, `infisical-`, `routes-`, `separation-`, `smoke-` and `test-`, and their matrices are `netpol-20261105T140145Z.tsv` and `netpol-20261105T083542Z.tsv` |
| `MON-1-`, `MON-2-`, `MON-side-watcher-` | `make test-alert`. `MON-1-*` is the dev run with Alertmanager, sink, Prometheus and event captures, a raw watcher and a timeline. `MON-2-20261105T072541Z-run.txt` is the prod-sim run, and `MON-2-20261105T060633Z*` is an earlier refusal with its watchers. `MON-side-watcher-*` is the helpers' source |
| `OPS-7-`, `low-disk-overrides` | `guard_disk` with a raised floor, and the log a lowered floor writes |
| `PERS-1-`, `PERS-2-`, `PERS-3-` | The pod restart drills on the final images, and `make down` then `make up`. `PERS-2-20261105T061948Z.txt` and its `-061912Z-watch` are an earlier refusal. `PERS-3-20261105T083304Z.txt` names `make test-e2e` in its first line and holds none: that ran in `MAKE-TEST-20261105T083455Z.txt` |
| `RT-2b-` | `RT-2b-RT-3-20261105T073208Z.txt` is two real tabs, by hand, held and through a `live` restart. `RT-2b-20261105T062912Z.txt` is an earlier refusal |
| `SEC-2-`, `SEC-3-`, `SEC-4-`, `SEC-4b-`, `SEC-6-` | Rotation. `SEC-4b-20261105T084615Z.txt` is a killed rotation undone with `ROLLBACK=yes`. The `-072331Z` and later files are the runs, and the `-062` files are refusal records, watchers and a pre-check from before the owner's approval, apart from `SEC-2-backup-before-20261105T062141Z.txt`, a real `make backup ENV=dev`, exit 0, which BKP-1 cites. `SEC-3-BKP-3-*` also holds a backup, a refused restore, a real restore and the e2e after it |
| `TEAR-1-`, `TEAR-4-` | `TEAR-1-20261105T083304Z.txt` is `make destroy` refusing. `TEAR-4-20261105T105346Z-make.txt` is `make drill-clean-restore CONFIRM=yes CLEAN_INSTALL_FIRST=yes COLD_INSTALL=yes` at `e602dad`, finished: the same lines as its log, `drill-clean-restore-20261105T105347Z.log`, ending `RESULT FAIL` on one step of the cold install and `make exit=2`, with every restore step PASS |
| `alert-` | `make test-alert` JSON by environment and UTC start (`alert-test-`), a census of every rule not inactive, the figures quoted in alert text, and `tests/drills/alert-rules.sh` (`alert-rules-`): the FAIL at `100605Z`, the PASS after the fix at `101707Z`, and `alert-rules-validate-1.txt`, `scripts/ci/validate-manifests.sh` after that fix, with no date of its own |
| `argo-stuck-progressing-` | `ArgoAppStuckProgressing` firing on a throwaway Application and reaching the sink |
| `auth-6-`, `browser-cache-` | The promotion half of a returning browser, and the cached page it started from |
| `ci-actions-` | The repository setting that lets Actions open pull requests, before and after the owner's yes |
| `ci-2-` | `make ci` in a clean clone of `f30a7f5`, made from this checkout because that commit was not yet pushed, with `.tools` copied: `ci-2-20261105T140005Z-clean-clone-f30a7f5.txt`, exit 0 |
| `clean-install-` | One directory per run of `tests/drills/clean-install.sh`. `clean-install-20261105T075041Z/` kept the local registry and caches, and read 1 failed step, `destroy-refused`. Its `make up` of 955s, with no manual step, is the good figure for an install. `clean-install-20261105T105546Z/` is the cold form at `e602dad`, finished, and also read 1 failed step, `destroy-refused`. Its `make-up.txt` took 5238s, and that holds a wait on images that could not start, a rebuild and a manual patch, so it is not the time of a good install: read INST-1b and INST-1c in [validation.md](../validation.md) before citing it. A run that has `make-up-stops-on-new-digests.txt` is the cold form. A copy made while a run was going is partial, so read the last line of its `summary.txt`, which ends `Steps that failed: N` only when the run has ended |
| `clock-probe-`, `cluster-readings-`, `collect-other-`, `gitops-publish-`, `hardening-round-`, `image-pins-`, `limits-pod-cgroup-`, `lint-netpol-`, `make-ci-clean-clone-`, `node-kubelet-config-`, `policy-mutations-`, `rollback-generated-`, `rules-unit-`, `stuck-progressing-`, `validate-manifests-alerts-` | Checks and read-only readings from the hardening rounds on 2026-11-05. Each says in its first lines what it ran, and on what |
| `copy-to-local-registry-` | `scripts/ci/copy-to-local-registry.sh` with a stub docker, on a mixed-case owner, so nothing was copied and no registry was read |
| `final-` | `make test-e2e` terminal output on the images each promotion reached, by environment |
| `final-harness-` | The stubbed restore suite and its planted defects by commit. `final-harness-f30a7f5/` holds `group-0.txt` to `group-5.txt`, six `ONLY=` groups at once in one clean clone, `total.txt`, 1340 passed and 0 failed, and `mutants.txt`, 125 caught, 1 survived, 0 did not apply, exit 1. `final-harness-ddcb105/` and `final-harness-f05930d/` hold V1 and that one surviving defect again, after two changes to V1. They show the logic against stubs, and nothing about the platform |
| `gates-` | `tests/gates/day1.sh` inside the full `scripts/test.sh` run |
| `load-` | One directory per `make test-load` run. See [what each entry point writes](#what-each-entry-point-writes) |
| `podrestarting-` | `PodRestarting` live on the published rule, and the offsets behind it |
| `prod-sim-track-` | The refusal records from the prod-sim track at 06:29Z, not test output |
| `promote-`, `promotion-` | `make promote` output in each environment (`promote-`), and promotion checks, mostly on stubs, as each file says (`promotion-`). `promotion-dev-check-real-1.txt` read the real cluster |
| `review-` | What reviewers ran to check the fixes of a hardening round, on scratch clones unless the file says otherwise |
| `rotate-` | `scripts/rotate.sh` logs and probes, by environment and UTC start. A `.probe` file holds only ok or fail, with no status code |
| `separation-` | `tests/separation/` output by UTC start, from `scripts/test.sh` and `make test-separation` |
| `argo-controller-limit-` | A `terraform apply` that raised the Argo CD application controller's memory limit, with the workloads after it. Some of its read commands failed under zsh, and the file shows that |
| `argo-sync-unknown-` | The alert on an Application Argo CD cannot render, on a throwaway Application, held across a controller replacement |
| `argocd-` | Argo CD behaviour: Lua health checks, statically and on the real server (`-lua-`), chart render and repo-server memory (`-render-`), wave gating, Terminating operations, a restart under default-deny |
| `bootstrap-` | First bring-up of the foundation: `scripts/up.sh` stage by stage with `UP_STOP_AFTER` (`-up-`), the Application timeline, memory and `kubectl top` samples |
| `branded-dev-smoke-` | `make test-e2e ENV=dev` terminal output on the branded images, the run behind `smoke-dev-20261105T001213Z.json` |
| `cluster-up-` | The first kind cluster creation. The same bytes as `../cluster-up-20261104T184521Z.log` |
| `cpu-throttling-` | Where `CPUThrottlingHigh` went pending or firing, from `ALERTS` over 3.6 hours |
| `day1-gates-` | `tests/gates/day1.sh` runs, of which `-1` and `-2` are the same bytes as `../day1-gates-20261104T184733Z.txt` and `../day1-gates.txt`. Also proofs of the script on scratch copies: injected faults and signals (backlog item H46), and a reviewer's logs, which describe the script before `f878bca` (`-adversarial-`) |
| `dr-` | Disaster recovery work: backups and retention, in-place Infisical restores (`-inplace-restore-`), rehearsals in throwaway places (`-fresh-instance-rehearsal-`, `-plane-restore-rehearsal-`), the plan and its refusals, locks, the harness's stubbed scenarios and source, its mutants and stop sweep. None of these is a full clean restore |
| `destroy-refused-line-check` | The refusal line of `tests/drills/clean-install.sh`, old and new, under an outer `make` with `CONFIRM=yes`, against a stub target with the same test as `make destroy`. It checks the line, not a drill |
| `dr4-evidence/`, `dr5-evidence/` | Runs of the stubbed restore suite and its planted defects from the last rounds of restore fixes. `dr4-evidence/mutants-3-14d2a17.txt` is the record at the commit now `52c4744`, under its old id: 112 caught, 0 survived. They show the logic against stubs, and nothing about the platform |
| `drill-` | Logs of the drills that write one: pod restart in dev and prod-sim, with a JSON per StatefulSet, failed deploy and failing migrator with their alert files, and clean-restore. A clean-restore log may be `PLAN_ONLY=yes`, which stops before the delete, or a run under way when it was published, so read its last line. `drill-clean-restore-20261105T074859Z.log` is the first whole run, `RESULT FAIL` on one step of its clean install, and `-105347Z` is the cold run, the same, on the same step, with the recovery fixes merged. `-130633Z`, `LOSE_CLUSTER=yes`, has no clean install in it, and reads `RESULT PASS` |
| `foundation-logs-` | Log level counts and errors for Traefik and metrics-server after the bring-up |
| `h16-` | Backlog item H16, `ArgoSyncFailed` during a retry loop: a throwaway Application on the real controller, when the alert fired, metrics, operation durations, promtool, validation |
| `h17-` | H17, the allow list on internal routes: what the other doors do with free egress, whether a missing Middleware fails closed, Infisical isolation from the host, the ownership check, validation |
| `h18-` | H18, the alert on kindnet logging that it skips network policies: a synthetic line, Loki, validation |
| `h43-` | H43, Argo CD reading a Prometheus with no ready pod as Progressing: reproductions before and after, the Lua check, `terraform plan` and `apply` |
| `h49-` | H49, the operator's Thanos default: digest, mirror path, rendered flag, policy result |
| `harness-` | Test harness work on 2026-11-05: smoke in dev, the worker control in prod-sim, `tests/separation/` network and state, `make test-*` terminal output (`-make-test-`), the full `scripts/test.sh` (`-test-full-`), `scripts/test-netpol.sh` on small fixture matrices, stubs and their scripts, reviewers' re-runs, Celery's source read from the worker image. Some ran on an uncommitted `smoke.py`, as the file says |
| `imagetools-local-` | How `docker buildx imagetools inspect` and `kubectl --ignore-not-found` answer for something absent |
| `install-tools-retry-check` | The curl options of `scripts/install-tools.sh`, as `30f422a` and `6edde64` set them, against a local stub that answers 504 three times and then 200 |
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
| `netpol-` | `scripts/test-netpol.sh`: a TSV per run by UTC start, terminal output by source namespace (`-foundation-`, `-infisical-`), and checks from real pods. A TSV with `fixture` in its note column comes from `harness-netpol-fixtures-*`, and is not a run of the real matrix |
| `plane-dev-` | Plane in dev before the branded images were promoted at `4f622e3`: first boot, smoke, PSA dry run, rollouts and quota, startup, memory, worker, `/live`, cookie attributes, public board, PDF export, page duplicate, the pod restart drill, the NetworkPolicy matrix, two screenshots of the upstream UI. `plane-dev-final-*` is later: `make test-e2e` and the running state on the final images |
| `plane-prod-sim-` | Plane in prod-sim on upstream images, before `0af8956`: first boot, smoke, concurrent load with dev, separation attempts between the environments (network and state, with the scripts saved as `*-script.py.txt`), pod restart drills, worker and broker restart, memory samples, snapshots, and the proposed `smoke.py` patch |
| `publish-evidence-` | The negative control for `scripts/publish-evidence.sh`, the script that ran it, and the check by hand of what it published (`-control-`, `-check-`), the session rule's own control and script (`-session-control-`), and what each later publish printed (`-final-`) |
| `quota-budget-` | Plane pods' requests against the quota in `modules/foundation`, from rendered manifests |
| `registry-memory-` | H39, how much memory `plane-registry` needs during a push, on scratch containers |
| `render-m4-m7-` | `make render`, `render.sh --check`, kubeconform, conftest and negative controls from the render fixes |
| `restore-` | JSON from `scripts/restore.sh`: each step with its status, for the in-place Infisical restores, for Plane in prod-sim and dev, and for the clean restore (`restore-clean-`). A refusal reads `result: FAIL` and stops early, as `restore-prod-sim-20261105T073428Z.json` does. `restore-smoke-*` is the proof step's smoke. Each drill's full restore has its set: `restore-clean-20261105T081017Z.json` for the first run, on the script from before the recovery fixes, and `restore-clean-20261105T124518Z.json`, with `restore-infisical-20261105T124950Z.json`, `restore-dev-20261105T125720Z.json` and `restore-prod-sim-20261105T130009Z.json`, for the run with them merged |
| `routes-` | `tests/routes/internal-routes.sh` before and after the allow list (H17) |
| `shellcheck-ops-` | shellcheck and bash 3.2 syntax on the entry-point scripts |
| `smoke-` | JSON from `tests/e2e/smoke.py`, by environment and UTC start, with the process id when `scripts/test.sh` ran it, or by the run's own id when it ran directly, such as PERS-3's `smoke-dev-d751a926.json`. `smoke-dev-20261104T225624Z.json` is a FAIL, 37 of 38 |
| `status-real-` | `make status` on the cluster, before Argo CD was installed |
| `terraform-` | Terraform and TFLint static checks, and mock-provider tests on a throwaway copy |
| `test-` | `scripts/test.sh` summaries: one line per test with its label and evidence path, by UTC start |
| `test_` | Scenario tests of the entry points with stubbed commands (`-stub-`), with no cluster. They show the scripts' logic and nothing about the platform |
| `traefik-` | Routes through Traefik, and the source address seen at the NodePort |
| `validate-manifests-ops-` | `scripts/ci/validate-manifests.sh` during the entry-point work |
| `wayline-` | Early branding builds and checks. `wayline-assets-sheet.png` is the contact sheet of generated images. The final build is in [branding/](branding/README.md) |
