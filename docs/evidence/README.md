# Evidence

This directory holds the raw output behind every result in [validation.md](../validation.md) and every
measured number in [resource-utilization.md](../resource-utilization.md). Contract section 12 makes it binding:
a claim in the docs needs evidence here, captured from a real run with its date and command.

## Rules

1. **Evidence is raw output.** It is what the command printed or wrote. It is never summarized, reformatted,
   reordered or trimmed by hand. A summary belongs in the doc that links to the file.
2. **Secrets are scrubbed, and that is the only permitted edit.** Replace a secret value with `<redacted>`, keep
   everything else byte for byte, and say so in the index below. If a file needs more than that, do not commit it.
3. **Failed runs stay.** A FAIL or BLOCKED run is evidence too. Commit it, and link it from the row. A later PASS
   adds a file. It does not replace the earlier one.
4. **No file, no result.** A run with no file here stays NOT RUN in the matrix, however it went.
5. **Date and command go in the index when the file lacks them.** Do not add them to the raw file.

Status values are exactly PASS, FAIL, BLOCKED and NOT RUN. [validation.md](../validation.md) defines them.

## Layout

The directory is flat. Each file is named after the test row it supports, lower case, with the UTC start of the run:

```text
docs/evidence/
  README.md                         this file, including the index
  day1-gates.txt                    the one exception to the naming rule, kept as named at capture
  <test-id>-<YYYYMMDDTHHMMSSZ>.<ext>
```

For example, `net-2-<timestamp>.tsv` for row NET-2. A run that produces a directory, such as the load test, keeps its
own file names under `<test-id>-<timestamp>/`.

The earlier gate run and the cluster creation log have no row of their own, so they use the step name in place of `<test-id>`,
and the modification time of the source file in place of the start time. The index says so for each.

## Getting from a run to a committed file

Scripts write raw output to `.local/evidence-raw/`, which is gitignored. Nothing reaches this directory on its own.
Copying is a deliberate step, because `.local/` also holds real secrets.

```bash
# 1. Copy one named file. Never copy .local/ or a whole directory without reading what is in it.
cp .local/evidence-raw/<file> docs/evidence/<test-id>-<YYYYMMDDTHHMMSSZ>.<ext>

# 2. Scan it. Gitleaks also runs at commit time, but a scan does not replace reading the file.
.tools/bin/gitleaks dir docs/evidence/<file> --no-banner --config .gitleaks.toml --redact

# 3. Add a row to the index below, then change the status in docs/validation.md.
```

### What each entry point writes

| Entry point | Raw output | Notes |
|---|---|---|
| `tests/gates/day1.sh` (`make gates`) | stdout only | Capture it with `tee`. The script stamps no date or command |
| `tests/e2e/smoke.py` (`make test-e2e`) | `.local/evidence-raw/smoke-<env>-<run>.json` | Credentials go to `.local/test-accounts.env`, not here |
| `scripts/test-netpol.sh` (`make test-netpol`) | `.local/evidence-raw/netpol-<timestamp>.tsv` | One line per matrix row |
| `scripts/test-alert.sh` (`make test-alert`) | `.local/evidence-raw/alert-test-<env>-<timestamp>.json` | Timings for each stage |
| `tests/load/run.sh` (`make test-load`) | `.local/evidence-raw/load-<run>/` | `results.json` plus snapshots. Read `job.yaml` and `k6.log` before copying |
| `tests/drills/*.sh` | `.local/evidence-raw/drill-<name>-<timestamp>.log` | The pod restart drill also writes one JSON file per round |
| `scripts/rotate.sh` (`make rotate`) | `.local/evidence-raw/rotate-<env>-<timestamp>.log` | The script writes results and counts, never values |
| `scripts/backup.sh` (`make backup`) | `.local/backups/<env>/<id>/manifest.json`, `SHA256SUMS` | Copy only these two files. The manifest holds a truncated key hash, never the key. Never copy the dumps |
| `scripts/restore.sh` (`make restore`) | `.local/evidence-raw/restore-<env>-<timestamp>.json` | Plus `restore-smoke-<env>-<timestamp>.json` from the proof step |

### Never copy these

| Path | Why |
|---|---|
| `.local/secret-zero/` | Infisical's encryption key, auth secret and database password. `rotate.sh` also keeps its journal here, holding old and new passwords until a rotation ends |
| `.local/test-accounts.env` | Generated test credentials |
| `.local/kubeconfig` | Cluster admin access |
| `.local/backups/` dumps | `scripts/backup.sh` notes that dumps hold password hashes and plaintext API tokens |
| `.local/terraform/` | Terraform state |

## Index

One row per file. Date and command come from the file itself when it records them. Otherwise the row says where they
came from.

| File | Test rows | Result | Date | Command | Commit | Edits |
|---|---|---|---|---|---|---|
| [day1-gates.txt](day1-gates.txt) | G1-1 to G5-2 | 9 PASS, 0 FAIL, as printed by the file | 2026-11-04 21:49:52 +0300, from the modification time of the source file. The output carries no date | `tests/gates/day1.sh`, inferred from the output format. The output does not record the command, or whether `make gates` called it | Script added in `0f7ba03`, committed one second after that time | None. Byte-identical to `.local/evidence-raw/day1-gates-2.txt`. Scanned with gitleaks, and read in full: no secrets. The hashes in it are an image digest and the commit of a throwaway Git repository |
| [day1-gates-20261104T184733Z.txt](day1-gates-20261104T184733Z.txt) | G5-1, earlier run | 8 PASS, 1 FAIL, as printed by the file | 2026-11-04 21:47:33 +0300, from the modification time of the source file, which is also the time in the name. The output carries no date | `tests/gates/day1.sh`, inferred from the output format, before the fix to its name lookup | Before `0f7ba03`, which holds the fixed script | None. Byte-identical to `.local/evidence-raw/day1-gates-1.txt`. Scanned with gitleaks, and read in full: no secrets |
| [cluster-up-20261104T184521Z.log](cluster-up-20261104T184521Z.log) | None. Backs the status line in the [README](../../README.md) | Exit status not recorded. The last line reports `cluster ready` | 2026-11-04 21:45:21 +0300, from the modification time of the source file, which is also the time in the name | `scripts/cluster-up.sh`, inferred from the output format | Not recorded | None, so it keeps terminal color codes and the build host's home path. Byte-identical to `.local/evidence-raw/cluster-up-1.log`. Scanned with gitleaks, and read in full: no secrets |

The earlier gate run printed 8 passed and 1 failed. The failing line was "pods resolve the Docker-network name". A comment
in `tests/gates/day1.sh` attributes that failure to the test itself: busybox `nslookup` exits non-zero on the first NXDOMAIN
from a search domain, and the fix was a trailing dot on the name.
