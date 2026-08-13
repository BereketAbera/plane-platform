#!/usr/bin/env bash
# Copyright (c) 2026 Bereket Abera
# SPDX-License-Identifier: AGPL-3.0-only
#
# MUST NOT RUN until it exempts every digest in docs/evidence/promotions and the prod overlay. It keeps the newest <keep>
# versions and knows nothing of what production runs or what evidence names, so it could delete either, and a rollback would
# then have nothing to pull. images.yml no longer runs it, and until that exemption exists this only lists: DRY_RUN=yes.
#
# Deletes all but the newest <keep> versions of each Wayline image in GHCR. This is a precaution: GitHub's billing
# page says Container registry storage and bandwidth are currently free, with a month's notice before that changes,
# and nothing has been stored there yet to confirm how it is counted. It lists what it deletes, and DRY_RUN=yes only
# lists. A digest that dev or prod-sim still pins should be copied to the local registry first
# (scripts/ci/copy-to-local-registry.sh), which is why <keep> must be at least 2.
#
#   apps/wayline/scripts/prune-ghcr.sh <owner> [keep]
#
# Only names in images.txt are touched. Assumes a user-owned package; an organization needs /orgs/.
# Needs GH_TOKEN with package delete rights.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

owner="${1:?usage: prune-ghcr.sh <owner> [keep]}"
keep="${2:-2}"
[[ "$keep" -ge 2 ]] || die "keep must be at least 2, a promoted digest may still be in use"
[[ "${DRY_RUN:-no}" == yes ]] || die "this must not delete anything until it exempts every digest in docs/evidence/promotions and the prod overlay. DRY_RUN=yes only lists"

while read -r name _; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  package="wayline%2F$name"
  # Newest first, which is how the API returns them.
  if ! versions="$(gh api --paginate "/users/$owner/packages/container/$package/versions" --jq '.[] | "\(.id) \(.name)"' 2>"$BUILD_DIR/prune.err")"; then
    # A package that does not exist yet is fine. A token without rights must not look like an empty package.
    grep -q 'HTTP 404' "$BUILD_DIR/prune.err" || die "listing $name failed: $(cat "$BUILD_DIR/prune.err")"
    warn "$name has no package yet, skipping"
    continue
  fi
  while read -r id digest; do
    [[ -n "$id" ]] || continue
    if [[ "${DRY_RUN:-no}" == yes ]]; then
      log "would delete $name $digest"
    else
      log "deleting $name $digest"
      gh api --method DELETE "/users/$owner/packages/container/$package/versions/$id"
    fi
  done < <(printf '%s\n' "$versions" | tail -n +"$((keep + 1))")
done <"$WAYLINE/images.txt"
ok "pruned, keeping $keep versions per image"
