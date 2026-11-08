#!/usr/bin/env bash
# Copyright (c) 2026 Bereket Abera
# SPDX-License-Identifier: AGPL-3.0-only
#
# Shared by the Wayline scripts. Source it; do not execute it.
# shellcheck disable=SC2034  # these are read by the scripts that source this file
# shellcheck source=../../../scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/scripts/lib/common.sh"

WAYLINE="$ROOT/apps/wayline"
BUILD_DIR="$ROOT/.build"
UPSTREAM_CACHE="$BUILD_DIR/plane-upstream.git"
SRC="$BUILD_DIR/plane-src"
PATCHWORK="$BUILD_DIR/plane-patchwork"
DIST="$BUILD_DIR/wayline-dist"
OVERLAY="$WAYLINE/overlay"
PATCHES="$WAYLINE/patches"
LOCK_DIR="$BUILD_DIR/build.lockdir"
BASE_TAG="wayline-base"
OVERLAY_LOCK="$WAYLINE/overlay.lock"
# What an image's Corresponding Source is, beyond the pinned upstream commit: the build that made it.
# A change here means an image's /source link no longer names what built it. Work in other
# directories does not, so a dirty monitoring/ does not stop an image build.
SOURCE_PATHS=(apps/wayline LICENSE COPYRIGHT.txt NOTICE.md scripts/ci/build-images.sh scripts/lib/common.sh)

# shellcheck disable=SC1091
source "$WAYLINE/UPSTREAM"

mkdir -p "$BUILD_DIR"

# Git with the user's own configuration out of the way, so nobody's diff.noprefix or
# commit.gpgsign changes what these trees contain.
wgit() {
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git \
    -c user.name=wayline-build -c user.email=build@wayline.invalid -c commit.gpgsign=false \
    -c core.autocrlf=false -c advice.detachedHead=false "$@"
}

# require_tools <tool...>: say what is missing before any work starts, not halfway through.
require_tools() {
  local missing=() tool
  for tool in "$@"; do command -v "$tool" >/dev/null 2>&1 || missing+=("$tool"); done
  [[ ${#missing[@]} -eq 0 ]] || die "missing tools: ${missing[*]}. make setup installs yq and the other pinned CLIs; Node comes from nvm."
}

# write_source_stamp <file>: the commit this tree is at, and whether the build inputs differ from it.
write_source_stamp() {
  local commit dirty=yes
  commit="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
  [[ -n "$(git -C "$ROOT" status --porcelain -- "${SOURCE_PATHS[@]}" 2>/dev/null || echo unknown)" ]] || dirty=no
  printf 'commit=%s\ndirty=%s\n' "$commit" "$dirty" >"$1"
}

# Patches in the order they are applied. Numeric prefixes are zero-padded, so bytewise sort is numeric.
list_patches() {
  [[ -d "$PATCHES" ]] || return 0
  find "$PATCHES" -maxdepth 1 -type f -name '*.patch' | LC_ALL=C sort
}

valid_patch_name() { [[ "$1" =~ ^[0-9]{2,3}-[a-z0-9][a-z0-9-]*$ ]]; }

# Serialize anything that rewrites .build/plane-src. Re-entrant through WAYLINE_LOCK_HELD, so
# build.sh can call apply.sh. A lock whose owner has died is taken over rather than waited on.
acquire_build_lock() {
  [[ -z "${WAYLINE_LOCK_HELD:-}" ]] || return 0
  local waited=0 owner
  until mkdir "$LOCK_DIR" 2>/dev/null; do
    owner="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [[ -n "$owner" ]] && ! kill -0 "$owner" 2>/dev/null; then
      warn "removing a stale build lock left by pid $owner"
      rm -rf "${LOCK_DIR:?}"
      continue
    fi
    [[ $waited -lt 3600 ]] || die "still locked after an hour: $LOCK_DIR (pid ${owner:-unknown})"
    [[ $((waited % 60)) -ne 0 ]] || log "waiting for the build lock held by pid ${owner:-unknown}"
    sleep 5
    waited=$((waited + 5))
  done
  echo $$ >"$LOCK_DIR/pid"
  export WAYLINE_LOCK_HELD=$$
  # shellcheck disable=SC2064
  trap "rm -rf '${LOCK_DIR:?}'" EXIT
}
