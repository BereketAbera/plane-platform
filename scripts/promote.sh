#!/usr/bin/env bash
# Move image digests into an environment. The only writer of the images: lines in
# helm/plane/overlays/<env>/kustomization.yaml, per the contract.
#
#   scripts/promote.sh dev IMAGE=web DIGEST=sha256:... [REPO=localhost:5001/wayline/web]
#   scripts/promote.sh dev                 takes every digest from .build/digests.tsv
#   scripts/promote.sh prod-sim            copies every differing image from the dev overlay
#   scripts/promote.sh prod-sim IMAGE=web DIGEST=sha256:...
#
# IMAGE is web, admin, space, live, backend, postgres, valkey, rabbitmq or silo, or a full
# images[].name. ENV=<env> and environment variables work too, which is how make passes them.
#
# prod-sim refuses a digest dev never recorded for that image, takes a backup unless SKIP_BACKUP=yes,
# and asks first unless CONFIRM=yes. It also refuses unless plane-dev is Synced and Healthy with that
# digest in a ready container. OVERRIDE_DEV_CHECK="<reason>" goes ahead anyway, and the reason goes in
# .local/evidence-raw/promotion-overrides.log and in the commit message. With no cluster in reach, as
# in CI, that check is skipped, and both this output and the commit message say so.
#
# COMMIT=no leaves the change uncommitted and unpublished, for CI, which turns it into a pull
# request. SKIP_REGISTRY_CHECK=yes skips the local registry lookup, for CI and failure drills.
# DIGESTS_FILE overrides .build/digests.tsv.
#
# With a commit it publishes, and a publish that fails or is refused leaves the commit on main, where
# it goes out with the next publish of any kind. Run this again to publish it: the plan is empty then,
# and this still publishes, because the overlay holding a digest does not mean Argo CD has read it. It
# takes the commit lock in lib/commit-lock.sh from before its first edit until the commit.
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
# shellcheck source=lib/dev-check.sh
source "$(dirname "$0")/lib/dev-check.sh"
# shellcheck source=lib/commit-lock.sh
source "$(dirname "$0")/lib/commit-lock.sh"

usage() { die "usage: $0 dev|prod-sim [IMAGE=name DIGEST=sha256:... [REPO=repository]] [CONFIRM=yes] [SKIP_BACKUP=yes] [COMMIT=no] [OVERRIDE_DEV_CHECK=reason]"; }

for arg in "$@"; do
  case "$arg" in
    dev | prod-sim) ENV="$arg" ;;
    ENV=* | IMAGE=* | DIGEST=* | REPO=* | CONFIRM=* | SKIP_BACKUP=* | COMMIT=* | SKIP_REGISTRY_CHECK=* | DIGESTS_FILE=* | OVERRIDE_DEV_CHECK=*) export "${arg?}" ;;
    *) usage ;;
  esac
done

ENV="${ENV:-}"
IMAGE="${IMAGE:-}"
DIGEST="${DIGEST:-}"
REPO="${REPO:-}"
COMMIT="${COMMIT:-yes}"
DIGESTS_FILE="${DIGESTS_FILE:-$ROOT/.build/digests.tsv}"

[[ "$ENV" == dev || "$ENV" == prod-sim ]] || usage
[[ -n "$IMAGE" && -n "$DIGEST" || -z "$IMAGE" && -z "$DIGEST" ]] || die "IMAGE and DIGEST go together"
[[ -z "$DIGEST" || "$DIGEST" =~ ^sha256:[a-f0-9]{64}$ ]] || die "DIGEST must be sha256: and 64 hex characters"
[[ -z "$REPO" || "$REPO" =~ ^[a-zA-Z0-9][a-zA-Z0-9._:/-]*$ ]] || die "REPO is not a repository name"

guard_disk 1
cd "$ROOT"

OVERLAY="helm/plane/overlays/$ENV"
KUSTOMIZATION="$OVERLAY/kustomization.yaml"
DEV_KUSTOMIZATION=helm/plane/overlays/dev/kustomization.yaml
RENDERED="gitops/environments/$ENV/manifests.yaml"
[[ -f "$KUSTOMIZATION" ]] || die "$KUSTOMIZATION does not exist"

git rev-parse -q --verify HEAD >/dev/null || die "the repository has no commits, so promotion has no history to record in"
[[ -z "$(git status --porcelain -- "$OVERLAY" "$RENDERED")" ]] || die "$OVERLAY or $RENDERED has uncommitted changes"
if [[ "$COMMIT" == yes ]]; then
  # gitops-publish pushes main, so a promotion committed anywhere else would never reach Argo CD.
  [[ "$(git symbolic-ref --quiet --short HEAD || true)" == main ]] || die "promote from main, or use COMMIT=no"
  # A commit here would finish that revert, whatever state it is in.
  [[ ! -e "$(git rev-parse --git-path REVERT_HEAD)" ]] || die "a revert is under way in this checkout, so this changed nothing. Finish it or clear it first: git status shows what it left."
fi

