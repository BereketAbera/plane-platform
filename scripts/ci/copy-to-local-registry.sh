#!/usr/bin/env bash
# Argo CD pulls Wayline images from localhost:5001, but GitHub Actions can only push to GHCR. After
# merging a digest-bump pull request, copy those exact digests into the local registry.
# Copying keeps the digest, and rebuilding would not.
#
#   docker login ghcr.io      (the packages are private)
#   scripts/ci/copy-to-local-registry.sh ghcr.io/owner/wayline dev
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

[[ $# -eq 2 ]] || die "usage: $0 <source-prefix> <dev|prod-sim>"
SOURCE="${1%/}"
FILE="$ROOT/helm/plane/overlays/$2/kustomization.yaml"
[[ -f "$FILE" ]] || die "$FILE does not exist"

copied=0
while read -r repository digest; do
  [[ "$repository" == localhost:5001/* ]] || continue
  name="${repository##*/}"
  docker buildx imagetools create -t "$repository:${digest:7:12}" "$SOURCE/$name@$digest"
  # Trust the registry's answer, not the copy command's exit status.
  docker buildx imagetools inspect "$repository@$digest" >/dev/null || die "$repository did not end up with $digest"
  ok "$repository@$digest"
  copied=$((copied + 1))
done < <(yq -r '.images[] | [(.newName // .name), .digest] | join(" ")' "$FILE")
ok "$copied image(s) present in the local registry"
