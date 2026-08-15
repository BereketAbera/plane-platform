#!/usr/bin/env bash
# The only writer of deploy/plane-prod, the one branch hosted Argo CD reads. ci.yml's release-plane-prod job runs it on each
# push to main, after every other job has passed.
#
#   GITHUB_TOKEN=... scripts/ci/publish-release.sh
#
# In order, stopping at the first that fails, so a failure leaves the branch where it is and reaches nothing:
#   1. scripts/ci/check-prod-evidence.sh. Exit 3 means plane-prod is not promoted yet, and the release holds the platform alone.
#   2. The refusal to move backwards: RELEASE.json on the branch names a main commit, and this one must descend from it.
#   3. Nothing to do if the two hosted trees match the branch's, and the branch stays where it is.
#   4. Each Wayline digest must be a plain linux/amd64 manifest on GHCR, read with GITHUB_TOKEN.
#   5. A commit parented on the branch's tip, or on nothing the first time, holding only gitops/clusters/plane-prod,
#      gitops/environments/prod and RELEASE.json. So a workflow file cannot cross, and GitHub lets GITHUB_TOKEN push it.
#      It is pushed without force, so a branch that moved meanwhile refuses it.
#
# It builds that commit from objects, with a temporary index, and touches neither the working tree nor the checkout's index.
# With no gitops/clusters/plane-prod at this commit there is nothing to release, and it says so and exits 0.
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

[[ $# -eq 0 ]] || die "usage: $0, which releases HEAD"

BRANCH=deploy/plane-prod
CLUSTER_TREE=gitops/clusters/plane-prod
ENVIRONMENT_TREE=gitops/environments/prod
GHCR_PREFIX=ghcr.io/bereketabera/wayline
# All four, so an index answers as an index and the refusal below can say so.
ACCEPT='application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json'

cd "$ROOT"
COMMIT="$(git rev-parse --verify --quiet 'HEAD^{commit}')" || die "this repository has no commits"

summary() { # summary <line>: for whoever reads the run
  log "$1"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then printf '%s\n' "$1" >>"$GITHUB_STEP_SUMMARY"; fi
}
in_commit() { git cat-file -e "$COMMIT:$1" 2>/dev/null; } # in_commit <path>
sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; } # sha256_of <file>

if ! in_commit "$CLUSTER_TREE"; then
  summary "$COMMIT has no $CLUSTER_TREE, so there is nothing to release yet. $BRANCH stays where it is."
  exit 0
fi
in_commit "$ENVIRONMENT_TREE" || die "$COMMIT has $CLUSTER_TREE and no $ENVIRONMENT_TREE, and the branch needs both. Run make render and commit."

# RELEASE.json has to name a run, and this is how a laptop does not publish by accident.
[[ -n "${GITHUB_RUN_ID:-}" ]] || die "this is the release-plane-prod job's, and GITHUB_RUN_ID is not set. A release has to name the run that made it"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log "Checking the evidence for $COMMIT"
check_status=0
# It needs no token, and yq and jq run under it.
env -u GITHUB_TOKEN "$ROOT/scripts/ci/check-prod-evidence.sh" >"$WORK/check-output" || check_status=$?
SET_HASH=""
case "$check_status" in
  0) SET_HASH="$(sed -n 's/^set_hash=//p' "$WORK/check-output")" ;;
  3) summary "plane-prod is not promoted yet, so this release holds the platform alone." ;;
  *) die "check-prod-evidence.sh refused $COMMIT, so $BRANCH stays where it is and this commit reaches nothing" ;;
esac
[[ "$check_status" -ne 0 || "$SET_HASH" =~ ^[a-f0-9]{64}$ ]] || die "check-prod-evidence.sh passed and named no set: $(cat "$WORK/check-output")"

# GITHUB_TOKEN from the job's environment, read when git asks, so it is never on a command line or in .git/config.
remote_git() { # remote_git <git arguments...>
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    # shellcheck disable=SC2016  # git's credential helper expands this, not this shell
    git -c credential.helper= -c 'credential.helper=!f() { test "$1" = get || return 0; printf "username=x-access-token\npassword=%s\n" "$GITHUB_TOKEN"; }; f' "$@"
  else
    git "$@"
  fi
}