WORK="$(mktemp -d)"
applied=no
cleanup() {
  local status=$?
  rm -rf "$WORK"
  # Never leave a half-promoted overlay behind. The paths were clean when the commit lock was taken.
  if [[ "$applied" == yes && "$status" -ne 0 ]]; then
    restore_from_head "$OVERLAY" "$RENDERED" ||
      warn "$OVERLAY and $RENDERED still hold this promotion, uncommitted, because git could not write the index. Once it can: git restore --source=HEAD --staged --worktree -- $OVERLAY $RENDERED. Then run this again."
  fi
  release_commit_lock
}
trap cleanup EXIT
# bash does not run an EXIT trap on a signal it has no trap for, and this may hold the commit lock.
trap 'exit 130' INT
trap 'exit 143' TERM

# name repo tag digest, one image per line. "-" stands for no tag, so `read` cannot shift columns.
entries() { yq -r '.images[] | [.name, (.newName // .name), (.newTag // "-"), .digest] | join(" ")' "$1"; }

# The chart's image names are fixed. The contract's short names map onto them.
chart_name() {
  case "$1" in
    web) echo plane-frontend ;;
    admin | space | live | backend) echo "plane-$1" ;;
    *) echo "$1" ;;
  esac
}

# Print the one overlay entry for an image, by full name or by last path segment.
entry_for() {
  local file="$1" want matches
  want="$(chart_name "$2")"
  matches="$(entries "$file" | awk -v want="$want" '{ n = split($1, part, "/"); if ($1 == want || part[n] == want) print }')"
  [[ -n "$matches" ]] || die "no image matching '$2' in $file"
  [[ "$(wc -l <<<"$matches")" -eq 1 ]] || die "'$2' matches more than one image in $file"
  echo "$matches"
}

PLAN="$WORK/plan"
: >"$PLAN"

# add_to_plan <name> <repo> <tag> <digest>, dropping anything the overlay already has.
add_to_plan() {
  local name="$1" repo="$2" tag="$3" digest="$4" current_repo current_tag current_digest
  read -r _ current_repo current_tag current_digest < <(entry_for "$KUSTOMIZATION" "$name")
  if [[ "$current_repo" == "$repo" && "$current_digest" == "$digest" ]]; then
    return 0
  fi
  # A tag beside a digest only documents the version. It cannot describe a different repository.
  if [[ "$tag" == keep ]]; then
    if [[ "$current_repo" == "$repo" ]]; then tag="$current_tag"; else tag=-; fi
  fi
  printf '%s %s %s %s\n' "$name" "$repo" "$tag" "$digest" >>"$PLAN"
}

if [[ -n "$IMAGE" ]]; then
  read -r name current_repo _ _ < <(entry_for "$KUSTOMIZATION" "$IMAGE")
  if [[ -n "$REPO" ]]; then
    add_to_plan "$name" "$REPO" keep "$DIGEST"
  elif [[ "$ENV" == prod-sim ]]; then
    # The repository travels with the digest: dev may already serve this image from another one.
    read -r _ dev_repo _ dev_digest < <(entry_for "$DEV_KUSTOMIZATION" "$IMAGE")
    if [[ "$dev_digest" != "$DIGEST" ]]; then
      warn "$DIGEST is not what dev runs now ($dev_digest). Pass REPO= if it came from another repository."
      dev_repo="$current_repo"
    fi
    add_to_plan "$name" "$dev_repo" keep "$DIGEST"
  else
    add_to_plan "$name" "$current_repo" keep "$DIGEST"
  fi
elif [[ "$ENV" == prod-sim ]]; then
  while read -r name repo tag digest; do
    add_to_plan "$name" "$repo" "$tag" "$digest"
  done < <(entries "$DEV_KUSTOMIZATION")
else
  [[ -s "$DIGESTS_FILE" ]] || die "nothing to promote: pass IMAGE= and DIGEST=, or run make images to write ${DIGESTS_FILE#"$ROOT"/}"
  # A partial file must not look like a complete set. Backend, web and the rest move together.
  if [[ -f apps/wayline/images.txt ]]; then
    [[ "$(awk '$1 !~ /^#/ && NF { print $1 }' apps/wayline/images.txt | LC_ALL=C sort)" == "$(cut -f1 "$DIGESTS_FILE" | LC_ALL=C sort)" ]] \
      || die "$DIGESTS_FILE does not name every image in apps/wayline/images.txt. Run make images again, or use IMAGE= and DIGEST="
  fi
  while IFS=$'\t' read -r image repo digest; do
    [[ -n "$image" ]] || continue
    [[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]] || die "bad digest for $image in $DIGESTS_FILE"
    read -r name _ _ _ < <(entry_for "$KUSTOMIZATION" "$image")
    add_to_plan "$name" "$repo" keep "$digest"
  done <"$DIGESTS_FILE"
fi

# A publish that failed or was refused leaves its promotion on main, and that is one way to an empty
# plan. So this publishes before it says anything, and that does nothing if main is published already.
if [[ ! -s "$PLAN" ]]; then
  if [[ "$COMMIT" == yes ]]; then
    "$ROOT/scripts/gitops-publish.sh" ||
      die "$ENV's overlay already holds these digests, but main could not be published, so Argo CD has not read them. They leave with the next publish of any kind. Fix the cause and run this again, or withdraw them with make rollback ENV=$ENV."
  fi
  ok "$ENV already runs these digests, nothing to promote"
  exit 0
