#!/usr/bin/env bash
# Signs a record that plane-dev ran an exact digest set and that its smoke passed against those containers. This is what
# lets those digests reach hosted production: scripts/ci/check-prod-evidence.sh refuses anything without it.
#
#   make record-dev-evidence      after make test-e2e ENV=dev and make publish-evidence
#
# Writes docs/evidence/promotions/<set-hash>.json and <set-hash>.json.sig, and commits nothing. It refuses unless:
#   - the newest dev smoke under .local/evidence-raw is a full run that passed, with branding-overlay and each branded image
#     PASS, and its published copy exists, with the digests the overlay names
#   - plane-dev is Synced and Healthy, at a revision on origin's main
#   - each digest that revision's overlay names runs in a ready container, read by imageID, and no container of those
#     repositories runs any other
#   - each of those containers started before the smoke began. Dev's smoke replaces the worker's pod on purpose
#     (scripts/test.sh passes --worker-negative-control), so that one may start during the smoke if the smoke says it
#     did, and the backend image must also have a container from before the smoke began
#   - each branded digest is a plain linux/amd64 manifest on GHCR, labelled with a commit on origin's main, and named in the
#     log of a successful images.yml push run of that commit
#   - each upstream digest is an index with one linux/arm64 and one linux/amd64 child
#   - the node is arm64, because that is what executed_under: rosetta-on-arm64 says
#
# It needs what only the laptop has: the kind cluster, ~/.ssh/wayline_evidence_ed25519, Docker able to read GHCR (as
# scripts/ci/copy-to-local-registry.sh leaves it) and gh. No key means no evidence, so new digests stay blocked.
# docs/evidence/promotions/README.md describes the file.
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

