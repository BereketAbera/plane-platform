#!/usr/bin/env bash
# Copyright (c) 2026 Bereket Abera
# SPDX-License-Identifier: AGPL-3.0-only
#
# Pinned checkout of upstream into .build/plane-src, verifying the commit in UPSTREAM.
#
# Objects are fetched once into a bare cache, .build/plane-upstream.git, so the build tree and the
# authoring tree do not depend on each other. The source is GitHub. Set PLANE_SOURCE_MIRROR to a local
# clone to avoid the network; the commit check is the same either way.
#
#   apps/wayline/scripts/fetch.sh               refresh the cache, then reset .build/plane-src
#   apps/wayline/scripts/fetch.sh --cache-only  refresh the cache only
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

SOURCE="${PLANE_SOURCE_MIRROR:-$UPSTREAM_REPO}"

ensure_cache() {
  if wgit -C "$UPSTREAM_CACHE" cat-file -e "$UPSTREAM_COMMIT^{commit}" 2>/dev/null; then
    # Always, not just on a fetch: rolling UPSTREAM back to a commit already cached must move the ref too.
    wgit -C "$UPSTREAM_CACHE" update-ref "refs/wayline/pinned" "$UPSTREAM_COMMIT"
    return 0
  fi
  log "Fetching $UPSTREAM_TAG ($UPSTREAM_COMMIT) from $SOURCE"
  [[ -d "$UPSTREAM_CACHE" ]] || wgit init --quiet --bare "$UPSTREAM_CACHE"
  wgit -C "$UPSTREAM_CACHE" fetch --quiet --depth 1 --no-tags "$SOURCE" "refs/tags/$UPSTREAM_TAG"
  local got
  got="$(wgit -C "$UPSTREAM_CACHE" rev-parse 'FETCH_HEAD^{commit}')"
  [[ "$got" == "$UPSTREAM_COMMIT" ]] || die "tag $UPSTREAM_TAG at $SOURCE is $got, expected $UPSTREAM_COMMIT"
  wgit -C "$UPSTREAM_CACHE" update-ref "refs/wayline/pinned" "$UPSTREAM_COMMIT"
}

ensure_cache
[[ "${1:-}" != "--cache-only" ]] || exit 0

acquire_build_lock

[[ -d "$SRC/.git" ]] || {
  wgit init --quiet "$SRC"
  wgit -C "$SRC" remote add origin "$UPSTREAM_CACHE"
}
wgit -C "$SRC" cat-file -e "$UPSTREAM_COMMIT^{commit}" 2>/dev/null \
  || wgit -C "$SRC" fetch --quiet --depth 1 --no-tags origin refs/wayline/pinned
# Fresh tree. node_modules survives because the lockfile is frozen and a reinstall costs a minute;
# everything else, including earlier build output, goes.
wgit -C "$SRC" checkout --quiet --force --detach "$UPSTREAM_COMMIT"
wgit -C "$SRC" clean -ffdxq -e node_modules

head="$(wgit -C "$SRC" rev-parse HEAD)"
[[ "$head" == "$UPSTREAM_COMMIT" ]] || die "checkout is at $head, expected $UPSTREAM_COMMIT"
ok "$SRC at $UPSTREAM_TAG ($head)"
