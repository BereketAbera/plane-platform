#!/usr/bin/env bash
# Copyright (c) 2026 Bereket Abera
# SPDX-License-Identifier: AGPL-3.0-only
#
# Proves the authoring loop: a scratch edit, new file and deletion in the patchwork survive save-patch
# and a rebuild from clean byte for byte, and removing the patch restores the previous tree.
# Run it only when nobody else is authoring, because it compares whole trees.
# shellcheck source=../scripts/lib.sh
source "$(dirname "$0")/../scripts/lib.sh"

SCRATCH=99-roundtrip-scratch
EDIT=packages/constants/src/metadata.ts
NEWFILE=packages/constants/src/wayline-roundtrip-scratch.txt
GONE=apps/web/app/layout.tsx

tree_of_patchwork() {
  # The whole working tree as a tree hash, using a private index so nothing shared moves.
  local idx="$BUILD_DIR/tmp/rt.$$.index"
  GIT_INDEX_FILE="$idx" wgit -C "$PATCHWORK" read-tree "$BASE_TAG"
  GIT_INDEX_FILE="$idx" wgit -C "$PATCHWORK" add --all .
  GIT_INDEX_FILE="$idx" wgit -C "$PATCHWORK" write-tree
  rm -f "${idx:?}"
}
tree_of_src() { wgit -C "$SRC" rev-parse 'HEAD^{tree}'; }

mkdir -p "$BUILD_DIR/tmp"
restore() {
  rm -f "${PATCHES:?}/${SCRATCH:?}.patch" "${PATCHWORK:?}/${NEWFILE:?}"
  wgit -C "$PATCHWORK" show "$BASE_TAG:$EDIT" >"$PATCHWORK/$EDIT"
  wgit -C "$PATCHWORK" show "$BASE_TAG:$GONE" >"$PATCHWORK/$GONE"
}
trap restore EXIT

"$WAYLINE/scripts/patchwork.sh" >/dev/null

log "Before: clean apply"
WAYLINE_SKIP_CODEMOD=yes "$WAYLINE/scripts/apply.sh" >/dev/null
before="$(tree_of_src)"
[[ "$before" == "$(tree_of_patchwork)" ]] || die "patchwork and a clean apply differ before the test"
ok "patchwork tree equals clean apply: $before"

log "Scratch edit, new file, deletion"
printf '\nexport const WAYLINE_ROUNDTRIP = "scratch";\n' >>"$PATCHWORK/$EDIT"
printf 'scratch\n' >"$PATCHWORK/$NEWFILE"
rm -f "${PATCHWORK:?}/${GONE:?}"
"$WAYLINE/scripts/save-patch.sh" "$SCRATCH" "$EDIT" "$NEWFILE" "$GONE"
want="$(tree_of_patchwork)"

log "Rebuild from clean"
WAYLINE_SKIP_CODEMOD=yes "$WAYLINE/scripts/apply.sh" >/dev/null
got="$(tree_of_src)"
[[ "$got" == "$want" ]] || die "rebuilt tree $got differs from the patchwork $want"
ok "identical tree after save and rebuild: $got"

log "Remove the scratch patch"
restore
trap - EXIT
WAYLINE_SKIP_CODEMOD=yes "$WAYLINE/scripts/apply.sh" >/dev/null
[[ "$(tree_of_src)" == "$before" ]] || die "tree did not return to $before"
[[ "$(tree_of_patchwork)" == "$before" ]] || die "patchwork did not return to $before"
ok "back to $before, scratch patch gone"
