#!/usr/bin/env bash
# Build the Wayline images and record their digests. Same script locally and in CI, only the
# prefix differs.
#
#   scripts/ci/build-images.sh localhost:5001/wayline
#   PUSH=no scripts/ci/build-images.sh ghcr.io/owner/wayline     build only, for pull requests
#
# Reads apps/wayline/images.txt, one image per line, paths relative to apps/wayline:
#   <name> <dockerfile> <context>
# With no images.txt there is nothing to build yet, which is not a failure.
#
# Writes .build/digests.tsv as: <name> TAB <repository> TAB <sha256 digest>. scripts/promote.sh
# reads it. Environment: PUSH (yes), TAG (short git commit), DIGESTS_FILE.
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

[[ $# -eq 1 ]] || die "usage: $0 <registry-prefix>, for example localhost:5001/wayline"
PREFIX="${1%/}"
PUSH="${PUSH:-yes}"
DIGESTS_FILE="${DIGESTS_FILE:-$ROOT/.build/digests.tsv}"
LIST="$ROOT/apps/wayline/images.txt"

cd "$ROOT"
mkdir -p "$(dirname "$DIGESTS_FILE")"
: >"$DIGESTS_FILE"

if [[ ! -f "$LIST" ]]; then
  warn "apps/wayline/images.txt does not exist yet, nothing to build"
  exit 0
fi

guard_disk
TAG="${TAG:-$(git rev-parse --short=12 HEAD 2>/dev/null || echo dev)}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

while read -r name dockerfile context _; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  [[ -n "$dockerfile" && -n "$context" ]] || die "images.txt: '$name' needs a dockerfile and a context"
  repository="$PREFIX/$name"
  metadata="$WORK/$name.json"

  # No provenance or SBOM manifests, so the digest names one plain manifest and survives a copy
  # between registries. Native arm64 only, no emulation.
  output=(--output type=cacheonly)
  [[ "$PUSH" != yes ]] || output=(--push)

  log "Building $repository:$TAG"
  docker buildx build --platform linux/arm64 --provenance=false --sbom=false \
    --metadata-file "$metadata" "${output[@]}" \
    -f "apps/wayline/$dockerfile" -t "$repository:$TAG" "apps/wayline/$context"

  if [[ "$PUSH" == yes ]]; then
    digest="$(yq -p json -r '."containerimage.digest" // ""' "$metadata")"
    [[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]] || die "no digest recorded for $repository"
    # Prove the registry serves that digest, independently of what the builder reported.
    docker buildx imagetools inspect "$repository@$digest" >/dev/null
    printf '%s\t%s\t%s\n' "$name" "$repository" "$digest" >>"$DIGESTS_FILE"
    ok "$repository@$digest"
  fi
done <"$LIST"

if [[ "$PUSH" == yes ]]; then
  ok "digests recorded in ${DIGESTS_FILE#"$ROOT"/}"
fi
