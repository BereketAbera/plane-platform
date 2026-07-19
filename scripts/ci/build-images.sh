#!/usr/bin/env bash
# Copyright (c) 2026 Bereket Abera
# SPDX-License-Identifier: AGPL-3.0-only
#
# Build the Wayline images and record their digests. Same script locally and in CI, only the
# prefix differs.
#
#   scripts/ci/build-images.sh localhost:5001/wayline
#   PUSH=no scripts/ci/build-images.sh ghcr.io/owner/wayline     build only, for pull requests
#
# Builds the frontends natively first with apps/wayline/scripts/build.sh, because every Docker context
# is assembled by that script. SKIP_NATIVE_BUILD=yes reuses the contexts already in .build/wayline-dist.
#
# AGPL section 13: each image's /source link and revision label name the commit its context was built from,
# as recorded by build.sh in .build/wayline-dist/SOURCE.<name>, never just HEAD. With PUSH=yes this refuses a
# context built from uncommitted source, and one whose source has changed since. Commits that touch only
# other directories do not matter, so the checks compare the paths in SOURCE_PATHS (scripts/lib.sh).
#
# Reads apps/wayline/images.txt, one image per line, paths relative to apps/wayline:
#   <name> <dockerfile> <context>
# With no images.txt there is nothing to build yet, which is not a failure.
#
# Walks before it publishes. Each image goes first to a throwaway registry on loopback, which lives in memory for as long
# as this script does. checks/layer-check.py reads every layer there as a registry serves it, and stops if a layer holds
# what is on upstream's commercially licensed files. checks/flatten-config.py stops if the flattened backend dropped
# anything from its base's config. Only when every image has passed are they copied by digest to <registry-prefix>, and
# each is walked again as that registry serves it. So an image that fails either check reaches nobody. The second walk
# fails only if that registry cannot be read or serves something else, and the image then stays where it was copied, with
# no digest recorded. PUSH=no runs neither check, because it builds and stores nothing to read. The backend's build also
# stops on the identifier before any of this.
#
# Writes .build/digests.tsv as: <name> TAB <repository> TAB <sha256 digest>, only once every image has
# been published and checked, and never with PUSH=no, so a failed run leaves the last good file. scripts/promote.sh
# reads it. Environment: PUSH (yes), TAG (short git commit), DIGESTS_FILE, SKIP_NATIVE_BUILD (no),
# WAYLINE_SOURCE_REPO (where /source points, default the BereketAbera/plane-platform repository),
# WAYLINE_STAGING_PORT (the throwaway registry's port on loopback, 5059).
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=../../apps/wayline/scripts/lib.sh
source "$ROOT/apps/wayline/scripts/lib.sh"

