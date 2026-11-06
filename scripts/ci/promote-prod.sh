#!/usr/bin/env bash
# Moves hosted production to an evidenced digest set, in this checkout, for a person to review as a pull request.
# .github/workflows/promote-plane-prod.yml runs it and opens that pull request. Merging it is the approval.
#
#   scripts/ci/promote-prod.sh <set-hash>     from docs/evidence/promotions/<set-hash>.json, as HEAD holds it
#
# It writes the digests and GHCR names the evidence gives into helm/plane/overlays/prod, renders, and on the first
# promotion copies gitops/clusters/plane-prod/plane-prod-application.yaml.tmpl to applications/plane-prod.yaml. Then it
# runs scripts/ci/check-prod-evidence.sh against a commit made of the result, and undoes everything if that refuses.
#
# It commits nothing to a branch and reaches no cluster. It leaves the change in the working tree and the commit message
# in .build/promote-prod-message.txt. If plane-prod holds this set already it changes nothing and writes no message.
# A rollback is this with an older set's hash, or a revert on main: the older evidence is still there either way.
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=../lib/commit-lock.sh
source "$(dirname "$0")/../lib/commit-lock.sh"

[[ $# -eq 1 ]] || die "usage: $0 <set-hash>, the name of a file in docs/evidence/promotions without .json"
# Also what keeps this a file name and nothing else.
[[ "$1" =~ ^[a-f0-9]{64}$ ]] || die "a set hash is 64 lower-case hex characters, and got '$1'"
SET_HASH="$1"
EVIDENCE="docs/evidence/promotions/$SET_HASH.json"
OVERLAY=helm/plane/overlays/prod
KUSTOMIZATION="$OVERLAY/kustomization.yaml"
RENDERED=gitops/environments/prod/manifests.yaml
APPLICATION=gitops/clusters/plane-prod/applications/plane-prod.yaml
TEMPLATE=gitops/clusters/plane-prod/plane-prod-application.yaml.tmpl
MESSAGE="$ROOT/.build/promote-prod-message.txt"
PATHS=("$KUSTOMIZATION" "$RENDERED" "$APPLICATION")

for tool in git jq kustomize yq; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is not on PATH. Run: scripts/install-tools.sh helm kustomize yq"
done
cd "$ROOT"
git rev-parse -q --verify HEAD >/dev/null || die "this repository has no commits"
[[ -f "$KUSTOMIZATION" ]] || die "$KUSTOMIZATION does not exist"
[[ -z "$(git status --porcelain -- "${PATHS[@]}")" ]] || die "uncommitted changes under ${PATHS[*]}, and this would fold them into a promotion"
git cat-file -e "HEAD:$EVIDENCE" 2>/dev/null || die "HEAD has no $EVIDENCE. make record-dev-evidence writes it, and it has to be merged to main first"
rm -f "$MESSAGE"

WORK="$(mktemp -d)"
applied=no
cleanup() {
  local status=$?
  if [[ -d "$WORK/candidate" ]]; then
    git worktree remove --force "$WORK/candidate" >/dev/null 2>&1 || true
    git worktree prune >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
  # A refused promotion leaves nothing behind that a later commit could pick up.
  if [[ "$applied" == yes && "$status" -ne 0 ]]; then
    restore_from_head "${PATHS[@]}" || warn "${PATHS[*]} may still hold this promotion: git restore --source=HEAD --staged --worktree -- ${PATHS[*]}"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# From the commit, like the check: a file edited in this checkout must not decide what the overlay gets. check-prod-evidence.sh
# verifies the signature below, so these fields only have to be safe to hand to kustomize.
git cat-file blob "HEAD:$EVIDENCE" >"$WORK/evidence.json"
jq -r '.images[] | [.chart_image, .production_repository, (.tag // "-"), .digest] | @tsv' "$WORK/evidence.json" >"$WORK/images.tsv" ||
  die "$EVIDENCE has no readable list of images"
[[ -s "$WORK/images.tsv" ]] || die "$EVIDENCE names no images"
yq -r '.images[] | [.name, (.newName // .name), (.newTag // "-"), .digest] | @tsv' "$KUSTOMIZATION" >"$WORK/overlay.tsv"

applied=yes
trailers="Promote-Env: plane-prod"$'\n'"Promote-Set: $SET_HASH"$'\n'"Promote-Evidence: $EVIDENCE"
while IFS=$'\t' read -r name repository tag digest; do
  [[ "$name" =~ ^[a-z0-9][a-z0-9._/-]*$ && "$repository" =~ ^[a-z0-9][a-z0-9._/-]*$ ]] || die "$EVIDENCE names an image this cannot use: '$name' from '$repository'"
  [[ "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ || "$tag" == - ]] || die "$EVIDENCE gives $name the tag '$tag', which no reference can hold"
  [[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]] || die "$EVIDENCE gives $name the digest '$digest'"
  reference="$repository@$digest"
  if [[ "$tag" != - ]]; then reference="$repository:$tag@$digest"; fi
  # Only what moves, because any edit rewrites the file, and a set already here must leave no change to open.
  if ! grep -qxF "$name"$'\t'"$repository"$'\t'"$tag"$'\t'"$digest" "$WORK/overlay.tsv"; then
    (cd "$OVERLAY" && kustomize edit set image "$name=$reference") || die "kustomize could not set $name in $KUSTOMIZATION"
  fi
  trailers+=$'\n'"Promote-Image: ${repository##*/}=$reference"
done <"$WORK/images.tsv"

first_promotion=no
if [[ ! -e "$APPLICATION" ]]; then
  [[ -f "$TEMPLATE" ]] || die "neither $APPLICATION nor $TEMPLATE exists, so nothing would deploy this"
  first_promotion=yes
  cp "$TEMPLATE" "$APPLICATION"
fi

"$ROOT/scripts/render.sh" --env prod || die "rendering failed, so nothing was promoted"

if [[ -z "$(git status --porcelain -- "${PATHS[@]}")" ]]; then
  applied=no
  ok "plane-prod already holds set ${SET_HASH:0:12}, so there is nothing to promote"
  exit 0
fi

# The check reads a commit and not a working tree, so it gets one. This commit is on no branch and goes nowhere, and the
# index here is a throwaway, so the checkout's own stays as it was.
log "Checking what this would merge"
export GIT_AUTHOR_NAME=promote-prod GIT_AUTHOR_EMAIL=promote-prod@invalid GIT_COMMITTER_NAME=promote-prod GIT_COMMITTER_EMAIL=promote-prod@invalid
GIT_INDEX_FILE="$WORK/index" git read-tree HEAD
GIT_INDEX_FILE="$WORK/index" git add -- "${PATHS[@]}"
candidate="$(git commit-tree "$(GIT_INDEX_FILE="$WORK/index" git write-tree)" -p HEAD -m "candidate promotion of $SET_HASH")"
git worktree add --quiet --detach "$WORK/candidate" "$candidate"
check_status=0
(cd "$WORK/candidate" && ./scripts/ci/check-prod-evidence.sh) >"$WORK/check-output" || check_status=$?
[[ "$check_status" -eq 0 ]] || die "check-prod-evidence.sh answered $check_status for this promotion, so nothing is left to merge"
[[ "$(cat "$WORK/check-output")" == "set_hash=$SET_HASH" ]] ||
  die "asked for set $SET_HASH, and the render is covered by $(cat "$WORK/check-output"). The overlay holds images this evidence does not name"

subject="promote(plane-prod): set ${SET_HASH:0:12}"
if [[ "$first_promotion" == yes ]]; then subject="promote(plane-prod): first promotion, set ${SET_HASH:0:12}"; fi
mkdir -p "$(dirname "$MESSAGE")"
printf '%s\n\n%s\n' "$subject" "$trailers" >"$MESSAGE"

applied=no
ok "plane-prod overlay and render hold set ${SET_HASH:0:12}, not committed. Commit message in ${MESSAGE#"$ROOT"/}"