[[ $# -eq 0 ]] || die "usage: $0"
# Timestamps compare as text below, once they have the one shape they may have.
export LC_ALL=C

KEY="$HOME/.ssh/wayline_evidence_ed25519"
SIGNERS=.github/evidence-signers
SIGNER=wayline-evidence
HOSTED_REPOSITORY=BereketAbera/plane-platform
GHCR_PREFIX=ghcr.io/bereketabera/wayline
DEV_OVERLAY=helm/plane/overlays/dev/kustomization.yaml
RAW_DIR="$LOCAL_DIR/evidence-raw"
RUNS_DIR=docs/evidence/runs
PROMOTIONS_DIR=docs/evidence/promotions
NULL_DIGEST=sha256:0000000000000000000000000000000000000000000000000000000000000000
STAMP_SHAPE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

for tool in docker gh jq kubectl ssh-keygen yq; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is not on PATH. Run: make setup"
done
[[ -f "$KEY" ]] || die "$KEY does not exist, and only that key may sign evidence"
cd "$ROOT"
[[ -f "$SIGNERS" ]] || die "$SIGNERS does not exist"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; } # sha256_of <file>
stop_on_problems() { # stop_on_problems <file of problems, one a line> <what they are about>
  if [[ -s "$1" ]]; then
    sed 's/^/  /' "$1" >&2
    die "$2"
  fi
}

# ---- The newest dev smoke ---------------------------------------------------------------------------------------------
# By what each file says, because a copied file's date and these file names give no order.
SMOKE=""
SMOKE_STARTED=""
for file in "$RAW_DIR"/smoke-dev-*.json; do
  [[ -e "$file" ]] || continue
  started="$(jq -r '.started_at // ""' "$file" 2>/dev/null)" || die "$file is not JSON, and it could be the newest dev smoke. If it is not, move it out of $RAW_DIR"
  [[ "$started" =~ $STAMP_SHAPE ]] || die "$file does not say when it started in the shape tests/e2e/smoke.py writes: '$started'"
  if [[ "$started" > "$SMOKE_STARTED" ]]; then
    SMOKE="$file"
    SMOKE_STARTED="$started"
  fi
done
[[ -n "$SMOKE" ]] || die "no dev smoke in $RAW_DIR. Run: make test-e2e ENV=dev"
log "Newest dev smoke: ${SMOKE#"$ROOT"/}, started $SMOKE_STARTED"

jq -r '
  def step($name): [.steps[]? | select(.name == $name)] | first // {};
  (if .tool != "tests/e2e/smoke.py" then "it is not from tests/e2e/smoke.py" else empty end),
  (if .environment != "dev" then "it ran against \(.environment), not dev" else empty end),
  (if .mode != "full" then "it ran in mode \(.mode), not full" else empty end),
  (if .result != "PASS" then "its result is \(.result)" else empty end),
  (if step("branding-overlay").status != "PASS" then "branding-overlay is \(step("branding-overlay").status // "missing")" else empty end),
  (("web", "admin", "space", "backend") as $image | if step("branding-" + $image).status != "PASS" then "branding-\($image) is \(step("branding-" + $image).status // "missing")" else empty end),
  empty' "$SMOKE" >"$WORK/problems"
stop_on_problems "$WORK/problems" "the newest dev smoke does not prove these images. Fix what it found, and run make test-e2e ENV=dev again"
SMOKE_FINISHED="$(jq -r '.finished_at // ""' "$SMOKE")"
[[ "$SMOKE_FINISHED" =~ $STAMP_SHAPE ]] || die "$SMOKE does not say when it finished: '$SMOKE_FINISHED'"

# The published copy has been scrubbed, so it differs in bytes. It is the one Git keeps, so that is the one this signs.
PUBLISHED="$RUNS_DIR/$(basename "$SMOKE")"
[[ -f "$PUBLISHED" ]] || die "$PUBLISHED does not exist, and the evidence has to name a file Git keeps. Run: make publish-evidence"
smoke_outline() { jq -S -c '{run_id, started_at, finished_at, result, environment, mode, steps: [.steps[] | {name, status, branded: .data.branded}]}' "$1"; }
[[ "$(smoke_outline "$SMOKE")" == "$(smoke_outline "$PUBLISHED")" ]] || die "$PUBLISHED does not say what $SMOKE says. Run: make publish-evidence"

# ---- What Argo CD has plane-dev at --------------------------------------------------------------------------------------
kc --request-timeout=15s -n argocd get application plane-dev -o json >"$WORK/application.json" || die "could not read Application plane-dev. Is the cluster up?"
status="$(jq -r '"\(.status.sync.status)/\(.status.health.status)"' "$WORK/application.json")"
[[ "$status" == Synced/Healthy ]] || die "Application plane-dev is $status, not Synced/Healthy"
ARGO_REVISION="$(jq -r '.status.sync.revision // ""' "$WORK/application.json")"
[[ "$ARGO_REVISION" =~ ^[a-f0-9]{40}$ ]] || die "Application plane-dev names no revision: '$ARGO_REVISION'"
git fetch --quiet origin "+refs/heads/main:refs/remotes/origin/main" || die "could not fetch origin's main, and everything below is measured against it"
# make gitops-publish can publish a commit GitHub does not have. The check needs this one in history, so a commit that
# is only here can never pass there.
git merge-base --is-ancestor "$ARGO_REVISION" refs/remotes/origin/main 2>/dev/null || die "plane-dev is at $ARGO_REVISION, which is not on origin's main. Merge it through a pull request first, with a merge commit"
git cat-file blob "$ARGO_REVISION:$DEV_OVERLAY" >"$WORK/overlay.yaml" 2>/dev/null || die "$ARGO_REVISION has no $DEV_OVERLAY"

yq -o=json -I=0 '.' "$WORK/overlay.yaml" | jq -c --arg ghcr "$GHCR_PREFIX/" '
  [.images[]
   | (.newName // .name) as $dev
   | ($dev | capture("^localhost:5001/wayline/(?<c>[a-z0-9-]+)$").c // null) as $component
   | {kind: (if $component then "branded" else "upstream-index" end),
      component: ($component // (.name | split("/") | last)),
      chart_image: .name, dev_repository: $dev,
      production_repository: (if $component then $ghcr + $component else $dev end),
      tag: (.newTag // null), digest: .digest}]' >"$WORK/entries.json"
jq -e --arg null_digest "$NULL_DIGEST" 'length > 0 and all(.digest | type == "string" and test("^sha256:[a-f0-9]{64}$") and . != $null_digest)' "$WORK/entries.json" >/dev/null ||
  die "$DEV_OVERLAY at $ARGO_REVISION holds an image with no real digest. The failure drill sets the null digest on purpose, and nothing so set may travel"
jq -e 'any(.kind == "branded")' "$WORK/entries.json" >/dev/null || die "$DEV_OVERLAY at $ARGO_REVISION names no Wayline image, so dev has not run what production would"

# The smoke checks whatever the overlay was when it ran, and this has to be the same set.
same_branded="$(jq -n --slurpfile entries "$WORK/entries.json" --slurpfile smoke "$SMOKE" '
  ([$entries[0][] | select(.kind == "branded") | {key: .component, value: .digest}] | from_entries)
  == ([$smoke[0].steps[] | select(.name == "branding-overlay") | .data.branded] | first)')"
[[ "$same_branded" == true ]] || die "the newest smoke checked other branded digests than plane-dev is at. Run make test-e2e ENV=dev again"

# ---- What is running ----------------------------------------------------------------------------------------------------
kc --request-timeout=15s get nodes -o json >"$WORK/nodes.json" || die "could not read the nodes"
jq -e '(.items | length) > 0 and all(.items[]; .status.nodeInfo.architecture == "arm64")' "$WORK/nodes.json" >/dev/null ||
  die "a node here is not arm64, so executed_under: rosetta-on-arm64 would not be true of this run"
kc --request-timeout=15s -n plane-dev get pods -o json >"$WORK/pods.json" || die "could not read the pods in plane-dev"

# Whether the smoke replaced the worker is its own to say. Without that, a young worker is just a young container.
worker_replaced="$(jq -r '[.steps[] | select(.name == "worker-negative-control" and .status == "PASS") | .data.worker_replaced == true] | any' "$SMOKE")"
jq -n --slurpfile entries "$WORK/entries.json" --slurpfile pods "$WORK/pods.json" \
  --arg began "$SMOKE_STARTED" --arg ended "$SMOKE_FINISHED" --argjson worker_replaced "$worker_replaced" '
  def digest_in: (. // "") | (capture("(?<d>sha256:[a-f0-9]{64})$").d // null);
  def repository_in: sub("@.*$"; "") | sub(":[^/]*$"; "");
  [$pods[0].items[]
   | select(.metadata.deletionTimestamp == null and .status.phase == "Running")
   | . as $pod
   | (.status.containerStatuses // [])[]
   | . as $status
   | ([$pod.spec.containers[] | select(.name == $status.name) | .image] | first // "") as $image
   | {pod: $pod.metadata.name, container: .name, ready: (.ready == true), started_at: (.state.running.startedAt // ""),
      running: (.imageID | digest_in), set_to: ($image | digest_in), repository: ($image | repository_in), image: $image}] as $rows
  | [$entries[0][]
     | . as $entry
     | ($rows | map(select(.running == $entry.digest))) as $mine
     | ($rows | map(select(.repository == $entry.dev_repository and .running != $entry.digest))) as $older
     | ($mine | map(. + {replaced_by_smoke: ($worker_replaced and $entry.component == "backend" and (.pod | startswith("plane-worker-wl-")) and .started_at >= $began and .started_at < $ended)})) as $checked
     | {entry: ($entry + {containers: ($checked | map({pod, container, started_at} + (if .replaced_by_smoke then {replaced_by_smoke: true} else {} end))) | sort_by(.pod, .container)}),
        problems: (
          (if ($mine | length) == 0 then ["no container in plane-dev runs \($entry.component) at \($entry.digest), read by imageID"] else [] end)
          + ($older | map("\(.pod)/\(.container) runs \(.running // "an image with no digest"), and the overlay names \($entry.digest)"))
          + ($mine | map(select(.ready | not) | "\(.pod)/\(.container) runs \($entry.component) and is not ready"))
          + ($mine | map(select(.set_to != $entry.digest) | "\(.pod)/\(.container) is set to \(.image), and its imageID says \($entry.digest)"))
          + ($checked | map(select((.replaced_by_smoke | not) and (.started_at == "" or .started_at >= $began)) | "\(.pod)/\(.container) started at \(.started_at), not before the smoke began at \($began), so that smoke says nothing about it"))
          + (if ($mine | length) > 0 and ($checked | all(.replaced_by_smoke)) then ["no container of \($entry.component) was there when the smoke began"] else [] end)
        )}]
  | {images: map(.entry), problems: (map(.problems) | add // [])}' >"$WORK/running.json"
jq -r '.problems[]' "$WORK/running.json" >"$WORK/problems"
stop_on_problems "$WORK/problems" "plane-dev is not running what this smoke proved. Wait for any rollout to end, then run make test-e2e ENV=dev again"

# ---- What each digest is ------------------------------------------------------------------------------------------------
docker_read_problem() { # docker_read_problem <reference>
  die "Docker cannot read $1. For a private package, scripts/ci/copy-to-local-registry.sh ${GHCR_PREFIX} dev logs Docker in, and says what token it needs"
}
read_raw() { # read_raw <reference> <digest> <file>: the bytes the registry serves, which must hash to that digest
  docker buildx imagetools inspect --raw "$1" >"$3" 2>"$WORK/docker-output" || docker_read_problem "$1"
  [[ "sha256:$(sha256_of "$3")" == "$2" ]] || die "what the registry serves for $1 does not hash to that digest"
}

index_child() { # index_child <architecture>: the digest of that one linux child in $WORK/index, or nothing
  jq -r --arg architecture "$1" '[.manifests[]? | select(.platform.os == "linux" and .platform.architecture == $architecture)] | if length == 1 then .[0].digest else "" end' "$WORK/index"
}

# A person with write access could push an image to GHCR under any label. The run's log is what ties the digest to a build.
built_by_run() { # built_by_run <commit> <digest>: prints the run, or nothing
  local commit="$1" digest="$2" run run_log
  gh run list --repo "$HOSTED_REPOSITORY" --workflow images.yml --commit "$commit" --branch main --event push --status success --limit 20 \
    --json databaseId,headSha,conclusion >"$WORK/runs.json" || die "gh could not list the runs of images.yml. Is gh logged in?"
  while read -r run <&4; do
    run_log="$WORK/run-$run.log"
    if [[ ! -f "$run_log" ]]; then gh run view "$run" --repo "$HOSTED_REPOSITORY" --log >"$run_log" 2>/dev/null || continue; fi
    if grep -qF "$digest" "$run_log"; then
      printf '%s\n' "$run"
      return 0
    fi
  done 4< <(jq -r --arg commit "$commit" '.[] | select(.headSha == $commit and .conclusion == "success") | .databaseId' "$WORK/runs.json")
}

: >"$WORK/images.jsonl"
# On its own descriptor, so docker and gh in this loop cannot read the list from stdin.
while read -r row <&3; do
  kind="$(jq -r '.kind' <<<"$row")"
  component="$(jq -r '.component' <<<"$row")"
  digest="$(jq -r '.digest' <<<"$row")"
  repository="$(jq -r '.production_repository' <<<"$row")"
  reference="$repository@$digest"
  if [[ "$kind" == branded ]]; then
    read_raw "$reference" "$digest" "$WORK/manifest"
    media_type="$(jq -r 'if has("manifests") then "an index" else (.mediaType // "no media type") end' "$WORK/manifest")"
    case "$media_type" in
      application/vnd.oci.image.manifest.v1+json | application/vnd.docker.distribution.manifest.v2+json) ;;
      *) die "$reference is $media_type, not a plain manifest, so production could run other bytes than dev" ;;
    esac
    docker buildx imagetools inspect "$reference" --format '{{json .Image}}' >"$WORK/image.json" 2>"$WORK/docker-output" || docker_read_problem "$reference"
    platform="$(jq -r '"\(.os)/\(.architecture)"' "$WORK/image.json")"
    [[ "$platform" == linux/amd64 ]] || die "$reference is $platform, and production is linux/amd64"
    revision="$(jq -r '.config.Labels["org.opencontainers.image.revision"] // ""' "$WORK/image.json")"
    [[ "$revision" =~ ^[a-f0-9]{40}$ ]] || die "$reference has no revision label: '$revision'"
    git merge-base --is-ancestor "$revision" refs/remotes/origin/main 2>/dev/null || die "$reference says it was built from $revision, which is not on origin's main"
    run="$(built_by_run "$revision" "$digest")"
    [[ -n "$run" ]] || die "no successful images.yml push run of $revision names $digest in its log, so nothing says CI built $reference"
    log "$component: plain linux/amd64 on GHCR, built from ${revision:0:12} by run $run"
    jq -c --arg platform "$platform" --arg media_type "$media_type" --arg revision "$revision" --argjson run "$run" \
      '. + {platform: $platform, media_type: $media_type, revision: $revision, built_by_run: $run}' <<<"$row" >>"$WORK/images.jsonl"
  else
    read_raw "$reference" "$digest" "$WORK/index"
    arm64="$(index_child arm64)"
    amd64="$(index_child amd64)"
    [[ -n "$arm64" && -n "$amd64" ]] || die "$reference is not an index with one linux/arm64 and one linux/amd64 child, so nothing could say what dev ran and what production would"
    log "$component: index, dev ran its linux/arm64 child, production runs its linux/amd64 child"
    jq -c --arg arm64 "$arm64" --arg amd64 "$amd64" \
      '. + {dev_ran: {platform: "linux/arm64", digest: $arm64}, production_runs: {platform: "linux/amd64", digest: $amd64}}' <<<"$row" >>"$WORK/images.jsonl"
  fi
done 3< <(jq -c '.images[]' "$WORK/running.json")

# ---- The record ---------------------------------------------------------------------------------------------------------
jq -r '.images[] | .production_repository + "@" + .digest' "$WORK/running.json" | sort -u >"$WORK/set"
SET_HASH="$(sha256_of "$WORK/set")"
RECORD="$WORK/$SET_HASH.json"
jq -n -S --slurpfile images "$WORK/images.jsonl" --slurpfile smoke "$PUBLISHED" --arg set_hash "$SET_HASH" --arg argo_revision "$ARGO_REVISION" \
  --arg recorded_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg published_path "$PUBLISHED" --arg smoke_sha256 "$(sha256_of "$PUBLISHED")" '
  {schema: 1, set_hash: $set_hash, environment: "plane-dev", executed_under: "rosetta-on-arm64", recorded_at: $recorded_at, argo_revision: $argo_revision,
   smoke: {published_path: $published_path, sha256: $smoke_sha256, run_id: $smoke[0].run_id, result: $smoke[0].result,
           branding_overlay: ([$smoke[0].steps[] | select(.name == "branding-overlay") | .status] | first),
           started_at: $smoke[0].started_at, finished_at: $smoke[0].finished_at},
   images: ($images | sort_by(.component))}' >"$RECORD"

log "Signing with $KEY"
ssh-keygen -Y sign -f "$KEY" -n "$SIGNER" "$RECORD" || die "ssh-keygen could not sign, so nothing was written"
ssh-keygen -Y verify -f "$SIGNERS" -I "$SIGNER" -n "$SIGNER" -s "$RECORD.sig" <"$RECORD" >/dev/null ||
  die "$KEY made a signature $SIGNERS does not accept, so the check would refuse it, and nothing was written"

mkdir -p "$PROMOTIONS_DIR"
TARGET="$PROMOTIONS_DIR/$SET_HASH.json"
# The signature first: a record with no signature is refused, and a signature with no record names nothing.
mv "$RECORD.sig" "$TARGET.sig"
mv "$RECORD" "$TARGET"
ok "wrote $TARGET and its signature"
cat <<NEXT
Next:
  git switch -c evidence/${SET_HASH:0:12}
  git add $TARGET $TARGET.sig $PUBLISHED
  git commit -m 'evidence: plane-dev ran set ${SET_HASH:0:12}'
  git push -u origin HEAD
  gh pr create --fill
Once Lint, Manifests and Security pass on that pull request:
  gh pr merge --merge
  git switch main && git pull --ff-only
  gh workflow run promote-plane-prod.yml --repo $HOSTED_REPOSITORY -f set_hash=$SET_HASH
NEXT