remote_tip="$(remote_git ls-remote origin "refs/heads/$BRANCH")" || die "could not read origin, and an unreadable branch must not look like a missing one"
TIP="${remote_tip%%[[:space:]]*}"
remote_git fetch --quiet origin "+refs/heads/main:refs/remotes/origin/main" || die "could not fetch origin's main"
git merge-base --is-ancestor "$COMMIT" refs/remotes/origin/main || die "$COMMIT is not on origin's main, and only main is released"

if [[ -n "$TIP" ]]; then
  remote_git fetch --quiet origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" || die "could not fetch $BRANCH"
  # A person or a bad version of this script put something else there. A workflow file would run on that branch, and
  # GITHUB_TOKEN may not remove one, so this takes a person.
  foreign="$(git ls-tree -r --name-only "$TIP" | grep -vE "^(RELEASE\.json|$CLUSTER_TREE/.*|$ENVIRONMENT_TREE/.*)$" || true)"
  [[ -z "$foreign" ]] || die "$BRANCH at $TIP holds more than a release should, so a person has to look at it: ${foreign//$'\n'/, }"
  recorded="$(git cat-file blob "$TIP:RELEASE.json" 2>/dev/null | jq -r '.main_commit // ""' 2>/dev/null || true)"
  [[ "$recorded" =~ ^[a-f0-9]{40}$ ]] || die "$BRANCH at $TIP has no RELEASE.json naming a main commit, so nothing says this would move forwards"
  git merge-base --is-ancestor "$recorded" "$COMMIT" 2>/dev/null ||
    die "$BRANCH was released from $recorded, and $COMMIT does not descend from it. Refusing to move backwards. A rollback is a revert on main, which moves forwards"

  unchanged=yes
  for tree in "$CLUSTER_TREE" "$ENVIRONMENT_TREE"; do
    [[ "$(git rev-parse --verify --quiet "$TIP:$tree" || true)" == "$(git rev-parse --verify --quiet "$COMMIT:$tree")" ]] || unchanged=no
  done
  if [[ "$unchanged" == yes ]]; then
    summary "$BRANCH at $TIP already holds what $COMMIT would release, so it stays there."
    exit 0
  fi
fi

confirm_on_ghcr() { # confirm_on_ghcr <repository> <digest> <revision the evidence signed>
  local repository="$1" digest="$2" revision="$3" path token config_digest found
  path="${repository#ghcr.io/}"
  # On stdin, so neither the token nor the bearer is on a command line.
  token="$(printf 'user = "%s:%s"\n' "${GITHUB_ACTOR:-x-access-token}" "$GITHUB_TOKEN" |
    curl -fsS --retry 3 -K - "https://ghcr.io/token?service=ghcr.io&scope=repository:$path:pull" | jq -r '.token // ""')" ||
    die "GHCR gave no token to read $repository. Does this repository's Actions have access to that package?"
  [[ -n "$token" ]] || die "GHCR gave no token to read $repository"
  printf 'header = "Authorization: Bearer %s"\n' "$token" |
    curl -fsSL --retry 3 -K - -H "Accept: $ACCEPT" -o "$WORK/manifest" "https://ghcr.io/v2/$path/manifests/$digest" ||
    die "GHCR does not serve $repository@$digest"
  [[ "sha256:$(sha256_of "$WORK/manifest")" == "$digest" ]] || die "what GHCR served for $repository@$digest does not hash to that digest"
  jq -e '(has("manifests") | not) and (.mediaType == "application/vnd.oci.image.manifest.v1+json" or .mediaType == "application/vnd.docker.distribution.manifest.v2+json")' "$WORK/manifest" >/dev/null ||
    die "$repository@$digest is not a plain image manifest, and production must run these bytes and no other child"
  config_digest="$(jq -r '.config.digest // ""' "$WORK/manifest")"
  [[ "$config_digest" =~ ^sha256:[a-f0-9]{64}$ ]] || die "$repository@$digest names no config"
  # curl drops an Authorization header when a redirect leaves this host, and blobs do redirect.
  printf 'header = "Authorization: Bearer %s"\n' "$token" |
    curl -fsSL --retry 3 -K - -o "$WORK/config" "https://ghcr.io/v2/$path/blobs/$config_digest" ||
    die "GHCR does not serve the config of $repository@$digest"
  [[ "sha256:$(sha256_of "$WORK/config")" == "$config_digest" ]] || die "what GHCR served as the config of $repository@$digest does not hash to $config_digest"
  found="$(jq -r '[.os, .architecture, (.variant // "")] | join("/")' "$WORK/config")"
  [[ "$found" == linux/amd64/ ]] || die "$repository@$digest is for $found, and production is linux/amd64"
  found="$(jq -r '.config.Labels["org.opencontainers.image.revision"] // ""' "$WORK/config")"
  [[ "$found" == "$revision" ]] || die "$repository@$digest says it was built from '$found', and its evidence says $revision"
  ok "$repository@$digest is a plain linux/amd64 manifest on GHCR, built from ${revision:0:12}"
}

