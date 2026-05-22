#!/usr/bin/env bash
# Copyright (c) 2026 Bereket Abera
# SPDX-License-Identifier: AGPL-3.0-only
#
# Fresh source tree in .build/plane-src: pinned checkout, overlay check, overlay, every patch in numeric
# order, codemod. Order matters: patches apply before the codemod, so they are authored against
# unrewritten text. A failed hunk stops everything.
#
# Patches apply with plain git apply, never --3way. A 3-way merge needs the old base blob, and a fresh
# depth-1 tree does not have it, so the same inputs could pass on one machine and fail on another. To
# rebase patches after a bump use patchwork.sh --rebase-from <old tag>, which fetches that blob on purpose.
#
#   apps/wayline/scripts/apply.sh
#   WAYLINE_SKIP_CODEMOD=yes apps/wayline/scripts/apply.sh    overlay and patches only
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

require_tools git rsync node
acquire_build_lock
"$WAYLINE/scripts/fetch.sh"

log "Overlay against the pinned commit"
"$WAYLINE/scripts/overlay-lock.sh" --check "$SRC"
node "$WAYLINE/assets/generate.mjs" --verify --against "$SRC"

log "Overlay"
rsync -a --exclude .DS_Store "$OVERLAY/" "$SRC/"
wgit -C "$SRC" add --all
# Force, because an upstream .gitignore rule must not hide an overlay file from the baseline.
(cd "$OVERLAY" && find . -type f ! -name .DS_Store -print0) \
  | GIT_LITERAL_PATHSPECS=1 wgit -C "$SRC" add --force --pathspec-from-file=- --pathspec-file-nul
wgit -C "$SRC" commit --quiet --allow-empty -m "wayline overlay"

count=0
while read -r patch; do
  [[ -n "$patch" ]] || continue
  name="$(basename "$patch" .patch)"
  valid_patch_name "$name" || die "bad patch name: $name, expected NN-area.patch"
  if ! wgit -C "$SRC" apply --index --whitespace=nowarn "$patch"; then
    die "patch failed: $name. It no longer fits upstream, and nothing was merged. Rebase it with patchwork.sh --rebase-from <old tag>"
  fi
  count=$((count + 1))
done < <(list_patches)
wgit -C "$SRC" commit --quiet --allow-empty -m "wayline patches ($count)"
ok "$count patches applied"

if [[ "${WAYLINE_SKIP_CODEMOD:-}" != yes ]]; then
  log "Codemod"
  node "$WAYLINE/codemod/rebrand.mjs" "$SRC"
fi
