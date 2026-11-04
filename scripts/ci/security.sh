#!/usr/bin/env bash
# Secret and misconfiguration scanning. Holds no secrets and needs none, which limits what a
# compromised scanner could steal. Trivy runs from the pinned binary in tools.lock, never through
# trivy-action, whose tags were force-pushed with malware in March 2026 (GHSA-69fq-xp46-6x23).
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

"$ROOT/scripts/install-tools.sh" gitleaks trivy >/dev/null
cd "$ROOT"

failed=0
run() { # run <label> <command...>
  local label="$1"; shift
  log "$label"
  if "$@"; then ok "$label"; else warn "$label FAILED"; failed=$((failed + 1)); fi
}

GITLEAKS=(--config .gitleaks.toml --redact --no-banner --exit-code 1 --log-level warn)

# Generated files, vendored code and host state. Upstream chart defaults are public example
# values, and .local/ legitimately holds real secrets that must not be scanned into CI output.
# shellcheck disable=SC2054  # the comma belongs to the --severity value
TRIVY=(--cache-dir "$LOCAL_DIR/trivy-cache" --ignorefile .trivyignore --exit-code 1 --severity HIGH,CRITICAL
  --skip-dirs .tools --skip-dirs .local --skip-dirs .git --skip-dirs .build --skip-dirs helm/plane/vendor)

history_scan() {
  # Before the first commit there is no history to read.
  git rev-parse -q --verify HEAD >/dev/null || { warn "no commits yet, skipping history scan"; return 0; }
  gitleaks git "${GITLEAKS[@]}" .
}

run "gitleaks history" history_scan
# The working tree too, so make ci catches a secret before it is committed.
run "gitleaks working tree" gitleaks dir "${GITLEAKS[@]}" .
run "trivy config" trivy config "${TRIVY[@]}" .
run "trivy fs" trivy fs --no-progress --scanners vuln,secret "${TRIVY[@]}" .

[[ "$failed" -eq 0 ]] || die "$failed security check(s) failed"
ok "security checks passed"
