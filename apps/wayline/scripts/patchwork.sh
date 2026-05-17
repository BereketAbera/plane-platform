#!/usr/bin/env bash
# Copyright (c) 2026 Bereket Abera
# SPDX-License-Identifier: AGPL-3.0-only
#
# Creates .build/plane-patchwork, the tree patch authors edit: pristine source plus overlay, committed
# and tagged wayline-base, with existing patches applied on top in the working tree so authors see
# each other's work. It never runs the codemod. See AUTHORING.md.
#
#   apps/wayline/scripts/patchwork.sh           create it, or report that it already exists
#   apps/wayline/scripts/patchwork.sh --reset   delete and recreate it; destroys unsaved edits
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

CREATE_LOCK="$BUILD_DIR/patchwork.lockdir"

if [[ "${1:-}" == "--reset" ]]; then
  rm -rf "${PATCHWORK:?}"
elif [[ -d "$PATCHWORK/.git" ]] && wgit -C "$PATCHWORK" rev-parse -q --verify "refs/tags/$BASE_TAG" >/dev/null; then
  ok "$PATCHWORK already exists; left as is so nobody's edits are lost (--reset recreates it)"
  exit 0
fi

# Two authors starting at once: one creates, the other waits and reuses it.
until mkdir "$CREATE_LOCK" 2>/dev/null; do sleep 2; done
trap 'rm -rf "${CREATE_LOCK:?}"' EXIT
if [[ -d "$PATCHWORK/.git" ]] && wgit -C "$PATCHWORK" rev-parse -q --verify "refs/tags/$BASE_TAG" >/dev/null; then
  ok "$PATCHWORK was created by someone else meanwhile"
  exit 0
fi
rm -rf "${PATCHWORK:?}"

"$WAYLINE/scripts/fetch.sh" --cache-only
wgit init --quiet "$PATCHWORK"
wgit -C "$PATCHWORK" remote add origin "$UPSTREAM_CACHE"
wgit -C "$PATCHWORK" fetch --quiet --depth 1 --no-tags origin refs/wayline/pinned
wgit -C "$PATCHWORK" checkout --quiet --force --detach "$UPSTREAM_COMMIT"
rsync -a --exclude .DS_Store "$OVERLAY/" "$PATCHWORK/"
wgit -C "$PATCHWORK" add --all
# Force, because an upstream .gitignore rule must not hide an overlay file from the baseline.
(cd "$OVERLAY" && find . -type f ! -name .DS_Store -print0) \
  | GIT_LITERAL_PATHSPECS=1 wgit -C "$PATCHWORK" add --force --pathspec-from-file=- --pathspec-file-nul
wgit -C "$PATCHWORK" commit --quiet --allow-empty -m "wayline base: $UPSTREAM_TAG plus overlay"
wgit -C "$PATCHWORK" tag "$BASE_TAG"

while read -r patch; do
  [[ -n "$patch" ]] || continue
  # Working tree only, so the index stays at the baseline and save-patch diffs against it.
  wgit -C "$PATCHWORK" apply --whitespace=nowarn "$patch" || die "patch failed in the patchwork: $patch"
done < <(list_patches)

ok "$PATCHWORK ready: baseline tag $BASE_TAG, $(list_patches | grep -c . || true) patches applied"
