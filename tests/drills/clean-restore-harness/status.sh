#!/bin/bash
# Stub of scripts/status.sh for tests/drills/clean-restore-harness.sh. The last thing a whole make up runs, so this is
# where a scenario's measured cost of make up reaches the free disk: $H_STATE/up-uses-kib, once.
if [[ -s "$H_STATE/up-uses-kib" && -s "$H_STATE/free-kib" ]]; then
  printf '%s' "$(($(cat "$H_STATE/free-kib") - $(cat "$H_STATE/up-uses-kib")))" > "$H_STATE/free-kib"
  rm -f "$H_STATE/up-uses-kib"
fi
echo "status: stub"