fi

log "Promotion plan for $ENV"
while read -r name repo tag digest; do
  printf '    %s -> %s@%s\n' "${name##*/}" "$repo" "$digest"
done <"$PLAN"

while read -r name repo tag digest; do
  if [[ "$ENV" == prod-sim ]]; then
    "$ROOT/scripts/ci/check-promoted-digests.sh" "$name=$digest"
  fi
  # A digest the local registry lacks would sit in ImagePullBackOff after Argo CD syncs it.
  if [[ "$repo" == localhost:5001/* && "${SKIP_REGISTRY_CHECK:-}" != yes ]]; then
    curl -fsSI -o /dev/null --max-time 10 \
      -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json' \
      "http://localhost:5001/v2/${repo#localhost:5001/}/manifests/$digest" ||
      die "$repo@$digest is not in the local registry. Run make images, or copy it with scripts/ci/copy-to-local-registry.sh."
  fi
done <"$PLAN"

if [[ "$ENV" == prod-sim ]]; then
  plan_items=()
  while read -r name _ _ digest; do plan_items+=("$name=$digest"); done <"$PLAN"
  check_dev_proven "${plan_items[@]}" || refuse_unproven_dev "Nothing changed."
fi

# Fails now rather than folding unrelated drift into a promotion commit.
"$ROOT/scripts/render.sh" --check >/dev/null || die "rendered manifests are already stale: run make render and commit first"

if [[ "$ENV" == prod-sim ]]; then
  if [[ "${CONFIRM:-}" != yes ]]; then
    [[ -t 0 ]] || die "prod-sim needs CONFIRM=yes when not run from a terminal"
    read -r -p "Promote the images above to prod-sim? Type yes: " answer
    [[ "$answer" == yes ]] || die "not confirmed, nothing changed"
  fi
  if [[ "${SKIP_BACKUP:-}" == yes ]]; then
    warn "SKIP_BACKUP=yes: no backup taken before this promotion"
  else
    log "Backing up prod-sim first, because rolling back an image does not roll back a migration"
    "$ROOT/scripts/backup.sh" prod-sim || die "backup failed, nothing was promoted. SKIP_BACKUP=yes overrides."
  fi
fi

# From here to the commit nobody else's commit may run, or it would take this half-made change with it.
# The dump above took minutes, so the check at the top may be stale, and the restore in cleanup
# relies on it.
take_commit_lock
[[ -z "$(git status --porcelain -- "$OVERLAY" "$RENDERED")" ]] || die "$OVERLAY or $RENDERED has uncommitted changes, made since this started. Nothing was promoted."
applied=yes
subject_parts=""
trailers="Promote-Env: $ENV"
while read -r name repo tag digest; do
  reference="$repo@$digest"
  [[ "$tag" == - ]] || reference="$repo:$tag@$digest"
  (cd "$OVERLAY" && kustomize edit set image "$name=$reference")
  short="${name##*/}"
  subject_parts+="${subject_parts:+, }$short ${digest:7:12}"
  trailers+=$'\n'"Promote-Image: $short=$reference"
done <"$PLAN"

"$ROOT/scripts/render.sh" || die "rendering the promotion failed, so nothing was committed or published"

[[ -z "$DEV_CHECK" ]] || trailers+=$'\n'"Promote-Dev-Check: $DEV_CHECK"

subject="promote($ENV): $subject_parts"
message_file="$ROOT/.build/promote-message.txt"
mkdir -p "$ROOT/.build"
printf '%s\n\n%s\n' "$subject" "$trailers" >"$message_file"

if [[ "$COMMIT" != yes ]]; then
  applied=no
  ok "$ENV overlay and manifests updated, not committed. Commit message in ${message_file#"$ROOT"/}"
  exit 0
fi

git_when_index_free add -- "$OVERLAY" "$RENDERED" || die "could not stage the promotion, so nothing was committed or published"
git_when_index_free commit --quiet --file "$message_file" -- "$OVERLAY" "$RENDERED" || die "could not commit the promotion, so nothing was published"
applied=no
release_commit_lock
ok "committed $(git rev-parse --short HEAD): $subject"

# A promotion of prod-sim took its dump above, or was told not to. A promotion of dev took none, and
# main may hold a merged promotion of prod-sim that leaves with it, so that publish decides for itself.
# The plane-dev check runs once more in there on purpose, so a local promotion and a merged one meet
# the same check at the same door.
publish_status=0
if [[ "$ENV" == prod-sim ]]; then
  SKIP_BACKUP=yes "$ROOT/scripts/gitops-publish.sh" || publish_status=$?
else
  "$ROOT/scripts/gitops-publish.sh" || publish_status=$?
fi
[[ "$publish_status" -eq 0 ]] ||
  die "$(git log -1 --format='%h %s') stays on main, and Argo CD has not read it. It leaves with the next publish of any kind. Fix the cause and run this again, which publishes it, or withdraw it with make rollback ENV=$ENV."