[[ $# -eq 1 ]] || die "usage: $0 <registry-prefix>, for example localhost:5001/wayline"
PREFIX="${1%/}"
PUSH="${PUSH:-yes}"
DIGESTS_FILE="${DIGESTS_FILE:-$ROOT/.build/digests.tsv}"
LIST="$ROOT/apps/wayline/images.txt"

cd "$ROOT"
mkdir -p "$(dirname "$DIGESTS_FILE")"
require_tools git docker yq python3 curl

if [[ ! -f "$LIST" ]]; then
  warn "apps/wayline/images.txt does not exist yet, nothing to build"
  exit 0
fi

# D12 in apps/wayline/MODIFICATIONS.md decides where images may go. PUSH=no publishes nothing, so it needs no decision.
[[ "$PUSH" != yes ]] || apps/wayline/scripts/publish-gate.sh "$PREFIX" || die "not publishing to $PREFIX"

guard_disk
if [[ "${SKIP_NATIVE_BUILD:-no}" != yes ]]; then
  "$ROOT/apps/wayline/scripts/build.sh"
else
  warn "SKIP_NATIVE_BUILD=yes: reusing contexts in .build/wayline-dist, each stamped with the commit that built it"
fi
SOURCE_REPO="${WAYLINE_SOURCE_REPO:-https://github.com/BereketAbera/plane-platform}"
WORK="$(mktemp -d)"
# Digest from 'docker buildx imagetools inspect ghcr.io/distribution/distribution:3.1.2', 2026-11-05: the local registry's own.
STAGING_IMAGE="ghcr.io/distribution/distribution:3.1.2@sha256:d106962e6fe3fa69c178cec77eeeee5edb626b8df6535b7bd6b95e658a0a5ca9"
STAGING_CONTAINER="wayline-staging-$$"
# A fixed port, because the builder pushes from inside Docker's VM, and on Docker Desktop a port Docker picked is only the
# Mac's. In images.yml the builder shares the runner's network, for the same reason.
STAGING_PORT="${WAYLINE_STAGING_PORT:-5059}"
STAGING="localhost:$STAGING_PORT/wayline"
trap 'docker rm -f "$STAGING_CONTAINER" >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

start_staging() {
  local waited=0
  docker run -d --rm --name "$STAGING_CONTAINER" --tmpfs /var/lib/registry:size=2g \
    --publish "127.0.0.1:$STAGING_PORT:5000" "$STAGING_IMAGE" >/dev/null \
    || die "could not start the throwaway registry on port $STAGING_PORT. WAYLINE_STAGING_PORT chooses another"
  until [[ "$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://localhost:$STAGING_PORT/v2/")" == 200 ]]; do
    waited=$((waited + 1))
    [[ $waited -lt 30 ]] || die "the throwaway registry did not answer on port $STAGING_PORT"
    sleep 1
  done
}
[[ "$PUSH" != yes ]] || start_staging

# Prints the commit an image's context was built from, after refusing a context that is not its source.
source_commit_of() {
  local name="$1" stamp commit dirty complaint=""
  stamp="$DIST/SOURCE.$name"
  [[ -f "$stamp" ]] || die "no $stamp, so nothing says what built this context. Run apps/wayline/scripts/build.sh"
  commit="$(sed -n 's/^commit=//p' "$stamp")"
  dirty="$(sed -n 's/^dirty=//p' "$stamp")"
  if [[ "$dirty" != no ]]; then
    complaint="$name was built from uncommitted source"
  elif ! git cat-file -e "$commit^{commit}" 2>/dev/null; then
    complaint="$name was built from $commit, which this repository does not have"
  elif ! git diff --quiet "$commit" HEAD -- "${SOURCE_PATHS[@]}"; then
    complaint="the source of $name changed after it was built from $commit"
  elif [[ -n "$(git status --porcelain -- "${SOURCE_PATHS[@]}")" ]]; then
    complaint="the source of $name has uncommitted changes, so a rebuild would not match this context"
  fi
  if [[ -n "$complaint" ]]; then
    [[ "$PUSH" != yes ]] || die "$complaint. Commit, then rebuild without SKIP_NATIVE_BUILD"
    warn "$complaint. Tolerated with PUSH=no, which publishes nothing"
  fi
  printf '%s\n' "$commit"
}

while read -r name dockerfile context _; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  [[ -n "$dockerfile" && -n "$context" ]] || die "images.txt: '$name' needs a dockerfile and a context"
  [[ -d "apps/wayline/$context" ]] || die "no build context at apps/wayline/$context, run apps/wayline/scripts/build.sh"
  repository="$PREFIX/$name"
  metadata="$WORK/$name.json"
  source_ref="$(source_commit_of "$name")"
  image_tag="${TAG:-${source_ref:0:12}}"
  # CI builds what it just checked out from GitHub, so only a local push can name a commit GitHub lacks.
  if [[ "$PUSH" == yes && -z "${CI:-}" ]] && ! git merge-base --is-ancestor "$source_ref" origin/main 2>/dev/null; then
    warn "$source_ref is not on origin/main, so $name's /source link answers 404 until it is pushed"
  fi

  # No provenance or SBOM manifests, so the digest names one plain manifest and survives a copy
  # between registries. Native arm64 only, no emulation. store=false, so the throwaway name stays out of Docker's image list.
  output=(--output type=cacheonly)
  build_ref="$repository:$image_tag"
  if [[ "$PUSH" == yes ]]; then
    # shellcheck disable=SC2054  # the commas are the exporter's options
    output=(--output type=image,push=true,store=false)
    build_ref="$STAGING/$name:$image_tag"
  fi

  log "Building $repository:$image_tag from $source_ref"
  # SOURCE_DATE_EPOCH fixes the config's created time. A rebuild can still differ, in file times and OS packages,
  # so a digest, not a rebuild, is the identity of a release.
  # A context holds what a checkout and a build left, with their modes. Under a restrictive umask those are 0600, and
  # the image's non-root user then cannot read its own files: nginx and Django fail at start, and no build step notices.
  # The cold install found this, with umask 077.
  chmod -R a+rX "apps/wayline/$context"
  docker buildx build --platform linux/arm64 --provenance=false --sbom=false \
    --build-arg "SOURCE_DATE_EPOCH=$(git show -s --format=%ct "$source_ref" 2>/dev/null || date +%s)" \
    --metadata-file "$metadata" "${output[@]}" \
    --build-arg "WAYLINE_SOURCE_REPO=$SOURCE_REPO" --build-arg "WAYLINE_SOURCE_REF=$source_ref" \
    -f "apps/wayline/$dockerfile" -t "$build_ref" "apps/wayline/$context"

  if [[ "$PUSH" == yes ]]; then
    digest="$(yq -p json -r '."containerimage.digest" // ""' "$metadata")"
    [[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]] || die "no digest recorded for $name"
    # Prove the registry serves that digest, independently of what the builder reported.
    docker buildx imagetools inspect "$STAGING/$name@$digest" >/dev/null
    python3 -B apps/wayline/checks/layer-check.py "$STAGING/$name@$digest" \
      || die "$name@$digest failed the layer check, so nothing is published and no digest is recorded"
    if [[ "$name" == backend ]]; then
      python3 -B apps/wayline/checks/flatten-config.py "$STAGING/$name@$digest" \
        || die "$name@$digest dropped config from its base, so nothing is published and no digest is recorded. Restate it in runtime/Dockerfile.backend"
    fi
    printf '%s\t%s\t%s\t%s\n' "$name" "$repository" "$image_tag" "$digest" >>"$WORK/passed.tsv"
    ok "$name@$digest passed, not published yet"
  fi
done <"$LIST"

if [[ "$PUSH" == yes ]]; then
  [[ -s "$WORK/passed.tsv" ]] || die "no images in images.txt, so no digests"
  while IFS=$'\t' read -r name repository image_tag digest <&3; do
    # --prefer-index=false is what keeps the digest: the default wraps a single image in a new index.
    docker buildx imagetools create --prefer-index=false -t "$repository:$image_tag" "$STAGING/$name@$digest"
    docker buildx imagetools inspect "$repository@$digest" >/dev/null || die "$repository did not end up with $digest"
    python3 -B apps/wayline/checks/layer-check.py "$repository@$digest" \
      || die "$repository@$digest failed the layer check where it was published, so no digest is recorded. It is still in that registry"
    printf '%s\t%s\t%s\n' "$name" "$repository" "$digest" >>"$WORK/digests.tsv"
    ok "$repository@$digest"
  done 3<"$WORK/passed.tsv"
  mv "$WORK/digests.tsv" "$DIGESTS_FILE"
  ok "digests recorded in ${DIGESTS_FILE#"$ROOT"/}"
fi
