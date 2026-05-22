#!/usr/bin/env bash
# Copyright (c) 2026 Bereket Abera
# SPDX-License-Identifier: AGPL-3.0-only
#
# How much work is a future upstream? Dry-runs the overlay and every patch against another upstream ref and
# prints the size of it, so a rewrite is known early. Changes nothing outside a throwaway tree, and uses
# no node_modules. A ref that does not fit is an answer, not a failure, so this exits 0 unless it cannot run.
#
#   apps/wayline/checks/upstream-check.sh <ref>             for example v1.5.0, or preview
#   PLANE_SOURCE_MIRROR=<clone> apps/wayline/checks/upstream-check.sh <ref>
# shellcheck source=../scripts/lib.sh
source "$(dirname "$0")/../scripts/lib.sh"

ref="${1:?usage: upstream-check.sh <tag or branch>}"
source_repo="${PLANE_SOURCE_MIRROR:-$UPSTREAM_REPO}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wayline-upstream-check.XXXXXX")"
trap 'rm -rf "${WORK:?}"' EXIT
tree="$WORK/tree"
wgit init --quiet "$tree"
if ! wgit -C "$tree" fetch --quiet --depth 1 --no-tags "$source_repo" "refs/tags/$ref" 2>/dev/null; then
  wgit -C "$tree" fetch --quiet --depth 1 --no-tags "$source_repo" "refs/heads/$ref"
fi
wgit -C "$tree" checkout --quiet --detach FETCH_HEAD
printf 'upstream %s at %s, version %s\n' "$ref" "$(wgit -C "$tree" rev-parse HEAD)" "$(sed -n 's/^ *"version": "\(.*\)",*$/\1/p' "$tree/package.json" | head -1)"

# ---- overlay ---------------------------------------------------------------------------------------
gone=0; changed=0; total=0
while IFS=$'\t' read -r kind blob path; do
  [[ "$kind" == replace ]] || continue
  total=$((total + 1))
  now="$(wgit -C "$tree" rev-parse -q --verify "HEAD:$path" 2>/dev/null || true)"
  if [[ -z "$now" ]]; then gone=$((gone + 1)); [[ "${VERBOSE:-}" != yes ]] || printf '    gone    %s\n' "$path"
  elif [[ "$now" != "$blob" ]]; then changed=$((changed + 1)); [[ "${VERBOSE:-}" != yes ]] || printf '    changed %s\n' "$path"
  fi
done <"$OVERLAY_LOCK"
printf 'overlay: %s files replace upstream paths: %s gone upstream, %s changed upstream\n' "$total" "$gone" "$changed"

# ---- design system ---------------------------------------------------------------------------------
if [[ -f "$tree/packages/tailwind-config/variables.css" ]]; then
  if node "$WAYLINE/checks/token-diff.mjs" "$tree" >"$WORK/token-diff" 2>&1; then
    printf 'token-diff: clean\n'
  else
    printf 'token-diff: fails: %s\n' "$(tail -1 "$WORK/token-diff")"
  fi
else
  printf 'token-diff: packages/tailwind-config/variables.css is gone, so the design system has moved\n'
fi

# ---- patches, each against that tree plus the overlay ------------------------------------------------
rsync -a --exclude .DS_Store "$OVERLAY/" "$tree/"
wgit -C "$tree" add --all
wgit -C "$tree" -c core.safecrlf=false commit --quiet --allow-empty -m "overlay"
failed_patches=0; failed_files=0; patches=0
while read -r patch; do
  [[ -n "$patch" ]] || continue
  patches=$((patches + 1))
  name="$(basename "$patch" .patch)"
  # Each file separately, because git apply stops at the first failure and a count needs them all.
  bad=0; files=0
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    files=$((files + 1))
    # --include takes a glob, and Next-style names hold brackets.
    glob="$(printf '%s' "$f" | sed 's/[][*?\\]/\\&/g')"
    wgit -C "$tree" apply --check --include="$glob" --whitespace=nowarn "$patch" >/dev/null 2>&1 || { bad=$((bad + 1)); [[ "${VERBOSE:-}" != yes ]] || printf '    fails   %s\n' "$f"; }
  done < <(wgit -C "$tree" apply --numstat -z "$patch" | tr '\0' '\n' | cut -f3 | grep .)
  printf '  %-20s %3s files, %3s do not apply\n' "$name" "$files" "$bad"
  [[ "$bad" -eq 0 ]] || failed_patches=$((failed_patches + 1))
  failed_files=$((failed_files + bad))
done < <(list_patches)
printf 'patches: %s of %s fail, %s files need a rebase\n' "$failed_patches" "$patches" "$failed_files"
