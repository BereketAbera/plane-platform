#!/usr/bin/env bash
set -uo pipefail
S="$1"; AMD="$2"; ARM="$3"; R=/Users/bek/dev/pr/plane-platform
run() { # run <label> <expected> <ref> [env...]
  local label="$1" want="$2" ref="$3"; shift 3
  printf 'other\t%s\t%s\n' "${ref%@*}" "${ref#*@}" >"$S/smoke-digests.tsv"
  env "$@" "$R/apps/wayline/checks/smoke-images.sh" "$S/smoke-digests.tsv" >"$S/smoke-out.txt" 2>&1
  local got=$?
  if [[ "$got" == "$want" ]]; then echo "PASS $label: exit $got"; else echo "FAIL $label: exit $got, wanted $want"; fi
  sed -E 's/\x1b\[[0-9;]*m//g; s/^/     /' "$S/smoke-out.txt" | cut -c1-200 | grep -vE '^ *$' | tail -5
  docker rmi "$ref" >/dev/null 2>&1 || true
}
run "plain arm64, no PLATFORM" 0 "$ARM"
run "plain amd64, no PLATFORM" 1 "$AMD"
run "plain amd64, PLATFORM=linux/arm64" 1 "$AMD" PLATFORM=linux/arm64
run "plain amd64, PLATFORM=linux/amd64" 0 "$AMD" PLATFORM=linux/amd64
run "plain arm64, PLATFORM=linux/amd64" 1 "$ARM" PLATFORM=linux/amd64
run "a malformed PLATFORM" 1 "$ARM" PLATFORM=x86_64
