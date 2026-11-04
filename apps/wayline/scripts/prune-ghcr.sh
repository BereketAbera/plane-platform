#!/usr/bin/env bash
# Copyright (c) 2026 Bereket Abera
# SPDX-License-Identifier: AGPL-3.0-only
#
# Deletes all but the newest <keep> versions of each Wayline image in GHCR. The free private quota is
# 500 MB, so old versions cannot be left to pile up. It lists what it deletes, and DRY_RUN=yes only
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

while read -r name _; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  package="wayline%2F$name"
  # Newest first, which is how the API returns them.
  versions="$(gh api --paginate "/users/$owner/packages/container/$package/versions" --jq '.[] | "\(.id) \(.name)"' 2>/dev/null || true)"
  if [[ -z "$versions" ]]; then
    warn "no versions listed for $name, skipping"
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
