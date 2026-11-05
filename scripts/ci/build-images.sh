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
# After pushing each image it walks every layer as the registry serves it, and stops if a layer holds the identifier on
# upstream's commercially licensed files. It also stops if the flattened backend dropped anything from its base's config.
# Those two read what was pushed, so PUSH=no runs neither, and a failure leaves that image in the registry it was just
# pushed to, with no digest recorded for it. The backend's build also stops on that identifier before any push.
#
# Writes .build/digests.tsv as: <name> TAB <repository> TAB <sha256 digest>, only once every image has
# been pushed and checked, and never with PUSH=no, so a failed run leaves the last good file. scripts/promote.sh
# reads it. Environment: PUSH (yes), TAG (short git commit), DIGESTS_FILE, SKIP_NATIVE_BUILD (no),
# WAYLINE_SOURCE_REPO (where /source points, default the BereketAbera/plane-platform repository).
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
require_tools git docker yq python3

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
trap 'rm -rf "$WORK"' EXIT

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
  # between registries. Native arm64 only, no emulation.
  output=(--output type=cacheonly)
  [[ "$PUSH" != yes ]] || output=(--push)

  log "Building $repository:$image_tag from $source_ref"
  # SOURCE_DATE_EPOCH fixes the config's created time. A rebuild can still differ, in file times and OS packages,
  # so a digest, not a rebuild, is the identity of a release.
  docker buildx build --platform linux/arm64 --provenance=false --sbom=false \
    --build-arg "SOURCE_DATE_EPOCH=$(git show -s --format=%ct "$source_ref" 2>/dev/null || date +%s)" \
    --metadata-file "$metadata" "${output[@]}" \
    --build-arg "WAYLINE_SOURCE_REPO=$SOURCE_REPO" --build-arg "WAYLINE_SOURCE_REF=$source_ref" \
    -f "apps/wayline/$dockerfile" -t "$repository:$image_tag" "apps/wayline/$context"

  if [[ "$PUSH" == yes ]]; then
    digest="$(yq -p json -r '."containerimage.digest" // ""' "$metadata")"
    [[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]] || die "no digest recorded for $repository"
    # Prove the registry serves that digest, independently of what the builder reported.
    docker buildx imagetools inspect "$repository@$digest" >/dev/null
    python3 -B apps/wayline/checks/layer-check.py "$repository@$digest" \
      || die "$repository@$digest failed the layer check, so no digest is recorded. It is already in that registry"
    if [[ "$name" == backend ]]; then
      python3 -B apps/wayline/checks/flatten-config.py "$repository@$digest" \
        || die "$repository@$digest dropped config from its base, so no digest is recorded. Restate it in runtime/Dockerfile.backend"
    fi
    printf '%s\t%s\t%s\n' "$name" "$repository" "$digest" >>"$WORK/digests.tsv"
    ok "$repository@$digest"
  fi
done <"$LIST"

if [[ "$PUSH" == yes ]]; then
  [[ -s "$WORK/digests.tsv" ]] || die "no images in images.txt, so no digests"
  mv "$WORK/digests.tsv" "$DIGESTS_FILE"
  ok "digests recorded in ${DIGESTS_FILE#"$ROOT"/}"
fi
