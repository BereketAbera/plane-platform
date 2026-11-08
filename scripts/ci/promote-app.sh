#!/usr/bin/env bash
# Points one image of an app beside Wayline on hosted production at a new digest, in this checkout, for a person to review as a pull
# request. .github/workflows/promote-app.yml runs it and opens that pull request. Merging it is the approval.
#
#   scripts/ci/promote-app.sh <app> <component> <digest>      the app is rillmark, awushi-cloudgarden or frameflow
#   TAG=<12-character commit> scripts/ci/promote-app.sh ...   names that commit in the tag too. Without TAG the tag stays as it was
#
# The image is ghcr.io/bereketabera/<app>/<component>. gitops/clusters/plane-prod/platform/<app>/ must name it as one string, however
# many containers run it, and nothing else hosted Argo CD reads may name it. This writes the new tag and digest there and on the same
# line of policy/hosted-images.txt, so the manifest and the list move together, as validate-manifests.sh requires of every image.
#
# It does not look the digest up, because it holds no login that can read the app's private package. Nothing after it does either:
# publish-release.sh confirms Wayline's digests on GHCR and no others. A wrong digest shows only after the sync, as ImagePullBackOff
# beside the pod that keeps serving, so docs/hosted-apps.md, under Checking a digest, says how to look before merging.
#
# It commits nothing and reaches no cluster or registry. It leaves the change in the working tree and the commit message in
# .build/promote-app-message.txt. If the app runs this image already it changes nothing and writes no message.
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=../lib/commit-lock.sh
source "$(dirname "$0")/../lib/commit-lock.sh"
# shellcheck source=lib-manifests.sh
source "$(dirname "$0")/lib-manifests.sh"

[[ $# -eq 3 ]] || die "usage: $0 <rillmark|awushi-cloudgarden|frameflow|snakebrawl> <component> sha256:<64 hex>, with TAG=<12-character commit> to name that commit in the tag"
APP="$1"
COMPONENT="$2"
DIGEST="$3"
TAG="${TAG:-}"
case "$APP" in
  rillmark | awushi-cloudgarden | frameflow | snakebrawl) ;;
  *) die "the apps beside Wayline are rillmark, awushi-cloudgarden, frameflow and snakebrawl, and got '$APP'" ;;
esac
# Also what keeps each of these a piece of an image name and a path, and nothing else.
[[ "$COMPONENT" =~ ^[a-z]([a-z0-9-]{0,38}[a-z0-9])?$ ]] || die "a component is a lower-case name such as web or backend, and got '$COMPONENT'"
[[ "$DIGEST" =~ ^sha256:[a-f0-9]{64}$ ]] || die "a digest is sha256: and 64 lower-case hex characters, and got '$DIGEST'"
[[ "$DIGEST" != "sha256:$(printf '0%.0s' {1..64})" ]] || die "that is the placeholder digest, which no registry serves"
[[ -z "$TAG" || "$TAG" =~ ^[a-f0-9]{12}$ ]] || die "TAG is the first 12 characters of the commit the image was built from, as the app's images.yml tags it, and got '$TAG'"

REPOSITORY="ghcr.io/bereketabera/$APP/$COMPONENT"
if [[ "$APP" == snakebrawl ]]; then
  case "$COMPONENT" in web|arena) ;; *) die "snakebrawl components are web and arena" ;; esac
  REPOSITORY="docker.io/library/snake-production-$COMPONENT"
fi
APP_DIR="$HOSTED_TREE/platform/$APP"
MESSAGE="$ROOT/.build/promote-app-message.txt"
PATHS=("$APP_DIR" "$HOSTED_IMAGE_LIST")

for tool in git yq; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is not on PATH. Run: scripts/install-tools.sh yq"
done
cd "$ROOT"
git rev-parse -q --verify HEAD >/dev/null || die "this repository has no commits"
[[ -d "$APP_DIR" ]] || die "$APP_DIR does not exist, so $APP runs nothing on hosted production to promote"
[[ -f "$HOSTED_IMAGE_LIST" ]] || die "$HOSTED_IMAGE_LIST does not exist"
[[ -z "$(git status --porcelain -- "${PATHS[@]}")" ]] || die "uncommitted changes under ${PATHS[*]}, and this would fold them into a promotion"
rm -f "$MESSAGE"

