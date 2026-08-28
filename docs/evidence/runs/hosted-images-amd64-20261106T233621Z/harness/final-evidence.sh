#!/usr/bin/env bash
# Scratch: every local check of this work, once, on the final code, with raw output kept in .local/evidence-raw.
set -uo pipefail
S="$1"; R=/Users/bek/dev/pr/plane-platform
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
E="$R/.local/evidence-raw/hosted-images-amd64-$STAMP"
mkdir -p "$E/harness"
REG=ghcr.io/distribution/distribution:3.1.2@sha256:d106962e6fe3fa69c178cec77eeeee5edb626b8df6535b7bd6b95e658a0a5ca9
docker run -d --rm --name wayline-images-work-a --tmpfs /var/lib/registry:size=256m --publish 127.0.0.1:5073:5000 "$REG" >/dev/null
docker run -d --rm --name wayline-images-work-b --tmpfs /var/lib/registry:size=256m --publish 127.0.0.1:5074:5000 "$REG" >/dev/null
sleep 2
AMD="$(python3 -B "$S/push_case.py" localhost:5073 wayline/web amd64)"
ARM="$(python3 -B "$S/push_case.py" localhost:5073 wayline/web arm64)"
{ echo "$AMD amd64"; echo "$ARM arm64"; } >"$E/hand-made-images.txt"
cd "$R"
run() { # run <file> <command...>
  local f="$1"; shift
  { echo "\$ $*"; date -u +%Y-%m-%dT%H:%M:%SZ; "$@"; echo "[exit $?]"; } >"$E/$f" 2>&1 </dev/null
  echo "$f: $(tail -1 "$E/$f")"
}
run 01-layer-check-cases-with-registry.txt python3 -B apps/wayline/checks/layer-check-cases.py --registry localhost:5073
run 02-scan-report-selftest.txt python3 -B scripts/ci/scan-images-report.py --selftest
run 03-trivy-plain-manifest.txt bash "$S/trivy-plain.sh" "$S" "$AMD" "$ARM"
run 04-scan-images-end-to-end.txt bash "$S/scan-e2e.sh" "$S" "$AMD" "$ARM"
run 05-smoke-platform-check.txt bash "$S/smoke-prefix.sh" "$S" "$AMD" "$ARM"
run 06-copy-script-stubbed.txt bash "$S/copy-cases.sh" "$S"
run 07-copy-script-real-buildx-amd64.txt bash "$S/copy-real.sh" "$S"
run 08-build-images-calls-stubbed.txt bash "$S/build-args.sh" "$S"
run 09-pipefail-on-linux.txt docker run --rm python:3.13-slim-bookworm bash -c 'set -uo pipefail
for count in 700 850 950 1060; do a=$(for i in $(seq 1 $count); do echo "/usr/share/nginx/html/assets/instrument-sans-latin-ext-$i.woff2"; done); n=0; for i in $(seq 1 300); do if f="$(printf "%s\n" "$a" | head -1)"; then n=$((n+1)); fi; done; echo "listing of ${#a} bytes: printf into head -1 succeeded $n of 300"; done
html=$(python3 -c "print(\"<p>Plane brand all over this page, and more text here</p>\n\"*2000)"); oldfail=0; oldpass=0; newfail=0; newpass=0
for i in $(seq 1 200); do if printf "%s" "$html" | grep -oE ".{0,20}(Plane|plane\.so|makeplane).{0,20}" | grep -vqE "Built on Plane Community Edition"; then oldfail=$((oldfail+1)); else oldpass=$((oldpass+1)); fi; matches="$(grep -oE ".{0,20}(Plane|plane\.so|makeplane).{0,20}" <<<"$html")"; if grep -vqE "Built on Plane Community Edition" <<<"$matches"; then newfail=$((newfail+1)); else newpass=$((newpass+1)); fi; done
echo "a page carrying the brand 2000 times, 200 reads. As it was: FAIL $oldfail, wrongly PASS $oldpass. Now: FAIL $newfail, wrongly PASS $newpass"'
# Mutants, in a scratch copy
M="$S/mutant"; rm -rf "$M"; mkdir -p "$M/checks" "$M/runtime" "$M/ci"; cp "$R"/apps/wayline/checks/*.py "$M/checks/"; cp "$R/apps/wayline/runtime/Dockerfile.backend" "$M/runtime/"; cp "$R/scripts/ci/scan-images-report.py" "$M/ci/"
{
  echo "== mutant 1: oci_read reads a plain manifest of any architecture, as it did"; python3 "$S/mutate.py" "$M/checks/oci_read.py" 'if found != self.platform:' 'if False:'; python3 -B "$M/checks/layer-check-cases.py" 2>&1 | grep -E '^FAIL|wrong$'; cp "$R/apps/wayline/checks/oci_read.py" "$M/checks/"
  echo "== mutant 2: PLATFORM is not followed"; python3 "$S/mutate.py" "$M/checks/oci_read.py" 'return os.environ.get("PLATFORM") or DEFAULT_PLATFORM' 'return DEFAULT_PLATFORM'; python3 -B "$M/checks/layer-check-cases.py" 2>&1 | grep -E '^FAIL|wrong$'; cp "$R/apps/wayline/checks/oci_read.py" "$M/checks/"
  echo "== mutant 3: the report has no platform rule"; python3 "$S/mutate.py" "$M/ci/scan-images-report.py" 'if platforms and row["scanned"] == "yes" and row["platform"] not in (NO_PLATFORM, *platforms)' 'if False'; python3 -B "$M/ci/scan-images-report.py" --selftest 2>&1 | tail -1; cp "$R/scripts/ci/scan-images-report.py" "$M/ci/"
  echo "== mutant 4: the report lets an empty platform.txt through"; python3 "$S/mutate.py" "$M/ci/scan-images-report.py" 'if not platforms:' 'if False:'; python3 -B "$M/ci/scan-images-report.py" --selftest 2>&1 | tail -1
} >"$E/10-negative-controls.txt" 2>&1
echo "10-negative-controls.txt: $(grep -c . "$E/10-negative-controls.txt") lines"
# The published scan results of 2026-11-05 through the new report: arm64 as they were read, then held to amd64.
T="$S/report-regression"; rm -rf "$T"; mkdir -p "$T"; cp -R docs/evidence/security/scan-images-20261105T140048Z "$T/scan"
{
  printf 'linux/arm64\n' >"$T/scan/platform.txt"; python3 -B scripts/ci/scan-images-report.py "$T/scan" | tail -4; echo "[exit ${PIPESTATUS[0]}, published run's exit code was $(cat docs/evidence/security/scan-images-20261105T140048Z/exit-code.txt)]"
  printf 'linux/amd64\n' >"$T/scan/platform.txt"; python3 -B scripts/ci/scan-images-report.py "$T/scan" >"$T/amd64.txt"; echo "[held to linux/amd64: exit $?, $(grep -c 'and this scan is for linux/amd64' "$T/amd64.txt") images refused]"
} >"$E/11-report-on-published-scan.txt" 2>&1
echo "11-report-on-published-scan.txt: $(tail -1 "$E/11-report-on-published-scan.txt")"
docker stop wayline-images-work-a wayline-images-work-b >/dev/null 2>&1
# Kept from the runs earlier in this work, on the final script for 12 and on the base images for the rest.
cp "$S/smoke-linux-final.txt" "$E/12-smoke-web-admin-on-ubuntu-userland.txt"
cp "$S/smoke-linux-2.txt" "$E/13-smoke-new-script-and-cases-on-python-3.12.txt"
cp "$S/smoke-linux-old.txt" "$E/14-smoke-old-script-control-on-ubuntu-userland.txt"
cp "$S/preflight-layer-walk-amd64.txt" "$E/15-preflight-layer-walk-amd64-bases.txt"
cp "$S/trivy-bases.txt" "$E/16-preflight-critical-with-a-fix-amd64-against-arm64-bases.txt"
cp "$S/rehearse-amd64.txt" "$E/17-rehearsal-summary.txt"
cp "$S/rehearse-space.txt" "$E/18-rehearsal-space-build-steps-amd64-under-rosetta.txt"
cp "$S/rehearse-backend.txt" "$E/19-rehearsal-backend-build-steps-amd64-under-rosetta.txt"
for f in push_case.py trivy-plain.sh scan-e2e.sh smoke-prefix.sh copy-real.sh build-args.sh mutate.py rehearse-amd64.sh trivy-bases.sh final-evidence.sh; do cp "$S/$f" "$E/harness/"; done
cp "$S/harness/docker-wrapper" "$S/harness/run.sh" "$S/harness/run2.sh" "$S/harness/run3.sh" "$E/harness/"
# A made-up value, kept out of the copy so a scanner has nothing to read as a token.
sed 's/gho_FAKE[A-Z0-9]*/<made-up token>/' "$S/copy-cases.sh" >"$E/harness/copy-cases.sh"
echo "$E"
