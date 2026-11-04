#!/usr/bin/env bash
# Promotion invariant: nothing reaches prod-sim unless dev recorded that digest for that image first.
#
#   scripts/ci/check-promoted-digests.sh                        every image prod-sim uses now
#   scripts/ci/check-promoted-digests.sh <name>=sha256:...      just these, <name> as in images[].name
#
# The name is part of the check because a digest recorded for dev under another image proves nothing
# about this one: runs 41905611391 and 41908167069 on GitHub accepted the admin digest as web.
#
# It cannot tell order inside one commit, so a change adding a digest to both environments at
# once passes. Human review of the promotion pull request covers that. It proves dev recorded the
# digest, not that dev ran it: scripts/promote.sh asks the cluster that, when it can reach one.
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
cd "$ROOT"

DEV_OVERLAY=helm/plane/overlays/dev/kustomization.yaml
DEV_RENDERED=gitops/environments/dev/manifests.yaml
PROD_SIM_OVERLAY=helm/plane/overlays/prod-sim/kustomization.yaml
PROD_SIM_RENDERED=gitops/environments/prod-sim/manifests.yaml
NULL_DIGEST="sha256:$(printf '0%.0s' {1..64})"

digest_under_name() { # digest_under_name <name>, reading an overlay on stdin
  NAME="$1" yq -r '.images[] | select(.name == strenv(NAME)) | .digest'
}

# Was this digest ever in dev's overlay under this name? -S finds each commit that added or removed
# the digest anywhere in the file, and the file at that commit says which image it belonged to.
recorded_under_name() { # recorded_under_name <name> <digest>
  local commit
  while read -r commit; do
    [[ -n "$commit" ]] || continue
    if [[ "$(git show "$commit:$DEV_OVERLAY" 2>/dev/null | digest_under_name "$1" || true)" == "$2" ]]; then
      return 0
    fi
  done < <(git log --format=%H -S"$2" -- "$DEV_OVERLAY")
  return 1
}

recorded_for_any_image() { # recorded_for_any_image <digest>
  [[ -n "$(git log -n 1 --format=%H -S"$1" -- "$DEV_OVERLAY" "$DEV_RENDERED")" ]]
}

# Promoting one image is strict: the pair must already be in history. Checking the tree as a whole
# also accepts dev's current overlay, so make ci works on changes not committed yet. In CI that file
# is the commit under test, so nothing weakens there.
STRICT=no
pairs=()
if [[ $# -gt 0 ]]; then
  STRICT=yes
  for pair in "$@"; do
    [[ "$pair" =~ ^[^=]+=sha256:[a-f0-9]{64}$ ]] || die "usage: $0 [<image name>=sha256:<64 hex>...], got '$pair'"
    pairs+=("$pair")
  done
else
  # A while loop, not mapfile: macOS ships bash 3.2.
  while read -r name digest; do
    [[ -n "$name" ]] && pairs+=("$name=$digest")
  done < <(yq -r '.images[] | .name + " " + .digest' "$PROD_SIM_OVERLAY")
  [[ ${#pairs[@]} -gt 0 ]] || die "no images found in $PROD_SIM_OVERLAY"
fi

has_history=yes
git rev-parse -q --verify HEAD >/dev/null || has_history=no
if [[ "$has_history" == yes && "$(git rev-parse --is-shallow-repository)" == true ]]; then
  die "shallow clone: this check reads history, so CI must check out with fetch-depth: 0"
fi
[[ "$has_history" == yes ]] || warn "no commits yet, so comparing against the dev files on disk instead of their history"

missing=0
for pair in "${pairs[@]}"; do
  name="${pair%=*}"
  digest="${pair##*=}"
  # The failure drill records this digest in dev on purpose. It must never travel further.
  if [[ "$digest" == "$NULL_DIGEST" ]]; then
    warn "$digest is the failure-drill digest and may not reach prod-sim"
    missing=$((missing + 1))
    continue
  fi
  if [[ "$has_history" == yes ]] && recorded_under_name "$name" "$digest"; then
    continue
  fi
  if [[ ("$has_history" == no || "$STRICT" == no) && "$(digest_under_name "$name" <"$DEV_OVERLAY")" == "$digest" ]]; then
    continue
  fi
  if recorded_for_any_image "$digest"; then
    warn "$digest was recorded for dev under another image, not $name"
  else
    warn "$digest was never recorded for dev, so it may not be $name in prod-sim"
  fi
  missing=$((missing + 1))
done

checked=${#pairs[@]}
if [[ "$STRICT" == no ]]; then
  # Rendered digests the overlay does not set come from a chart default, so no image name goes with
  # them. Dev must still have rendered the same digest.
  overlay_digests="$(yq -r '.images[].digest' "$PROD_SIM_OVERLAY")"
  while read -r digest; do
    grep -qxF "$digest" <<<"$overlay_digests" && continue
    checked=$((checked + 1))
    if [[ -z "$(git log -n 1 --format=%H -S"$digest" -- "$DEV_RENDERED" 2>/dev/null)" ]] && ! grep -qF "$digest" "$DEV_RENDERED"; then
      warn "$digest is in $PROD_SIM_RENDERED and was never rendered for dev"
      missing=$((missing + 1))
    fi
  done < <(grep -hoE 'sha256:[a-f0-9]{64}' "$PROD_SIM_RENDERED" | sort -u)
fi

[[ "$missing" -eq 0 ]] || die "$missing image(s) may not be in prod-sim"
ok "$checked image(s) were recorded for dev under the same name"
