#!/usr/bin/env bash
# Promotion invariant: nothing reaches prod-sim unless dev recorded that digest first.
#
#   scripts/ci/check-promoted-digests.sh                every digest prod-sim uses now
#   scripts/ci/check-promoted-digests.sh sha256:...     just these digests
#
# It cannot tell order inside one commit, so a change adding a digest to both environments at
# once passes. Human review of the promotion pull request covers that.
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
cd "$ROOT"

DEV_RECORD=(helm/plane/overlays/dev/kustomization.yaml gitops/environments/dev/manifests.yaml)
PROD_SIM=(helm/plane/overlays/prod-sim/kustomization.yaml gitops/environments/prod-sim/manifests.yaml)
NULL_DIGEST="sha256:$(printf '0%.0s' {1..64})"

# Promoting one digest is strict: it must already be in history. Checking the tree as a whole also
# accepts dev's current files, so make ci works on changes not committed yet. In CI those files are
# the commit under test, so nothing weakens there.
STRICT=no
if [[ $# -gt 0 ]]; then
  STRICT=yes
  digests=("$@")
else
  digests=()
  # A while loop, not mapfile: macOS ships bash 3.2.
  while read -r digest; do digests+=("$digest"); done < <(grep -hoE 'sha256:[a-f0-9]{64}' "${PROD_SIM[@]}" | sort -u)
  [[ ${#digests[@]} -gt 0 ]] || die "no digests found in ${PROD_SIM[*]}"
fi

has_history=yes
git rev-parse -q --verify HEAD >/dev/null || has_history=no
if [[ "$has_history" == yes && "$(git rev-parse --is-shallow-repository)" == true ]]; then
  die "shallow clone: this check reads history, so CI must check out with fetch-depth: 0"
fi
[[ "$has_history" == yes ]] || warn "no commits yet, so comparing against the dev files on disk instead of their history"

missing=0
for digest in "${digests[@]}"; do
  # The failure drill records this digest in dev on purpose. It must never travel further.
  if [[ "$digest" == "$NULL_DIGEST" ]]; then
    warn "$digest is the failure-drill digest and may not reach prod-sim"
    missing=$((missing + 1))
    continue
  fi
  found=""
  if [[ "$has_history" == yes ]]; then
    found="$(git log -n 1 --format=%H -S"$digest" -- "${DEV_RECORD[@]}")"
  fi
  if [[ -z "$found" && ( "$has_history" == no || "$STRICT" == no ) ]]; then
    found="$(grep -lF "$digest" "${DEV_RECORD[@]}" || true)"
  fi
  if [[ -z "$found" ]]; then
    warn "$digest was never recorded for dev"
    missing=$((missing + 1))
  fi
done

[[ "$missing" -eq 0 ]] || die "$missing digest(s) may not be in prod-sim"
ok "${#digests[@]} digest(s) were recorded for dev"
