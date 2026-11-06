#!/usr/bin/env bash
# The gate in front of hosted production. May what this commit renders for plane-prod reach it?
#
#   scripts/ci/check-prod-evidence.sh
#
# Exit 0  Every image in gitops/environments/prod/manifests.yaml is in one signed evidence file, which covers exactly
#         that set and says dev ran it. Stdout is one line, set_hash=<hash>. Everything else goes to stderr.
# Exit 1  Refused, and it says why. Anything this script did not expect ends here too.
# Exit 3  Not promoted yet: no Application reads the render, and Wayline's digests are still the null digest.
#         scripts/ci/publish-release.sh then releases the platform alone.
#
# It reads the commit at HEAD and not the working tree, so a file edited after the commit changes nothing. That goes for
# the allowed signers, the evidence and the render, and this script refuses to run if it is not itself what HEAD holds.
# promote-prod.sh tests a change before anyone commits it by running this in a worktree of a commit made for the purpose.
#
# Nothing asks it to be lenient: no argument, no setting and no cluster, and git is its only way to history, with no
# fetch. It holds no clock either, so an older set keeps its evidence and a rollback to it passes.
#
# docs/evidence/promotions/README.md describes the evidence file, and what a signature does and does not prove.
set -euo pipefail

NULL_DIGEST=sha256:0000000000000000000000000000000000000000000000000000000000000000
HOSTED_REPOSITORY=ssh://git@ssh.github.com:443/BereketAbera/plane-platform.git
DEPLOY_BRANCH=deploy/plane-prod
GHCR_PREFIX=ghcr.io/bereketabera/wayline
SELF=scripts/ci/check-prod-evidence.sh
SIGNERS=.github/evidence-signers
SIGNER=wayline-evidence
EVIDENCE_DIR=docs/evidence/promotions
ENVIRONMENT_DIR=gitops/environments/prod
MANIFESTS=$ENVIRONMENT_DIR/manifests.yaml
CLUSTER_DIR=gitops/clusters/plane-prod
APPLICATIONS=$CLUSTER_DIR/applications
PLANE_APPLICATION=$APPLICATIONS/plane-prod.yaml
DEV_OVERLAY=helm/plane/overlays/dev/kustomization.yaml

REFUSED=no
refuse() { REFUSED=yes; printf 'refused: %s\n' "$*" >&2; exit 1; }

# jq exits 3 on a program it cannot compile, and set -e would pass that on. So only not_yet_promoted may end this script
# with 3, and any other unplanned exit is a refusal.
NOT_YET_PROMOTED=no
WORK="$(mktemp -d)"
finish() {
  local status=$?
  rm -rf "$WORK"
  if [[ "$status" -ne 0 && "$NOT_YET_PROMOTED" != yes ]]; then
    if [[ "$REFUSED" != yes ]]; then printf 'refused: this check stopped before it finished, with status %s, so it proved nothing\n' "$status" >&2; fi
    status=1
  fi
  exit "$status"
}
trap finish EXIT
trap 'exit 1' INT TERM
not_yet_promoted() {
  NOT_YET_PROMOTED=yes
  printf 'not promoted yet: %s\n' "$*" >&2
  exit 3
}

[[ $# -eq 0 ]] || refuse "this takes no arguments and has no overrides, and got: $*"

# GIT_DIR and its relatives could point every read below at another repository, and a replace ref could swap a blob.
# shellcheck disable=SC2046  # one variable name per word is what this prints
unset $(git rev-parse --local-env-vars)
export GIT_NO_REPLACE_OBJECTS=1

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
ROOT="$(cd "$(dirname "$SCRIPT")/../.." && pwd -P)"
cd "$ROOT"
export PATH="$ROOT/.tools/bin:$PATH"
[[ "$(git rev-parse --show-toplevel 2>/dev/null)" == "$ROOT" ]] || refuse "$ROOT is not the top of a Git repository, so there is no commit to test"
COMMIT="$(git rev-parse --verify --quiet 'HEAD^{commit}')" || refuse "this repository has no commits"
# Ancestry below would read a truncated history as a missing one.
[[ "$(git rev-parse --is-shallow-repository)" == false ]] || refuse "shallow clone: this check reads history, so check out with fetch-depth: 0"

committed_self="$(git rev-parse --verify --quiet "$COMMIT:$SELF")" || refuse "$SELF is not in commit $COMMIT, and it must test itself from the commit under test"
[[ "$(git hash-object --no-filters -- "$SCRIPT")" == "$committed_self" ]] || refuse "$SCRIPT is not what commit $COMMIT holds, so it is not the check that commit asks for. Commit it, or restore it"

for tool in jq yq ssh-keygen; do
  command -v "$tool" >/dev/null 2>&1 || refuse "$tool is not on PATH, so nothing could be checked. scripts/install-tools.sh yq fetches the pinned yq"
done

at_commit() { git cat-file blob "$COMMIT:$1"; } # at_commit <path>: the bytes this commit holds, never the working tree's
in_commit() { git cat-file -e "$COMMIT:$1" 2>/dev/null; } # in_commit <path>
sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; } # stdin
is_true() { # is_true <jq arguments...>: 0 true, 1 false. A jq that failed must not read as false.
  local status=0
  jq -e "$@" >/dev/null || status=$?
  case "$status" in
    0 | 1) return "$status" ;;
    *) refuse "jq could not read this: jq $*" ;;
  esac
}
refuse_all() { # refuse_all <file of problems, one a line>
  if [[ -s "$1" ]]; then
    REFUSED=yes
    sed 's/^/refused: /' "$1" >&2
    exit 1
  fi
}

