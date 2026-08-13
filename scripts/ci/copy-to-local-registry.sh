#!/usr/bin/env bash
# Argo CD pulls Wayline images from localhost:5001, but GitHub Actions can only push to GHCR. After
# merging a digest-bump pull request, copy those exact digests into the local registry.
# Copying keeps the digest, and rebuilding would not. Nothing here runs or reads what it copies, so this arm64 Mac copies a
# plain linux/amd64 manifest as it stands, and dev then runs those bytes under Rosetta.
#
#   scripts/ci/copy-to-local-registry.sh ghcr.io/owner/wayline dev
#
# The packages are private. If Docker cannot read the first image and the source is GHCR, this logs Docker in to ghcr.io with
# gh's token, through a pipe, so the token is in no argument, no variable and no output. That token needs read:packages, which
# `gh auth login` does not ask for: gh auth refresh -h github.com -s read:packages.
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

[[ $# -eq 2 ]] || die "usage: $0 <source-prefix> <dev|prod-sim>"
# An image reference takes only lower case, and GitHub keeps the owner's own spelling, such as BereketAbera.
SOURCE="$(tr '[:upper:]' '[:lower:]' <<<"${1%/}")"
FILE="$ROOT/helm/plane/overlays/$2/kustomization.yaml"
[[ -f "$FILE" ]] || die "$FILE does not exist"

# The read decides, not whether a login exists: a login can succeed with a token that cannot read these packages.
can_read() { docker buildx imagetools inspect "$1" >/dev/null 2>&1; }

# ensure_readable <image>: leaves Docker able to read it, logging in only if it cannot, or stops before anything is copied.
ensure_readable() {
  local image="$1" user
  can_read "$image" && return 0
  [[ "$SOURCE" == ghcr.io/* ]] || die "Docker cannot read $image. Log in to that registry, then run this again"
  command -v gh >/dev/null 2>&1 || die "Docker cannot read $image, and there is no gh to log in with. Run docker login ghcr.io with a token holding read:packages, then run this again"
  user="$(gh api user --jq .login)" || die "Docker cannot read $image, and gh has no working login. Run gh auth login, then run this again"
  log "Docker cannot read $image, so logging in to ghcr.io as $user with gh's token"
  gh auth token | docker login ghcr.io --username "$user" --password-stdin >/dev/null || die "docker login ghcr.io as $user failed"
  if ! can_read "$image"; then
    docker buildx imagetools inspect "$image" 2>&1 >/dev/null | tail -1 >&2 || true
    die "Logged in to ghcr.io as $user, and Docker still cannot read $image, so nothing was copied. If that package exists, gh's token lacks read:packages: gh auth refresh -h github.com -s read:packages, then run this again"
  fi
}

copied=0
# On its own descriptor, so nothing in the loop can read the list from stdin.
while read -r repository digest <&3; do
  [[ "$repository" == localhost:5001/* ]] || continue
  name="${repository##*/}"
  [[ "$copied" -gt 0 ]] || ensure_readable "$SOURCE/$name@$digest"
  # --prefer-index=false, as in build-images.sh. The default wraps a single image in a new index, and the tag named after
  # this digest would then answer with the index's digest instead.
  docker buildx imagetools create --prefer-index=false -t "$repository:${digest:7:12}" "$SOURCE/$name@$digest"
  # Trust the registry's answer, not the copy command's exit status.
  docker buildx imagetools inspect "$repository@$digest" >/dev/null || die "$repository did not end up with $digest"
  ok "$repository@$digest"
  copied=$((copied + 1))
done 3< <(yq -r '.images[] | [(.newName // .name), .digest] | join(" ")' "$FILE")
[[ "$copied" -gt 0 ]] || die "$FILE names no image in the local registry, so nothing was copied"
ok "$copied image(s) present in the local registry"
