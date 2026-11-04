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
#   apps/wayline/scripts/patchwork.sh --rebase-from <old tag>
#       After a bump: recreate it with the old tag's objects present, so each patch can apply with --3way.
#       Conflicts stay as markers in the working tree. Resolve them, then save-patch.sh each patch again.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

CREATE_LOCK="$BUILD_DIR/patchwork.lockdir"

REBASE_FROM=""
if [[ "${1:-}" == "--rebase-from" ]]; then
  REBASE_FROM="${2:?usage: patchwork.sh --rebase-from <old tag>}"
  rm -rf "${PATCHWORK:?}"
elif [[ "${1:-}" == "--reset" ]]; then
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

if [[ -n "$REBASE_FROM" ]]; then
  # A patch's index lines name blobs from the commit it was written against. These fetches bring them in.
  wgit -C "$UPSTREAM_CACHE" fetch --quiet --depth 1 --no-tags "${PLANE_SOURCE_MIRROR:-$UPSTREAM_REPO}" "refs/tags/$REBASE_FROM:refs/wayline/rebase-from"
  wgit -C "$PATCHWORK" fetch --quiet --depth 1 --no-tags origin refs/wayline/rebase-from
fi
conflicted=()
while read -r patch; do
  [[ -n "$patch" ]] || continue
  if [[ -n "$REBASE_FROM" ]]; then
    wgit -C "$PATCHWORK" apply --3way --whitespace=nowarn "$patch" || conflicted+=("$(basename "$patch")")
    # Leave the markers, but put the index back at the baseline, which is what save-patch diffs against.
    wgit -C "$PATCHWORK" reset --quiet
    continue
  fi
  # Working tree only, so the index stays at the baseline and save-patch diffs against it.
  wgit -C "$PATCHWORK" apply --whitespace=nowarn "$patch" || die "patch failed in the patchwork: $patch"
done < <(list_patches)
if [[ ${#conflicted[@]} -gt 0 ]]; then
  warn "patches with conflicts: ${conflicted[*]}"
  wgit -C "$PATCHWORK" grep -l --untracked -E '^(<<<<<<<|>>>>>>>) ' -- apps packages >&2 || true
fi

ok "$PATCHWORK ready: baseline tag $BASE_TAG, $(list_patches | grep -c . || true) patches applied"