WORK="$(mktemp -d)"
applied=no
cleanup() {
  local status=$?
  rm -rf "$WORK"
  # A refused promotion leaves nothing behind that a later commit could pick up.
  if [[ "$applied" == yes && "$status" -ne 0 ]]; then
    restore_from_head "${PATHS[@]}" || warn "${PATHS[*]} may still hold this promotion: git restore --source=HEAD --staged --worktree -- ${PATHS[*]}"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

FILES=()
while IFS= read -r -d '' file; do FILES+=("$file"); done < <(find "$APP_DIR" -type f -name '*.yaml' -print0)
[[ ${#FILES[@]} -gt 0 ]] || die "$APP_DIR holds no *.yaml, so $APP runs nothing on hosted production to promote"

of_this_repository() { # the lines on stdin that name $REPOSITORY, with a tag, a digest, both or neither
  local line
  while IFS= read -r line; do
    if [[ "$line" == "$REPOSITORY" || "$line" == "$REPOSITORY:"* || "$line" == "$REPOSITORY@"* ]]; then printf '%s\n' "$line"; fi
  done
}

# Read as validate-manifests.sh reads them, values at any depth and not comments, so a comment naming the image decides nothing.
named_before="$(images_named_in "${FILES[@]}")"
found="$(of_this_repository <<<"$named_before")"
count="$(grep -c . <<<"$found" || true)"
case "$count" in
  0)
    components="$(sed -n "s#^ghcr\.io/bereketabera/$APP/\([a-z0-9-]*\)[:@].*#\1#p" <<<"$named_before" | LC_ALL=C sort -u | tr '\n' ' ')"
    die "nothing in $APP_DIR runs $REPOSITORY. Its images from ghcr.io/bereketabera/$APP/ are: ${components:-none}"
    ;;
  1) OLD="$found" ;;
  *) die "$APP_DIR names $REPOSITORY $count ways, ${found//$'\n'/, }, and a promotion moves one image. Make them one first" ;;
esac

PINNED='^(:([A-Za-z0-9_][A-Za-z0-9_.-]{0,127}))?@(sha256:[a-f0-9]{64})$'
[[ "${OLD#"$REPOSITORY"}" =~ $PINNED ]] || die "$APP_DIR runs $OLD, which is not pinned by digest, as every image here is. Pin it first"
old_tag="${BASH_REMATCH[2]}"

# Anything else Argo CD reads that named it would keep the old digest after this, and the list would no longer hold that. Read as text,
# comments too, because the bootstrap chart's templates are not YAML a parser can read.
elsewhere=""
while IFS= read -r -d '' file; do
  status=0
  grep -qF -e "$REPOSITORY:" -e "$REPOSITORY@" -- "$file" || status=$?
  case "$status" in
    0) elsewhere="$elsewhere $file" ;;
    1) ;;
    *) die "could not read $file" ;;
  esac
done < <(find "$HOSTED_TREE" "$HOSTED_ENVIRONMENT" -type f -name '*.yaml' ! -path "$APP_DIR/*" -print0)
[[ -z "$elsewhere" ]] || die "$REPOSITORY is named outside $APP_DIR too, in$elsewhere, and this edits that folder alone, as the pull request adds it alone"

listed="$(grep -cxF -- "$OLD" "$HOSTED_IMAGE_LIST" || true)"
[[ "$listed" == 1 ]] || die "$HOSTED_IMAGE_LIST lists $OLD $listed times, and should once, so the manifest and the list disagree already. validate-manifests.sh says so too. Fix that first"

new_tag="${TAG:-$old_tag}"
[[ "$new_tag" != PLACEHOLDER ]] || die "$APP_DIR still runs the placeholder, so give the tag too: TAG=<the first 12 characters of the commit the image was built from>"
NEW="$REPOSITORY@$DIGEST"
if [[ -n "$new_tag" ]]; then NEW="$REPOSITORY:$new_tag@$DIGEST"; fi
if [[ "$NEW" == "$OLD" ]]; then
  ok "$APP runs $NEW already, so there is nothing to promote"
  exit 0
fi

applied=yes
# Every occurrence as plain text, comments too, and nothing else in the file. The replacement stays unquoted, because bash 3.2 would
# keep the quotes in it. NEW is made of the checked pieces above alone, so it holds no & or \ that bash 5.2 would read as special.
for file in "${FILES[@]}"; do
  content="$(cat -- "$file"; printf x)"
  content="${content%x}"
  if [[ "$content" == *"$OLD"* ]]; then printf '%s' "${content//"$OLD"/$NEW}" >"$file"; fi
done
# The one line, where it stands, so the list keeps its order. A line someone added by hand already is not doubled.
if grep -qxF -- "$NEW" "$HOSTED_IMAGE_LIST"; then
  awk -v old="$OLD" '$0 != old' "$HOSTED_IMAGE_LIST" >"$WORK/list"
else
  awk -v old="$OLD" -v new="$NEW" '$0 == old { print new; next } { print }' "$HOSTED_IMAGE_LIST" >"$WORK/list"
fi
cat "$WORK/list" >"$HOSTED_IMAGE_LIST"

# What it now runs is the same as before but for this one image, so the text edit reached nothing else.
named_after="$(images_named_in "${FILES[@]}")"
expected="$({ grep -vxF -- "$OLD" <<<"$named_before" || true; printf '%s\n' "$NEW"; } | LC_ALL=C sort -u)"
[[ "$named_after" == "$expected" ]] || die "after the edit $APP_DIR names more than $NEW in place of $OLD, so nothing was promoted"
[[ "$(grep -cxF -- "$NEW" "$HOSTED_IMAGE_LIST" || true)" == 1 && "$(grep -cxF -- "$OLD" "$HOSTED_IMAGE_LIST" || true)" == 0 ]] ||
  die "after the edit $HOSTED_IMAGE_LIST does not hold $NEW once in place of $OLD, so nothing was promoted"

# The tag says which commit only when TAG gave it. A kept one may name the build before this, so the subject names the digest then.
subject="promote($APP): $COMPONENT ${TAG:-${DIGEST:0:19}}"
trailers="Promote-App: $APP"$'\n'"Promote-Image: $COMPONENT=$NEW"$'\n'"Promote-Replaces: $OLD"
mkdir -p "$(dirname "$MESSAGE")"
printf '%s\n\n%s\n' "$subject" "$trailers" >"$MESSAGE"

applied=no
log "$APP $COMPONENT: $OLD -> $NEW"
git --no-pager diff --stat -- "${PATHS[@]}"
git --no-pager diff --no-color --unified=0 -- "${PATHS[@]}"
if [[ -z "$TAG" && -n "$old_tag" ]]; then warn "the tag stays $old_tag, which may name the commit of the image before. TAG=<12-character commit> names this one"; fi
ok "$APP_DIR and $HOSTED_IMAGE_LIST name $NEW, not committed. Commit message in ${MESSAGE#"$ROOT"/}"