# ---- Who reads the render -------------------------------------------------------------------------------------------
# Root reads everything under applications/, so an Application under another file name deploys this render too, and exit 3
# would not be true of it.
HAS_PLANE_APPLICATION=no
while read -r file <&3; do
  [[ -n "$file" ]] || continue
  case "$file" in
    *.yaml | *.yml | *.json) ;;
    *.jsonnet) refuse "$file: Argo CD would read it and this cannot, so it could deploy anything" ;;
    *) continue ;;
  esac
  at_commit "$file" >"$WORK/application.yaml"
  yq -o=json -I=0 '.' "$WORK/application.yaml" >"$WORK/application.json" || refuse "$file is not YAML, so nothing can say what it deploys"
  if [[ "$file" == "$PLANE_APPLICATION" ]]; then
    HAS_PLANE_APPLICATION=yes
    jq -s -r --arg repository "$HOSTED_REPOSITORY" --arg branch "$DEPLOY_BRANCH" --arg path "$ENVIRONMENT_DIR" '
      map(select(. != null)) as $documents
      | $documents[0] as $application
      | (if ($documents | length) != 1 then "holds \($documents | length) documents, and must hold one Application" else empty end),
        (if $application.kind != "Application" then "is not an Application" else empty end),
        (if $application.metadata.name != "plane-prod" then "is not named plane-prod" else empty end),
        (if $application.spec.sources != null then "has several sources, and a second one would deploy what this check does not read" else empty end),
        (if $application.spec.source.repoURL != $repository then "reads \($application.spec.source.repoURL), not \($repository)" else empty end),
        (if $application.spec.source.targetRevision != $branch then "reads revision \($application.spec.source.targetRevision), not \($branch)" else empty end),
        (if $application.spec.source.path != $path then "reads path \($application.spec.source.path), not \($path), which is the render this check reads" else empty end),
        (if $application.spec.destination.namespace != "plane-prod" then "deploys to namespace \($application.spec.destination.namespace), not plane-prod" else empty end),
        empty' "$WORK/application.json" | sed "s|^|$file |" >"$WORK/application-problems"
    refuse_all "$WORK/application-problems"
  elif is_true -s 'map(select(type == "object" and .kind == "Application"))
      | any(.metadata.name == "plane-prod" or (((.spec.sources // []) + [.spec.source // {}]) | any((.path // "") | test("(^|/)environments(/|$)"))))' "$WORK/application.json"; then
    refuse "$file also reads the Plane render. Only $PLANE_APPLICATION may, or this check would be gating an Application it does not know"
  fi
done 3< <(git ls-tree -r --name-only "$COMMIT" -- "$APPLICATIONS/")

# Argo CD reads this whole directory, so a second file would reach the cluster with no evidence.
stray="$(git ls-tree -r --name-only "$COMMIT" -- "$ENVIRONMENT_DIR/" | grep -vxF "$MANIFESTS" || true)"
[[ -z "$stray" ]] || refuse "Argo CD reads all of $ENVIRONMENT_DIR and this reads only $MANIFESTS, so these would reach the cluster with no evidence: ${stray//$'\n'/, }"

# A Wayline image anywhere else in the hosted tree would be deployed with no evidence at all.
grep_status=0
elsewhere="$(git grep -n -F "$GHCR_PREFIX" "$COMMIT" -- "$CLUSTER_DIR/" 2>&1)" || grep_status=$?
[[ "$grep_status" -ne 0 ]] || refuse "only $MANIFESTS may name a Wayline image, and this evidence does not cover these: ${elsewhere//$'\n'/, }"
[[ "$grep_status" -eq 1 ]] || refuse "could not search $CLUSTER_DIR: $elsewhere"

# ---- What the render runs -------------------------------------------------------------------------------------------
if ! in_commit "$MANIFESTS"; then
  [[ "$HAS_PLANE_APPLICATION" == no ]] || refuse "$PLANE_APPLICATION exists and $MANIFESTS does not, so Argo CD has nothing to deploy"
  not_yet_promoted "this commit has no $MANIFESTS and no $PLANE_APPLICATION"
fi
at_commit "$MANIFESTS" >"$WORK/manifests.yaml"
yq -o=json -I=0 '.' "$WORK/manifests.yaml" >"$WORK/manifests.json" || refuse "$MANIFESTS is not YAML"

# Every field called image, in any kind of object, and not only the shapes a grep for pod specs would know.
jq -r '.. | objects | select(has("image")) | .image | if type == "string" then . else "(not a string)" end' "$WORK/manifests.json" | LC_ALL=C sort -u >"$WORK/images"
[[ -s "$WORK/images" ]] || refuse "$MANIFESTS names no image, so there is nothing to have evidence for"

# The set is <repository>@<digest>, one a line. A tag beside a digest only documents the version, and the runtime ignores it.
: >"$WORK/unsorted"
while read -r reference; do
  [[ "$reference" =~ ^([^@[:space:]]+)@(sha256:[a-f0-9]{64})$ ]] || refuse "$MANIFESTS names an image that is not pinned by digest: $reference"
  repository="${BASH_REMATCH[1]}"
  digest="${BASH_REMATCH[2]}"
  last_part="${repository##*/}"
  if [[ "$last_part" == *:* ]]; then repository="${repository%:*}"; fi
  printf '%s@%s\n' "$repository" "$digest" >>"$WORK/unsorted"
done <"$WORK/images"
LC_ALL=C sort -u "$WORK/unsorted" >"$WORK/set"

# A digest in an env value or a command, as the dump Job's BACKEND_IMAGE, has to be one the images have.
grep -oE 'sha256:[a-f0-9]{64}' "$WORK/manifests.yaml" | LC_ALL=C sort -u >"$WORK/digests-anywhere" || true
sed 's/.*@//' "$WORK/set" | LC_ALL=C sort -u >"$WORK/digests-of-images"
outside="$(LC_ALL=C comm -23 "$WORK/digests-anywhere" "$WORK/digests-of-images")"
[[ -z "$outside" ]] || refuse "$MANIFESTS holds a digest outside its images, which no evidence can cover: ${outside//$'\n'/, }"

null_references="$(grep -F "@$NULL_DIGEST" "$WORK/set" || true)"
if [[ -n "$null_references" ]]; then
  [[ "$HAS_PLANE_APPLICATION" == no ]] || refuse "$PLANE_APPLICATION exists and $MANIFESTS still names the null digest, so Argo CD would deploy an image that does not exist: ${null_references//$'\n'/, }"
  promoted_wayline="$(grep -F "$GHCR_PREFIX/" "$WORK/set" | grep -vF "@$NULL_DIGEST" || true)"
  [[ -z "$promoted_wayline" ]] || refuse "$MANIFESTS names the null digest beside real Wayline digests, so it is neither promoted nor not: ${promoted_wayline//$'\n'/, }"
  not_yet_promoted "no Application reads $MANIFESTS, and it holds the null digest"
fi

# ---- The evidence for exactly this set -------------------------------------------------------------------------------
SET_HASH="$(sha256_of <"$WORK/set")"
EVIDENCE="$EVIDENCE_DIR/$SET_HASH.json"
if ! in_commit "$EVIDENCE"; then
  while read -r reference; do
    git grep -q -F "${reference##*@}" "$COMMIT" -- "$EVIDENCE_DIR/*.json" || printf 'refused: no evidence names %s\n' "$reference" >&2
  done <"$WORK/set"
  refuse "$EVIDENCE is not in this commit, so no evidence covers exactly the set $MANIFESTS runs"
fi
in_commit "$EVIDENCE.sig" || refuse "$EVIDENCE has no signature at $EVIDENCE.sig"
in_commit "$SIGNERS" || refuse "$SIGNERS is not in this commit, so nobody may sign"
at_commit "$EVIDENCE" >"$WORK/evidence.json"
at_commit "$EVIDENCE.sig" >"$WORK/evidence.json.sig"
at_commit "$SIGNERS" >"$WORK/signers"
ssh-keygen -Y verify -f "$WORK/signers" -I "$SIGNER" -n "$SIGNER" -s "$WORK/evidence.json.sig" <"$WORK/evidence.json" >/dev/null 2>"$WORK/verify-output" ||
  refuse "the signature on $EVIDENCE does not verify against $SIGNERS as this commit holds it, as principal and namespace $SIGNER: $(tr '\n' ' ' <"$WORK/verify-output")"

# The file's name comes from the render, and this is what the signed text says it covers.
jq -r '.images[] | .production_repository + "@" + .digest' "$WORK/evidence.json" | LC_ALL=C sort -u >"$WORK/evidence-set"
cmp -s "$WORK/set" "$WORK/evidence-set" ||
  refuse "$EVIDENCE does not cover exactly what $MANIFESTS runs. Only in the render: $(LC_ALL=C comm -23 "$WORK/set" "$WORK/evidence-set" | tr '\n' ' '). Only in the evidence: $(LC_ALL=C comm -13 "$WORK/set" "$WORK/evidence-set" | tr '\n' ' ')"

# The smoke the evidence names, as this commit holds it. A path from the file goes through git, so only by shape here.
smoke_path="$(jq -r '.smoke.published_path // ""' "$WORK/evidence.json")"
[[ "$smoke_path" =~ ^docs/evidence/runs/[A-Za-z0-9._-]+\.json$ ]] || refuse "$EVIDENCE names no published smoke under docs/evidence/runs: '$smoke_path'"
in_commit "$smoke_path" || refuse "$EVIDENCE names $smoke_path, which is not in this commit"
at_commit "$smoke_path" >"$WORK/smoke.json"
[[ "$(sha256_of <"$WORK/smoke.json")" == "$(jq -r '.smoke.sha256 // ""' "$WORK/evidence.json")" ]] || refuse "$smoke_path is not the file $EVIDENCE signed. If make publish-evidence rewrote it, restore it from Git: git log -- $smoke_path"

# Each rule is one line, so scripts/ci/test-prod-gate.sh --mutations can take one away and see a scenario go red.
jq -r --arg set_hash "$SET_HASH" --arg ghcr "$GHCR_PREFIX/" --arg null_digest "$NULL_DIGEST" --slurpfile published "$WORK/smoke.json" '
  def stamp: try fromdateiso8601 catch null;
  def digest: type == "string" and test("^sha256:[a-f0-9]{64}$") and . != $null_digest;
  def hex40: type == "string" and test("^[a-f0-9]{40}$");
  def plain: . == "application/vnd.oci.image.manifest.v1+json" or . == "application/vnd.docker.distribution.manifest.v2+json";
  def step($name): [$published[0].steps[]? | select(.name == $name)] | first // {};
  . as $e
  | ($e.smoke.started_at | stamp) as $began
  | ($e.smoke.finished_at | stamp) as $ended
  | ([$e.images[] | select(.kind == "branded") | {key: .component, value: .digest}] | from_entries) as $branded
  | (if $e.schema != 1 then "schema is \($e.schema), and this reads 1" else empty end),
    (if $e.set_hash != $set_hash then "says its set is \($e.set_hash), and it is filed as \($set_hash)" else empty end),
    (if $e.environment != "plane-dev" then "was not recorded in plane-dev: \($e.environment)" else empty end),
    (if $e.executed_under != "rosetta-on-arm64" then "records execution under \($e.executed_under), and only rosetta-on-arm64 is what dev does" else empty end),
    (if $e.smoke.result != "PASS" then "records a smoke that did not pass: \($e.smoke.result)" else empty end),
    (if $e.smoke.branding_overlay != "PASS" then "records branding-overlay as \($e.smoke.branding_overlay), so that smoke did not check the branded images" else empty end),
    (if $began == null or $ended == null or $began > $ended then "does not say when its smoke ran: \($e.smoke.started_at) to \($e.smoke.finished_at)" else empty end),
    (if $published[0].tool != "tests/e2e/smoke.py" or $published[0].environment != "dev" or $published[0].mode != "full" then "names a published file that is no full dev smoke" else empty end),
    (if $published[0].result != "PASS" then "names a published smoke that says \($published[0].result)" else empty end),
    (if (step("branding-overlay").status) != "PASS" then "names a published smoke where branding-overlay is \(step("branding-overlay").status)" else empty end),
    (if (step("branding-overlay").data.branded // {}) != $branded then "names a published smoke that ran other branded digests than this set" else empty end),
    (if $published[0].started_at != $e.smoke.started_at or $published[0].finished_at != $e.smoke.finished_at then "gives other times for its smoke than the published file" else empty end),
    ($e.images[]
     | . as $i
     | "\($i.component // "an image") "
     + (
       (if ($i.digest | digest) | not then "has no digest it could have run: \($i.digest)" else empty end),
       (if ($i.containers | type) != "array" or ($i.containers | length) == 0 then "names no container that ran it" else empty end),
       (if ($i.containers // [])[] | (.started_at | stamp) as $started | ($started == null or (if .replaced_by_smoke == true then $started >= $ended else $started >= $began end)) then "has a container started at or after the smoke began, so that smoke says nothing about it" else empty end),
       (if ($i.containers // []) | any(.replaced_by_smoke == true) and $i.component != "backend" then "claims a container the smoke replaced, and the smoke replaces only the worker" else empty end),
       (if ($i.containers // []) | all(.replaced_by_smoke == true) then "has no container that was there when the smoke began" else empty end),
       (if $i.kind == "branded" then
          (if $i.platform != "linux/amd64" then "is recorded as \($i.platform), and production runs only linux/amd64" else empty end),
          (if ($i.media_type | plain) | not then "is recorded as \($i.media_type), not a plain manifest" else empty end),
          (if ($i.revision | hex40) | not then "records no revision: \($i.revision)" else empty end),
          (if $i.production_repository != $ghcr + $i.component then "is to run from \($i.production_repository), not \($ghcr + $i.component)" else empty end),
          (if $i.dev_repository != "localhost:5001/wayline/" + $i.component then "ran from \($i.dev_repository), not localhost:5001/wayline/\($i.component)" else empty end),
          empty
        elif $i.kind == "upstream-index" then
          (if ($i.production_repository | startswith($ghcr)) then "is a Wayline image recorded as an upstream one" else empty end),
          (if $i.production_repository != $i.dev_repository then "ran from \($i.dev_repository) and would run from \($i.production_repository)" else empty end),
          (if $i.dev_ran.platform != "linux/arm64" or (($i.dev_ran.digest | digest) | not) then "does not say which child of the index dev ran" else empty end),
          (if $i.production_runs.platform != "linux/amd64" or (($i.production_runs.digest | digest) | not) then "does not say production runs the linux/amd64 child of the index: \($i.production_runs.platform)" else empty end),
          empty
        else
          "is of kind \($i.kind), which this does not know"
        end),
       empty
     )
    ),
    empty
  ' "$WORK/evidence.json" | sed "s|^|$EVIDENCE |" >"$WORK/problems"
refuse_all "$WORK/problems"

# ---- History: what the evidence names must be behind this commit, and say what it claims ------------------------------
argo_revision="$(jq -r '.argo_revision // ""' "$WORK/evidence.json")"
[[ "$argo_revision" =~ ^[a-f0-9]{40}$ ]] || refuse "$EVIDENCE names no Argo revision: '$argo_revision'"
# gitops-publish.sh publishes commits GitHub may never get, and dev can run one of those.
git merge-base --is-ancestor "$argo_revision" "$COMMIT" 2>/dev/null || refuse "$EVIDENCE says dev ran commit $argo_revision, which is not in this commit's history"
git cat-file blob "$argo_revision:$DEV_OVERLAY" >"$WORK/dev-overlay.yaml" 2>/dev/null || refuse "commit $argo_revision has no $DEV_OVERLAY"
yq -o=json -I=0 '.' "$WORK/dev-overlay.yaml" | jq -r '.images[] | [.name, (.newName // .name), .digest] | @tsv' | LC_ALL=C sort >"$WORK/dev-pairs"
jq -r '.images[] | [.chart_image, .dev_repository, .digest] | @tsv' "$WORK/evidence.json" | LC_ALL=C sort >"$WORK/evidence-pairs"
cmp -s "$WORK/dev-pairs" "$WORK/evidence-pairs" || refuse "$EVIDENCE says dev ran these at $argo_revision, and that commit's $DEV_OVERLAY names others"

while read -r revision; do
  git merge-base --is-ancestor "$revision" "$COMMIT" 2>/dev/null || refuse "$EVIDENCE says an image was built from $revision, which is not in this commit's history"
done < <(jq -r '.images[] | select(.kind == "branded") | .revision' "$WORK/evidence.json" | LC_ALL=C sort -u)

printf 'ok: every image in %s is in %s, signed by %s\n' "$MANIFESTS" "$EVIDENCE" "$SIGNER" >&2
printf 'set_hash=%s\n' "$SET_HASH"
