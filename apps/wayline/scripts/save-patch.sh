#!/usr/bin/env bash
# Copyright (c) 2026 Bereket Abera
# SPDX-License-Identifier: AGPL-3.0-only
#
# Regenerates apps/wayline/patches/<name>.patch from the patchwork, against the wayline-base tag,
# including new and deleted files. Run it again whenever those files change; it replaces the patch.
#
#   apps/wayline/scripts/save-patch.sh 20-shell "apps/web/core/components/workspace/content-wrapper.tsx" apps/web/app
#
# Paths are literal: a file or a directory, no globs, so Next-style names such as
# apps/web/app/(all)/[workspaceSlug] need only shell quoting.
#
# Safe while other authors run it on other paths: all index work happens in a private temporary index,
# so nothing touches the shared .git/index and no git lock is contended. Files are refused when they
# belong to another patch or to the overlay, which is what keeps patches independent.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

[[ $# -ge 2 ]] || die "usage: $0 <NN-area> <path...>"
name="${1%.patch}"; shift
valid_patch_name "$name" || die "bad patch name: $name, expected NN-area, for example 20-shell"
[[ -d "$PATCHWORK/.git" ]] || die "no patchwork yet, run apps/wayline/scripts/patchwork.sh"
wgit -C "$PATCHWORK" rev-parse -q --verify "refs/tags/$BASE_TAG" >/dev/null || die "patchwork has no $BASE_TAG tag"

export GIT_LITERAL_PATHSPECS=1
mkdir -p "$BUILD_DIR/tmp" "$PATCHES"
WORK="$(mktemp -d "$BUILD_DIR/tmp/save-patch.XXXXXX")"
trap 'rm -rf "${WORK:?}"' EXIT
export GIT_INDEX_FILE="$WORK/index"

wgit -C "$PATCHWORK" read-tree "$BASE_TAG"
# Puts new files in the private index only, so git diff can see them.
wgit -C "$PATCHWORK" add --intent-to-add -- "$@" 2>"$WORK/add.err" || {
  # A deleted file has nothing to add. Anything else is a real problem.
  grep -v "did not match any files" "$WORK/add.err" >&2 && die "git add failed" || true
}
wgit -C "$PATCHWORK" diff --binary --full-index --no-renames --no-color --no-ext-diff \
  --src-prefix=a/ --dst-prefix=b/ "$BASE_TAG" -- "$@" >"$WORK/out.patch"

target="$PATCHES/$name.patch"
if [[ ! -s "$WORK/out.patch" ]]; then
  rm -f "${target:?}"
  warn "no differences for those paths, $name.patch removed if it existed"
  exit 0
fi

wgit -C "$PATCHWORK" apply --numstat -z "$WORK/out.patch" | tr '\0' '\n' | cut -f3 | grep . | LC_ALL=C sort >"$WORK/files"

# One owner per file.
conflicts=0
while read -r other; do
  [[ -n "$other" && "$other" != "$target" ]] || continue
  while read -r f; do
    warn "$f already belongs to $(basename "$other")"
    conflicts=$((conflicts + 1))
  done < <(wgit -C "$PATCHWORK" apply --numstat -z "$other" | tr '\0' '\n' | cut -f3 | grep . | LC_ALL=C sort | comm -12 - "$WORK/files")
done < <(list_patches)
while read -r f; do
  if [[ -e "$OVERLAY/$f" ]]; then
    warn "$f is an overlay file: edit it in apps/wayline/overlay, do not patch it"
    conflicts=$((conflicts + 1))
  fi
done <"$WORK/files"
[[ $conflicts -eq 0 ]] || die "$conflicts files are owned elsewhere. Narrow the paths or talk to that patch's owner"

# It must apply to the baseline, or apply.sh will fail later for the same reason.
export GIT_INDEX_FILE="$WORK/check-index"
wgit -C "$PATCHWORK" read-tree "$BASE_TAG"
wgit -C "$PATCHWORK" apply --cached --check --whitespace=nowarn "$WORK/out.patch" \
  || die "the generated patch does not apply to $BASE_TAG"

mv "$WORK/out.patch" "$target"
ok "$(basename "$target"): $(wc -l <"$WORK/files" | tr -d ' ') files, $(wc -c <"$target" | tr -d ' ') bytes"
