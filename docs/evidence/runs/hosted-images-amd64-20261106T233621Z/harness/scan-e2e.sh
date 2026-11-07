#!/usr/bin/env bash
# Scratch harness: scan-images.sh with real trivy on hand-made images in a throwaway loopback registry, in a temp copy of the scripts.
set -uo pipefail
S="$1"; AMD="$2"; ARM="$3"
REPO=/Users/bek/dev/pr/plane-platform
T="$S/scan-tree"
rm -rf "$T"; mkdir -p "$T/scripts/ci" "$T/scripts/lib" "$T/.tools/bin" "$T/.build/plane-src"
cp "$REPO/scripts/ci/scan-images.sh" "$REPO/scripts/ci/scan-images-report.py" "$REPO/scripts/ci/lib-manifests.sh" "$T/scripts/ci/"
cp "$REPO/scripts/lib/common.sh" "$T/scripts/lib/"
cp "$REPO/scripts/install-tools.sh" "$T/scripts/"
cp "$REPO/tools.lock" "$T/"
cp "$REPO/.tools/bin/trivy" "$REPO/.tools/bin/.trivy.version" "$T/.tools/bin/"
printf '{"name":"x","lockfileVersion":3,"packages":{}}\n' >"$T/.build/plane-src/package-lock.json"
digests() { printf 'web\t%s\t%s\n' "${1%@*}" "${1#*@}" >"$T/.build/digests.tsv"; }
run() { # run <label> <expected exit> [env...]
  local label="$1" want="$2"; shift 2
  local out="$S/scan-out.txt"
  ( cd "$T" && env SCAN_MIN_FREE_GIB=5 SCAN_ONLY=built "$@" ./scripts/ci/scan-images.sh ) >"$out" 2>&1
  local got=$?
  if [[ "$got" == "$want" ]]; then echo "PASS $label: exit $got"; else echo "FAIL $label: exit $got, wanted $want"; fi
  grep -E 'Reading each|Scanned for|is linux/|PASS:|FAIL:|^fail|must be|does not apply' "$out" | sed -E 's/\x1b\[[0-9;]*m//g; s/^/     /' | cut -c1-230
}
digests "$AMD"
run "plain amd64, PLATFORM=linux/amd64" 0 PLATFORM=linux/amd64
run "plain amd64, no PLATFORM (arm64 default)" 1
run "plain amd64, PLATFORM=linux/arm64" 1 PLATFORM=linux/arm64
digests "$ARM"
run "plain arm64, PLATFORM=linux/amd64" 1 PLATFORM=linux/amd64
run "plain arm64, no PLATFORM" 0
run "SCAN_ONLY=built refuses SCAN_ALSO_PLATFORM" 1 PLATFORM=linux/amd64 SCAN_ALSO_PLATFORM=linux/arm64
run "a malformed PLATFORM is refused" 1 PLATFORM=amd64
run "a variant in PLATFORM is refused" 1 PLATFORM=linux/arm64/v8
d="$(ls -dt "$T"/.local/evidence-raw/scan-images-* | head -1)"
echo "--- newest results: $(basename "$d")"; cat "$d/platform.txt"; cut -f1,4,5,7,8 "$d/summary.tsv" | cut -c1-150