# Not promoted yet has only the null digest to offer, which nothing reads and GHCR cannot serve.
if [[ -n "$SET_HASH" ]]; then
  [[ -n "${GITHUB_TOKEN:-}" ]] || die "reading GHCR takes GITHUB_TOKEN, and it is not set"
  log "Confirming each Wayline digest on GHCR"
  git cat-file blob "$COMMIT:docs/evidence/promotions/$SET_HASH.json" |
    jq -r --arg prefix "$GHCR_PREFIX/" '.images[] | select(.production_repository | startswith($prefix)) | [.production_repository, .digest, .revision] | @tsv' >"$WORK/wayline-images"
  [[ -s "$WORK/wayline-images" ]] || die "the evidence for set $SET_HASH names no Wayline image, so GHCR has nothing to confirm"
  while IFS=$'\t' read -r repository digest revision <&3; do
    confirm_on_ghcr "$repository" "$digest" "$revision"
  done 3<"$WORK/wayline-images"
fi

log "Assembling the release"
jq -n --arg main_commit "$COMMIT" --arg repository "${GITHUB_REPOSITORY:-}" --arg id "$GITHUB_RUN_ID" --arg attempt "${GITHUB_RUN_ATTEMPT:-}" \
  --arg url "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/$GITHUB_RUN_ID" --arg set_hash "$SET_HASH" \
  '{main_commit: $main_commit, repository: $repository, run: {id: $id, attempt: $attempt, url: $url}, set_hash: (if $set_hash == "" then null else $set_hash end)}' >"$WORK/RELEASE.json"

export GIT_INDEX_FILE="$WORK/index"
git read-tree --empty
git read-tree --prefix="$CLUSTER_TREE/" "$COMMIT:$CLUSTER_TREE"
git read-tree --prefix="$ENVIRONMENT_TREE/" "$COMMIT:$ENVIRONMENT_TREE"
git update-index --add --cacheinfo "100644,$(git hash-object -w -- "$WORK/RELEASE.json"),RELEASE.json"
TREE="$(git write-tree)"
unset GIT_INDEX_FILE

export GIT_AUTHOR_NAME='github-actions[bot]' GIT_AUTHOR_EMAIL='41898282+github-actions[bot]@users.noreply.github.com'
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
PARENTS=()
if [[ -n "$TIP" ]]; then PARENTS=(-p "$TIP"); fi
RELEASE="$(git commit-tree "$TREE" ${PARENTS[@]+"${PARENTS[@]}"} -m "release: main ${COMMIT:0:12}${SET_HASH:+, set ${SET_HASH:0:12}}")"
remote_git push --quiet origin "$RELEASE:refs/heads/$BRANCH" ||
  die "could not push $BRANCH. If it moved meanwhile, a newer run has it. Otherwise run this job again"
summary "$BRANCH is now ${RELEASE:0:12}, from main ${COMMIT:0:12}${SET_HASH:+, set $SET_HASH}."
