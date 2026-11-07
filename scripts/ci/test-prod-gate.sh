#!/usr/bin/env bash
# Real runs of the exact-digest gate: scripts/ci/check-prod-evidence.sh, promote-prod.sh, publish-release.sh, check-deploy-branch.sh and
# scripts/record-dev-evidence.sh, in a throwaway Git repository with its own origin and a throwaway signing key. The signatures,
# Git history, pushes and kustomize are real. kubectl, docker, gh and curl are stubs, and so is scripts/render.sh, which here
# only runs kustomize, because the fixture's overlay has no chart. It runs what is on disk, as the scripts' own commit in the
# fixture. Nothing here can reach a cluster, a registry, GitHub or the real signing key: HOME belongs to the run.
#
#   scripts/ci/test-prod-gate.sh               every scenario: 12 seconds in an ubuntu:24.04 container, about three minutes
#                                              on macOS, where each of its thousands of processes costs more
#   scripts/ci/test-prod-gate.sh rollback      only the scenarios whose name contains "rollback"
#   scripts/ci/test-prod-gate.sh --mutations   take each check away in turn, and require its scenario to go red. About ten
#                                              minutes, so make ci does not run it
#   scripts/ci/test-prod-gate.sh --mutations arm64   only the mutations whose scenario's name contains "arm64"
#
# GATE_SCRIPTS_FROM and GATE_EXACT are how --mutations asks this for one scenario over a changed copy. They reach only this file.
#
# It proves the scripts do what they say given these answers, and nothing about GHCR, GitHub or a real cluster.
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

"$ROOT/scripts/install-tools.sh" kustomize yq >/dev/null

# Nothing from a job's own environment, or from the laptop's Git and SSH setup, reaches a scenario.
unset GITHUB_STEP_SUMMARY GITHUB_OUTPUT GITHUB_TOKEN GH_TOKEN GITHUB_RUN_ID GITHUB_RUN_ATTEMPT GITHUB_REPOSITORY GITHUB_ACTOR GITHUB_SERVER_URL SSH_AUTH_SOCK CI
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

MUTATING=no
if [[ "${1:-}" == --mutations ]]; then
  MUTATING=yes
  shift
fi
FILTER="${1:-}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

NULL_DIGEST="sha256:$(printf '0%.0s' {1..64})"

# ---- Mutations --------------------------------------------------------------------------------------------------------
# mutation <scenario> <file> <exact text> <what replaces it>: each text must appear exactly once, so this list cannot go
# stale in silence. Each one takes a single check away, and that check's scenario has to notice.
CHECK=scripts/ci/check-prod-evidence.sh
PROMOTE=scripts/ci/promote-prod.sh
PUBLISH=scripts/ci/publish-release.sh
RECORD=scripts/record-dev-evidence.sh
DEPLOY_BRANCH_CHECK=scripts/ci/check-deploy-branch.sh
list_mutations() {
  mutation check-refuses-tampered-json "$CHECK" 'refuse "the signature on' 'true "the signature on'
  mutation check-refuses-wrong-signer "$CHECK" 'refuse "the signature on' 'true "the signature on'
  mutation check-refuses-wrong-namespace "$CHECK" '-I "$SIGNER" -n "$SIGNER" -s' '-I "$SIGNER" -n other-purpose -s'
  mutation check-refuses-another-principal "$CHECK" '-I "$SIGNER" -n "$SIGNER" -s' '-I someone-else -n "$SIGNER" -s'
  mutation check-refuses-signers-only-in-the-tree "$CHECK" 'at_commit "$SIGNERS" >"$WORK/signers"' 'cat "$SIGNERS" >"$WORK/signers"'
  mutation check-reads-evidence-from-the-commit "$CHECK" 'at_commit "$EVIDENCE" >"$WORK/evidence.json"' 'cat "$EVIDENCE" >"$WORK/evidence.json"'
  mutation check-reads-the-render-from-the-commit "$CHECK" 'at_commit "$MANIFESTS" >"$WORK/manifests.yaml"' 'cat "$MANIFESTS" >"$WORK/manifests.yaml"'
  mutation check-refuses-an-edited-check "$CHECK" 'refuse "$SCRIPT is not what commit' 'true "$SCRIPT is not what commit'
  mutation check-refuses-an-argument "$CHECK" 'refuse "this takes no arguments' 'true "this takes no arguments'
  mutation check-ignores-gits-environment "$CHECK" 'unset $(command -p git rev-parse --local-env-vars)' ':'
  mutation check-refuses-shallow-history "$CHECK" 'refuse "shallow clone' 'true "shallow clone'
  mutation check-refuses-failed-smoke "$CHECK" '(if $e.smoke.result != "PASS" then' '(if false then'
  mutation check-refuses-branding-not-pass "$CHECK" '(if $e.smoke.branding_overlay != "PASS" then' '(if false then'
  mutation check-refuses-stale-smoke "$CHECK" '$started >= $ended else $started >= $began end' '$started >= $ended else false end'
  mutation check-refuses-a-container-started-with-the-smoke "$CHECK" '$started >= $ended else $started >= $began end' '$started >= $ended else $started > $began end'
  mutation check-refuses-a-replaced-container-beyond-the-worker "$CHECK" 'any(.replaced_by_smoke == true) and $i.component != "backend"' 'false'
  mutation check-refuses-only-replaced-containers "$CHECK" '($i.containers // []) | all(.replaced_by_smoke == true)' 'false'
  mutation check-refuses-a-replacement-after-the-smoke "$CHECK" 'then $started >= $ended else' 'then false else'
  mutation check-refuses-a-set-covering-some-images "$CHECK" 'refuse "$EVIDENCE does not cover exactly' 'true "$EVIDENCE does not cover exactly'
  mutation check-refuses-a-digest-not-in-the-set "$CHECK" 'refuse "$EVIDENCE is not in this commit' 'exit 0; true "$EVIDENCE is not in this commit'
  mutation check-refuses-a-mix-of-two-sets "$CHECK" 'refuse "$EVIDENCE is not in this commit' 'exit 0; true "$EVIDENCE is not in this commit'
  mutation check-refuses-a-digest-outside-the-images "$CHECK" 'refuse "$MANIFESTS holds a digest outside' 'true "$MANIFESTS holds a digest outside'
  mutation check-refuses-an-image-with-no-digest "$CHECK" 'refuse "$MANIFESTS names an image that is not pinned' 'continue; true "$MANIFESTS names an image that is not pinned'
  mutation check-refuses-null-digest-with-application "$CHECK" 'refuse "$PLANE_APPLICATION exists and $MANIFESTS still names' 'true "$PLANE_APPLICATION exists and $MANIFESTS still names'
  mutation check-refuses-half-null "$CHECK" 'refuse "$MANIFESTS names the null digest beside' 'true "$MANIFESTS names the null digest beside'
  mutation check-refuses-an-application-with-no-render "$CHECK" 'refuse "$PLANE_APPLICATION exists and $MANIFESTS does not' 'true "$PLANE_APPLICATION exists and $MANIFESTS does not'
  mutation check-refuses-another-application-reading-the-render "$CHECK" 'refuse "$file also reads the Plane render' 'true "$file also reads the Plane render'
  mutation check-refuses-application-with-another-path "$CHECK" '(if $application.spec.source.path != $path then' '(if false then'
  mutation check-refuses-application-on-another-branch "$CHECK" '(if $application.spec.source.targetRevision != $branch then' '(if false then'
  mutation check-refuses-application-from-another-repository "$CHECK" '(if $application.spec.source.repoURL != $repository then' '(if false then'
  mutation check-refuses-application-with-a-second-source "$CHECK" '(if $application.spec.sources != null then' '(if false then'
  mutation check-refuses-a-stray-file-beside-the-render "$CHECK" 'refuse "Argo CD reads all of' 'true "Argo CD reads all of'
  mutation check-refuses-a-wayline-image-elsewhere "$CHECK" 'refuse "only $MANIFESTS may name a Wayline image' 'true "only $MANIFESTS may name a Wayline image'
  mutation check-refuses-no-containers "$CHECK" '(if ($i.containers | type) != "array" or ($i.containers | length) == 0 then' '(if false then'
  mutation check-refuses-arm64-entry "$CHECK" '(if $i.platform != "linux/amd64" then' '(if false then'
  mutation check-refuses-index-entry "$CHECK" '(if ($i.media_type | plain) | not then' '(if false then'
  mutation check-refuses-arm64-production-child "$CHECK" '(if $i.production_runs.platform != "linux/amd64" or' '(if'
  mutation check-refuses-an-index-with-no-dev-child "$CHECK" '(if $i.dev_ran.platform != "linux/arm64" or (($i.dev_ran.digest | digest) | not) then' '(if false then'
  mutation check-refuses-wayline-recorded-as-upstream "$CHECK" '(if ($i.production_repository | startswith($ghcr)) then' '(if false then'
  mutation check-refuses-another-execution-claim "$CHECK" '(if $e.executed_under != "rosetta-on-arm64" then' '(if false then'
  mutation check-refuses-another-environment "$CHECK" '(if $e.environment != "plane-dev" then' '(if false then'
  mutation check-refuses-a-wrong-set-hash-inside "$CHECK" '(if $e.set_hash != $set_hash then' '(if false then'
  mutation check-refuses-a-smoke-file-that-changed "$CHECK" 'refuse "$smoke_path is not the file' 'true "$smoke_path is not the file'
  mutation check-refuses-a-missing-smoke-file "$CHECK" 'refuse "$EVIDENCE names $smoke_path, which is not in this commit' 'true "$EVIDENCE names $smoke_path, which is not in this commit'
  mutation check-refuses-a-published-smoke-that-failed "$CHECK" '(if $published[0].result != "PASS" then' '(if false then'
  mutation check-refuses-a-published-smoke-of-other-digests "$CHECK" '(if (step("branding-overlay").data.branded // {}) != $branded then' '(if false then'
  mutation check-refuses-other-smoke-times "$CHECK" '(if $published[0].started_at != $e.smoke.started_at or' '(if'
  mutation check-refuses-argo-revision-off-history "$CHECK" 'refuse "$EVIDENCE says dev ran commit' 'true "$EVIDENCE says dev ran commit'
  mutation check-refuses-a-dev-overlay-that-disagrees "$CHECK" 'refuse "$EVIDENCE says dev ran these at' 'true "$EVIDENCE says dev ran these at'
  mutation check-refuses-image-revision-off-history "$CHECK" 'refuse "$EVIDENCE says an image was built from' 'true "$EVIDENCE says an image was built from'
  mutation check-status-3-from-a-tool-is-a-refusal "$CHECK" 'status=1
  fi' 'true
  fi'
  mutation check-passes "$CHECK" 'printf '"'"'set_hash=%s\n'"'"' "$SET_HASH"' ':'
  mutation check-not-promoted "$CHECK" 'not_yet_promoted "no Application reads' 'refuse "no Application reads'
  mutation check-not-promoted-all-null "$CHECK" 'not_yet_promoted "no Application reads' 'refuse "no Application reads'
  mutation check-nothing-there-yet "$CHECK" 'not_yet_promoted "this commit has no' 'refuse "this commit has no'
  mutation check-ignores-signers-in-the-tree "$CHECK" 'at_commit "$SIGNERS" >"$WORK/signers"' 'cat "$SIGNERS" >"$WORK/signers"'
  mutation check-refuses-a-check-not-in-the-commit "$CHECK" 'refuse "$SELF is not in commit' 'true "$SELF is not in commit'
  mutation check-refuses-a-hidden-image-field "$CHECK" '.. | objects | select(has("image"))' '.spec?.template?.spec?.containers[]?'
  mutation check-refuses-a-jsonnet-application "$CHECK" 'refuse "$file: Argo CD would read it' 'continue; true "$file: Argo CD would read it'
  mutation check-refuses-a-published-branding-skip "$CHECK" '(if (step("branding-overlay").status) != "PASS" then' '(if false then'
  mutation check-refuses-a-published-smoke-of-another-mode "$CHECK" '(if $published[0].tool != "tests/e2e/smoke.py" or $published[0].environment != "dev" or $published[0].mode != "full" then' '(if false then'
  mutation check-refuses-a-revision-with-a-bad-shape "$CHECK" '(if ($i.revision | hex40) | not then' '(if false then'
  mutation check-refuses-a-smaller-set-under-its-own-name "$CHECK" 'refuse "$EVIDENCE is not in this commit' 'exit 0; true "$EVIDENCE is not in this commit'
  mutation check-refuses-a-smoke-path-outside-runs "$CHECK" 'refuse "$EVIDENCE names no published smoke' 'true "$EVIDENCE names no published smoke'
  mutation check-refuses-a-time-it-cannot-read "$CHECK" '($started == null or (if' '(false or (if'
  mutation check-refuses-an-application-it-cannot-read "$CHECK" 'refuse "$file is not YAML' 'continue; true "$file is not YAML'
  mutation check-refuses-an-image-in-a-job "$CHECK" 'refuse "$EVIDENCE is not in this commit' 'exit 0; true "$EVIDENCE is not in this commit'
  mutation check-refuses-an-unknown-kind "$CHECK" '"is of kind \($i.kind), which this does not know"' 'empty'
  mutation check-refuses-another-file-named-plane-prod "$CHECK" '.metadata.name == "plane-prod" or ' ''
  mutation check-refuses-another-repository "$CHECK" 'refuse "$EVIDENCE is not in this commit' 'exit 0; true "$EVIDENCE is not in this commit'
  mutation check-refuses-another-schema "$CHECK" '(if $e.schema != 1 then' '(if false then'
  mutation check-refuses-application-of-another-namespace "$CHECK" '(if $application.spec.destination.namespace != "plane-prod" then' '(if false then'
  mutation check-refuses-evidence-it-cannot-read "$CHECK" 'printf '"'"'refused: this check stopped' 'true '"'"'refused: this check stopped'
  mutation check-refuses-missing-signature "$CHECK" 'refuse "$EVIDENCE has no signature' 'true "$EVIDENCE has no signature'
  mutation check-refuses-no-images "$CHECK" 'refuse "$MANIFESTS names no image' 'exit 0; true "$MANIFESTS names no image'
  mutation check-refuses-no-signers-file "$CHECK" 'refuse "$SIGNERS is not in this commit' 'true "$SIGNERS is not in this commit'
  mutation check-refuses-null-digest-in-one-image "$CHECK" 'refuse "$PLANE_APPLICATION exists and $MANIFESTS still names' 'true "$PLANE_APPLICATION exists and $MANIFESTS still names'
  mutation check-refuses-real-digests-with-no-evidence-and-no-application "$CHECK" 'if [[ -n "$null_references" ]]; then' 'if [[ "$HAS_PLANE_APPLICATION" == no ]]; then not_yet_promoted "no Application"; fi; if [[ -n "$null_references" ]]; then'
  mutation check-refuses-a-symlink-in-applications "$CHECK" 'refuse "$file is a symlink or a submodule' 'true "$file is a symlink or a submodule'
  mutation check-refuses-applications-as-a-symlink "$CHECK" 'refuse "$file is a symlink or a submodule' 'true "$file is a symlink or a submodule'
  mutation check-refuses-a-symlink-before-it-is-promoted "$CHECK" 'refuse "$file is a symlink or a submodule' 'true "$file is a symlink or a submodule'
  mutation check-refuses-a-submodule "$CHECK" 'refuse "$file is a symlink or a submodule' 'true "$file is a symlink or a submodule'
  mutation check-refuses-an-argocd-source-file "$CHECK" 'refuse "$file would be merged' 'true "$file would be merged'
  mutation check-refuses-a-kustomization-by-another-name "$CHECK" 'refuse "$file makes Argo CD build' 'true "$file makes Argo CD build'
  mutation check-refuses-jsonnet-outside-applications "$CHECK" 'refuse "$file would be evaluated by Argo CD' 'true "$file would be evaluated by Argo CD'
  mutation check-refuses-a-file-it-cannot-parse "$CHECK" 'refuse "$file cannot be parsed' 'true "$file cannot be parsed'
  mutation check-refuses-an-application-in-a-new-folder "$CHECK" 'refuse "$file holds an Application, and only' 'true "$file holds an Application, and only'
  mutation check-refuses-an-application-in-values "$CHECK" 'refuse "$file holds an Application, and only' 'true "$file holds an Application, and only'
  mutation check-refuses-something-else-in-applications "$CHECK" 'refuse "$file holds something other than an Application' 'true "$file holds something other than an Application'
  mutation check-refuses-a-list-in-applications "$CHECK" 'refuse "$file holds something other than an Application' 'true "$file holds something other than an Application'
  mutation check-refuses-overrides-on-the-application "$CHECK" '(if (($application.spec.source // {}) | keys) != ["path", "repoURL", "targetRevision"] then' '(if false then'
  mutation check-finds-a-quoted-name-reading-the-render "$CHECK" 'done 3< <(git ls-tree -r -z --name-only "$COMMIT" -- "$APPLICATIONS/")' 'done 3< <(git ls-tree -r --name-only "$COMMIT" -- "$APPLICATIONS/" | tr "\n" "\0")'
  mutation check-refuses-tracked-tools "$CHECK" 'refuse "commit $COMMIT tracks files under .tools' 'true "commit $COMMIT tracks files under .tools'
  mutation promote-refuses-what-the-check-refuses "$PROMOTE" 'die "check-prod-evidence.sh answered' 'true "check-prod-evidence.sh answered'
  mutation promote-refuses-a-bad-hash "$PROMOTE" 'die "a set hash is 64' 'true "a set hash is 64'
  mutation promote-refuses-a-dirty-overlay "$PROMOTE" 'die "uncommitted changes under' 'true "uncommitted changes under'
  mutation promote-first-promotion "$PROMOTE" 'cp "$TEMPLATE" "$APPLICATION"' ':'
  mutation promote-second-promotion "$PROMOTE" 'if [[ ! -e "$APPLICATION" ]]; then' 'if true; then'
  mutation promote-already-holds-the-set "$PROMOTE" 'if ! grep -qxF "$name"$'"'"'\t'"'"'"$repository"$'"'"'\t'"'"'"$tag"$'"'"'\t'"'"'"$digest" "$WORK/overlay.tsv"; then' 'if true; then'
  mutation promote-first-refusal-leaves-no-application "$PROMOTE" 'restore_from_head "${PATHS[@]}" ||' 'true ||'
  mutation promote-refuses-a-digest-field-it-cannot-use "$PROMOTE" 'die "$EVIDENCE names an image this cannot use' 'true "$EVIDENCE names an image this cannot use'
  mutation promote-refuses-an-unknown-set "$PROMOTE" 'die "HEAD has no $EVIDENCE' 'true "HEAD has no $EVIDENCE'
  mutation promote-refuses-uncommitted-evidence "$PROMOTE" 'die "HEAD has no $EVIDENCE' 'true "HEAD has no $EVIDENCE'
  mutation publish-refuses-going-backwards "$PUBLISH" 'die "$BRANCH was released from' 'true "$BRANCH was released from'
  mutation publish-later-release-has-the-tip-as-parent "$PUBLISH" '|| unchanged=no' '|| true'
  mutation publish-no-op-when-the-trees-match "$PUBLISH" 'if [[ "$unchanged" == yes ]]; then' 'if false; then'
  mutation publish-rerun-of-the-same-commit-changes-nothing "$PUBLISH" 'if [[ "$unchanged" == yes ]]; then' 'if false; then'
  mutation publish-refuses-failed-evidence "$PUBLISH" 'die "check-prod-evidence.sh refused' 'true "check-prod-evidence.sh refused'
  mutation publish-refuses-a-digest-with-no-evidence-on-the-first-release "$PUBLISH" 'die "check-prod-evidence.sh refused' 'true "check-prod-evidence.sh refused'
  mutation publish-keeps-tokens-off-the-command-line "$PUBLISH" 'curl -fsS --retry 3 -K - "https://ghcr.io/token' 'curl -fsS --retry 3 -K - -u "x:$GITHUB_TOKEN" "https://ghcr.io/token'
  mutation publish-needs-a-run "$PUBLISH" 'die "this is the release-plane-prod job' 'true "this is the release-plane-prod job'
  mutation publish-needs-a-token-to-read-ghcr "$PUBLISH" 'die "reading GHCR takes GITHUB_TOKEN' 'true "reading GHCR takes GITHUB_TOKEN'
  mutation publish-no-cluster-tree "$PUBLISH" 'if ! in_commit "$CLUSTER_TREE"; then' 'if false; then'
  mutation publish-writes-the-job-summary "$PUBLISH" 'printf '"'"'%s\n'"'"' "$1" >>"$GITHUB_STEP_SUMMARY"' ':'
  mutation publish-refuses-off-main "$PUBLISH" 'die "$COMMIT is not on origin' 'true "$COMMIT is not on origin'
  mutation publish-refuses-what-ghcr-lacks "$PUBLISH" 'die "GHCR does not serve $repository@$digest"' 'return 0'
  mutation publish-refuses-an-index-on-ghcr "$PUBLISH" 'die "$repository@$digest is not a plain image manifest' 'true "$repository@$digest is not a plain image manifest'
  mutation publish-refuses-arm64-on-ghcr "$PUBLISH" 'die "$repository@$digest is for $found' 'true "$repository@$digest is for $found'
  mutation publish-refuses-bytes-that-do-not-hash "$PUBLISH" 'die "what GHCR served for $repository@$digest does not hash' 'true "what GHCR served for $repository@$digest does not hash'
  mutation publish-refuses-a-config-that-does-not-hash "$PUBLISH" 'die "what GHCR served as the config' 'true "what GHCR served as the config'
  mutation publish-refuses-another-revision-on-ghcr "$PUBLISH" 'die "$repository@$digest says it was built from' 'true "$repository@$digest says it was built from'
  mutation publish-refuses-foreign-files-on-the-branch "$PUBLISH" 'die "$BRANCH at $TIP holds more than' 'true "$BRANCH at $TIP holds more than'
  mutation publish-refuses-a-tip-with-no-release "$PUBLISH" 'die "$BRANCH at $TIP has no RELEASE.json' 'true "$BRANCH at $TIP has no RELEASE.json'
  mutation publish-refuses-an-unreadable-origin "$PUBLISH" 'die "could not read origin' 'true "could not read origin'
  mutation publish-holds-only-the-hosted-trees "$PUBLISH" 'git update-index --add --cacheinfo "100644,' 'git read-tree --prefix=.github/ "$COMMIT:.github"; git update-index --add --cacheinfo "100644,'
  mutation publish-later-release-has-the-tip-as-parent "$PUBLISH" 'PARENTS=(-p "$TIP")' 'PARENTS=()'
  mutation publish-refuses-a-branch-that-moved "$PUBLISH" '"$RELEASE:refs/heads/$BRANCH"' '"+$RELEASE:refs/heads/$BRANCH"'
  mutation publish-platform-only "$PUBLISH" "export GIT_AUTHOR_NAME='github-actions[bot]' GIT_AUTHOR_EMAIL='41898282+github-actions[bot]@users.noreply.github.com'" ':'
  mutation promote-first-promotion "$PROMOTE" 'export GIT_AUTHOR_NAME=promote-prod GIT_AUTHOR_EMAIL=promote-prod@invalid GIT_COMMITTER_NAME=promote-prod GIT_COMMITTER_EMAIL=promote-prod@invalid' ':'
  mutation publish-refuses-tracked-tools "$PUBLISH" 'if [[ -n "$tracked_tools" ]]; then' 'if false; then'
  mutation publish-refuses-a-branch-pushed-by-hand "$PUBLISH" 'die "$BRANCH at $TIP says it came from' 'true "$BRANCH at $TIP says it came from'
  mutation publish-refuses-going-back-to-no-set "$PUBLISH" 'if [[ "$check_status" -eq 3 && -n "$released_set" ]]; then' 'if false; then'
  mutation deploy-branch-check-finds-a-hand-push "$DEPLOY_BRANCH_CHECK" 'die "$BRANCH at $TIP says it came from' 'true "$BRANCH at $TIP says it came from'
  mutation deploy-branch-check-finds-foreign-files "$DEPLOY_BRANCH_CHECK" 'die "$BRANCH at $TIP holds more than' 'true "$BRANCH at $TIP holds more than'
  mutation deploy-branch-check-finds-no-release-file "$DEPLOY_BRANCH_CHECK" 'die "$BRANCH at $TIP has no RELEASE.json' 'true "$BRANCH at $TIP has no RELEASE.json'
  mutation deploy-branch-check-finds-a-commit-off-main "$DEPLOY_BRANCH_CHECK" 'die "$BRANCH at $TIP says it came from $recorded, which' 'true "$BRANCH at $TIP says it came from $recorded, which'
  mutation deploy-branch-check-says-nothing-when-it-cannot-read "$DEPLOY_BRANCH_CHECK" 'unreadable "could not read origin"' 'true "could not read origin"'
  mutation record-newest-smoke-failed "$RECORD" '(if .result != "PASS" then' '(if false then'
  mutation record-passes-and-the-check-accepts-it "$RECORD" 'executed_under: "rosetta-on-arm64", ' ''
  mutation record-no-key "$RECORD" 'die "$KEY does not exist' 'true "$KEY does not exist'
  mutation record-no-revision-label "$RECORD" 'die "$reference has no revision label' 'true "$reference has no revision label'
  mutation record-no-smoke-at-all "$RECORD" 'die "no dev smoke' 'true "no dev smoke'
  mutation record-only-the-replaced-worker-runs-backend "$RECORD" '(if ($mine | length) > 0 and ($checked | all(.replaced_by_smoke)) then' '(if false then'
  mutation record-overlay-has-a-null-digest "$RECORD" 'die "$DEV_OVERLAY at $ARGO_REVISION holds an image with no real digest' 'true "$DEV_OVERLAY at $ARGO_REVISION holds an image with no real digest'
  mutation record-refuses-a-smoke-it-cannot-read "$RECORD" 'die "$file is not JSON' 'continue; true "$file is not JSON'
  mutation record-worker-started-after-the-smoke "$RECORD" ' and .started_at < $ended' ''
  mutation record-newest-smoke-by-what-it-says "$RECORD" 'if [[ "$started" > "$SMOKE_STARTED" ]]; then' 'if true; then'
  mutation record-branding-overlay-skipped "$RECORD" '(if step("branding-overlay").status != "PASS" then' '(if false then'
  mutation record-a-branded-image-skipped "$RECORD" 'if step("branding-" + $image).status != "PASS" then' 'if false then'
  mutation record-smoke-in-verify-mode "$RECORD" '(if .mode != "full" then' '(if false then'
  mutation record-smoke-not-published "$RECORD" 'die "$PUBLISHED does not exist' 'true "$PUBLISHED does not exist'
  mutation record-published-copy-differs "$RECORD" 'die "$PUBLISHED does not say what' 'true "$PUBLISHED does not say what'
  mutation record-argo-not-synced "$RECORD" 'die "Application plane-dev is $status' 'true "Application plane-dev is $status'
  mutation record-argo-revision-off-main "$RECORD" 'die "plane-dev is at $ARGO_REVISION, which is not on' 'true "plane-dev is at $ARGO_REVISION, which is not on'
  mutation record-smoke-of-other-digests "$RECORD" 'die "the newest smoke checked other branded digests' 'true "the newest smoke checked other branded digests'
  mutation record-digest-not-running "$RECORD" '(if ($mine | length) == 0 then' '(if false then'
  mutation record-image-id-is-what-counts "$RECORD" '.running == $entry.digest' '.set_to == $entry.digest'
  mutation record-container-not-ready "$RECORD" 'map(select(.ready | not)' 'map(select(false)'
  mutation record-container-started-during-smoke "$RECORD" 'select((.replaced_by_smoke | not) and (.started_at == "" or .started_at >= $began))' 'select(false)'
  mutation record-young-worker-with-no-negative-control "$RECORD" '($worker_replaced and $entry.component == "backend"' '($entry.component == "backend"'
  mutation record-older-digest-still-running "$RECORD" '($older | map(' '([] | map('
  mutation record-ignores-a-pod-on-its-way-out "$RECORD" 'select(.metadata.deletionTimestamp == null and .status.phase == "Running")' 'select(.status.phase == "Running")'
  mutation record-ignores-a-finished-pod "$RECORD" 'select(.metadata.deletionTimestamp == null and .status.phase == "Running")' 'select(.metadata.deletionTimestamp == null)'
  mutation record-node-not-arm64 "$RECORD" 'die "a node here is not arm64' 'true "a node here is not arm64'
  mutation record-branded-is-an-index "$RECORD" 'die "$reference is $media_type' 'true "$reference is $media_type'
  mutation record-branded-is-arm64 "$RECORD" 'die "$reference is $platform' 'true "$reference is $platform'
  mutation record-branded-not-on-ghcr "$RECORD" 'docker_read_problem "$1"
  [[' 'true "$1"
  [['
  mutation record-bytes-do-not-hash "$RECORD" 'die "what the registry serves for' 'true "what the registry serves for'
  mutation record-revision-off-main "$RECORD" 'die "$reference says it was built from' 'true "$reference says it was built from'
  mutation record-no-successful-run "$RECORD" 'select(.headSha == $commit and .conclusion == "success")' '.'
  mutation record-digest-not-in-the-run-log "$RECORD" 'if grep -qF "$digest" "$run_log"; then' 'if true; then'
  mutation record-upstream-is-not-an-index "$RECORD" 'die "$reference is not an index' 'true "$reference is not an index'
  mutation record-key-the-signers-do-not-accept "$RECORD" 'die "$KEY made a signature' 'true "$KEY made a signature'
}

mutated=0
missed=0
mutation() { # mutation <scenario> <file> <exact text> <replacement>
  local scenario_name="$1" file="$2" from="$3" to="$4" copy="$WORK/mutated" output="$WORK/mutation-output"
  [[ -z "$FILTER" || "$scenario_name" == *"$FILTER"* ]] || return 0
  rm -rf "$copy"
  mkdir -p "$copy"
  cp -R "$ROOT/scripts" "$copy/scripts"
  python3 -I -B -c '
import sys
path, old, new = sys.argv[1:4]
text = open(path).read()
if text.count(old) != 1:
    sys.exit("appears %d times, not once: %s" % (text.count(old), old))
open(path, "w").write(text.replace(old, new))
' "$copy/$file" "$from" "$to" || die "mutation for $scenario_name no longer fits $file"
  mutated=$((mutated + 1))
  if GATE_SCRIPTS_FROM="$copy/scripts" GATE_EXACT="$scenario_name" "$0" >"$output" 2>&1; then
    warn "NOT NOTICED: $file without '$from': $scenario_name stayed green"
    missed=$((missed + 1))
  elif grep -qF "$scenario_name FAILED" "$output"; then
    ok "$scenario_name went red without: $from"
  else
    tail -n 20 "$output" >&2
    warn "NOT NOTICED: $scenario_name did not run with $file without '$from'"
    missed=$((missed + 1))
  fi
}
if [[ "$MUTATING" == yes ]]; then
  list_mutations
  [[ "$mutated" -gt 0 ]] || die "no mutation's scenario contains '$FILTER'"
  [[ "$missed" -eq 0 ]] || die "$missed of $mutated mutation(s) were not noticed"
  ok "$mutated mutation(s), and each one turned its scenario red"
  exit 0
fi

# ---- The fixture ------------------------------------------------------------------------------------------------------
SCRIPTS_FROM="${GATE_SCRIPTS_FROM:-$ROOT/scripts}"
SCENARIO_DIR="$WORK/scenario"
REPO="$SCENARIO_DIR/repo"
ORIGIN="$SCENARIO_DIR/origin.git"
TEMPLATE="$WORK/template"
export STUB="$WORK/stub"
export REGISTRY="$WORK/registry"
export HOME="$WORK/home"
SETS="$WORK/sets"
OUT="$WORK/output"
FAILURES="$WORK/failures"
OTHER_KEY="$WORK/other-key"
mkdir -p "$SCENARIO_DIR" "$STUB" "$REGISTRY" "$HOME/.ssh" "$SETS"
ssh-keygen -q -t ed25519 -N '' -C gate-test -f "$HOME/.ssh/wayline_evidence_ed25519"
ssh-keygen -q -t ed25519 -N '' -C gate-test-other -f "$OTHER_KEY"
SIGNERS_LINE="wayline-evidence $(cut -d' ' -f1-2 "$HOME/.ssh/wayline_evidence_ed25519.pub")"
GHCR=ghcr.io/bereketabera/wayline

IMAGES_TABLE="$WORK/images.tsv"
# <chart image> <component> <kind> <upstream repository, or -> <tag, or ->, as the real overlays name them
cat >"$IMAGES_TABLE" <<'TABLE'
artifacts.plane.so/makeplane/plane-frontend web branded - -
artifacts.plane.so/makeplane/plane-admin admin branded - -
artifacts.plane.so/makeplane/plane-space space branded - -
artifacts.plane.so/makeplane/plane-backend backend branded - -
artifacts.plane.so/makeplane/plane-live plane-live upstream-index docker.io/makeplane/plane-live v1.4.3
postgres postgres upstream-index docker.io/library/postgres 15.19-alpine
valkey/valkey valkey upstream-index docker.io/valkey/valkey 7.2.15-alpine
rabbitmq rabbitmq upstream-index docker.io/library/rabbitmq 3.13.7-management-alpine
docker.io/pgsty/silo silo upstream-index docker.io/pgsty/silo RELEASE.2026-10-26T00-00-00Z-distroless
TABLE

sha256_file() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
hash_of_lines() { # stdin: what scripts/ci/check-prod-evidence.sh calls the set hash
  LC_ALL=C sort -u >"$WORK/lines"
  sha256_file "$WORK/lines"
}
store() { # store <file>: into the stub registry under its own digest, and prints that digest
  local digest
  digest="sha256:$(sha256_file "$1")"
  cp "$1" "$REGISTRY/$digest"
  printf '%s' "$digest"
}
store_config() { # store_config <unique text> <architecture> <revision label>
  printf '{"architecture":"%s","os":"linux","config":{"Labels":{"org.opencontainers.image.revision":"%s"}},"note":"%s"}\n' "$2" "$3" "$1" >"$WORK/blob"
  store "$WORK/blob"
}
store_manifest() { # store_manifest <config digest>: a plain manifest, as build-images.sh pushes
  printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"%s","size":1},"layers":[]}\n' "$1" >"$WORK/blob"
  store "$WORK/blob"
}
store_index() { # store_index <unique text>: an index with linux/amd64 and linux/arm64 children, as upstream publishes
  printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","note":"%s","manifests":[{"digest":"sha256:%064d","platform":{"os":"linux","architecture":"amd64"}},{"digest":"sha256:%064d","platform":{"os":"linux","architecture":"arm64","variant":"v8"}},{"digest":"sha256:%064d","platform":{"os":"unknown","architecture":"unknown"}}]}\n' "$1" 1 2 3 >"$WORK/blob"
  store "$WORK/blob"
}
make_set() { # make_set <label> [<component> <its digest>]: real bytes for each digest, and upstream's stay the same across sets
  local label="$1" exception="${2:-}" exception_digest="${3:-}" chart component kind repository tag
  mkdir -p "$SETS/$label"
  while read -r chart component kind repository tag; do
    if [[ "$component" == "$exception" ]]; then
      printf '%s' "$exception_digest" >"$SETS/$label/$component"
    elif [[ "$kind" == branded ]]; then
      store_manifest "$(store_config "$label $component" amd64 "$SOURCE_COMMIT")" >"$SETS/$label/$component"
    else
      store_index "$component" >"$SETS/$label/$component"
    fi
  done <"$IMAGES_TABLE"
}
digest_of() { cat "$SETS/$1/$2"; } # digest_of <label> <component>

write_overlay() { # write_overlay <dev|prod> <label>, or prod null: Wayline's four at the null digest, as the real overlay starts
  local environment="$1" label="$2" chart component kind repository tag digest new_name
  {
    printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n- workloads.yaml\nimages:\n'
    while read -r chart component kind repository tag; do
      if [[ "$kind" == branded ]]; then
        new_name="$GHCR/$component"
        if [[ "$environment" == dev ]]; then new_name="localhost:5001/wayline/$component"; fi
        if [[ "$label" == null ]]; then digest="$NULL_DIGEST"; else digest="$(digest_of "$label" "$component")"; fi
      else
        new_name="$repository"
        if [[ "$label" == null ]]; then digest="$(digest_of A "$component")"; else digest="$(digest_of "$label" "$component")"; fi
      fi
      printf -- '- name: %s\n  newName: %s\n  digest: %s\n' "$chart" "$new_name" "$digest"
      if [[ "$tag" != - ]]; then printf '  newTag: %s\n' "$tag"; fi
    done <"$IMAGES_TABLE"
  } >"$REPO/helm/plane/overlays/$environment/kustomization.yaml"
}
write_workloads() { # write_workloads <overlay directory>: one Deployment an image, and the Job the real overlay has beside them
  local chart component kind repository tag
  {
    while read -r chart component kind repository tag; do
      printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: %s\nspec:\n  selector:\n    matchLabels: {app: %s}\n  template:\n    metadata:\n      labels: {app: %s}\n    spec:\n      containers:\n      - name: main\n        image: %s\n---\n' "$component" "$component" "$component" "$chart"
    done <"$IMAGES_TABLE"
    printf 'apiVersion: batch/v1\nkind: Job\nmetadata:\n  name: predeploy-dump\nspec:\n  template:\n    spec:\n      restartPolicy: Never\n      containers:\n      - name: dump\n        image: postgres\n'
  } >"$1/workloads.yaml"
}
render_prod() { (cd "$REPO" && ./scripts/render.sh --env prod); }
as_someone() { GIT_AUTHOR_NAME=gate-test GIT_AUTHOR_EMAIL=gate-test@invalid GIT_COMMITTER_NAME=gate-test GIT_COMMITTER_EMAIL=gate-test@invalid "$@"; }
commit_all() { git -C "$REPO" add -A && as_someone git -C "$REPO" commit -q -m "$1"; }
head_commit() { git -C "$REPO" rev-parse HEAD; }

# The times in a set's smoke: containers from before it, and the worker's pod replaced during it, as dev's smoke does.
smoke_times() { # smoke_times <label>: sets SMOKE_BEGAN SMOKE_ENDED BEFORE_SMOKE DURING_SMOKE AFTER_SMOKE
  case "$1" in
    B) SMOKE_BEGAN=2026-11-07T11:00:00Z; SMOKE_ENDED=2026-11-07T11:10:00Z; BEFORE_SMOKE=2026-11-07T10:30:00Z; DURING_SMOKE=2026-11-07T11:05:00Z; AFTER_SMOKE=2026-11-07T11:30:00Z ;;
    *) SMOKE_BEGAN=2026-11-07T10:00:00Z; SMOKE_ENDED=2026-11-07T10:10:00Z; BEFORE_SMOKE=2026-11-07T09:00:00Z; DURING_SMOKE=2026-11-07T10:05:00Z; AFTER_SMOKE=2026-11-07T10:30:00Z ;;
  esac
}
smoke_name() { printf 'smoke-dev-%s.json' "$1"; } # smoke_name <label>
write_smoke() { # write_smoke <label> <file>: what tests/e2e/smoke.py writes, in the parts anything here reads
  local label="$1" file="$2" branded
  smoke_times "$label"
  branded="$(for component in admin backend space web; do printf '%s %s\n' "$component" "$(digest_of "$label" "$component")"; done | jq -R -s -c 'split("\n") | map(select(. != "") | split(" ") | {key: .[0], value: .[1]}) | from_entries')"
  jq -n --arg label "$label" --arg began "$SMOKE_BEGAN" --arg ended "$SMOKE_ENDED" --argjson branded "$branded" '
    {tool: "tests/e2e/smoke.py", environment: "dev", host: "plane.dev.localhost", mode: "full", run_id: ("run-" + $label),
     started_at: $began, finished_at: $ended, result: "PASS", counts: {PASS: 7, FAIL: 0, BLOCKED: 0, SKIP: 1},
     steps: [{name: "reachable", status: "PASS", detail: "", duration_ms: 1, data: {}},
             {name: "branding-overlay", status: "PASS", detail: "", duration_ms: 1, data: {branded: $branded}},
             {name: "branding-web", status: "PASS", detail: "", duration_ms: 1, data: {}},
             {name: "branding-admin", status: "PASS", detail: "", duration_ms: 1, data: {}},
             {name: "branding-space", status: "PASS", detail: "", duration_ms: 1, data: {}},
             {name: "branding-backend", status: "PASS", detail: "", duration_ms: 1, data: {}},
             {name: "branding-fresh-install", status: "SKIP", detail: "needs a clean database", duration_ms: 1, data: {}},
             {name: "worker-negative-control", status: "PASS", detail: "", duration_ms: 1, data: {worker_replaced: true}}]}' >"$file"
}
containers_json() { # containers_json <component>, after smoke_times
  case "$1" in
    backend) jq -n -c --arg before "$BEFORE_SMOKE" --arg during "$DURING_SMOKE" '[{pod: "plane-api-wl-1", container: "main", started_at: $before}, {pod: "plane-beat-worker-wl-1", container: "main", started_at: $before}, {pod: "plane-worker-wl-2", container: "main", started_at: $during, replaced_by_smoke: true}]' ;;
    *) jq -n -c --arg pod "plane-$1-wl-1" --arg before "$BEFORE_SMOKE" '[{pod: $pod, container: "main", started_at: $before}]' ;;
  esac
}
write_evidence() { # write_evidence <label> <argo revision>: what make record-dev-evidence writes, signed, with the published smoke
  local label="$1" argo_revision="$2" chart component kind repository tag digest smoke file set_hash
  smoke="docs/evidence/runs/$(smoke_name "$label")"
  mkdir -p "$REPO/docs/evidence/runs" "$REPO/docs/evidence/promotions"
  write_smoke "$label" "$REPO/$smoke"
  smoke_times "$label"
  : >"$WORK/evidence-images"
  while read -r chart component kind repository tag; do
    digest="$(digest_of "$label" "$component")"
    if [[ "$kind" == branded ]]; then
      jq -n -c --arg chart "$chart" --arg component "$component" --arg digest "$digest" --arg ghcr "$GHCR" --arg revision "$SOURCE_COMMIT" --argjson containers "$(containers_json "$component")" '
        {kind: "branded", component: $component, chart_image: $chart, dev_repository: ("localhost:5001/wayline/" + $component), production_repository: ($ghcr + "/" + $component),
         tag: null, digest: $digest, platform: "linux/amd64", media_type: "application/vnd.oci.image.manifest.v1+json", revision: $revision, built_by_run: 1001, containers: $containers}' >>"$WORK/evidence-images"
    else
      jq -n -c --arg chart "$chart" --arg component "$component" --arg digest "$digest" --arg repository "$repository" --arg tag "$tag" \
        --arg arm64 "sha256:$(printf '%064d' 2)" --arg amd64 "sha256:$(printf '%064d' 1)" --argjson containers "$(containers_json "$component")" '
        {kind: "upstream-index", component: $component, chart_image: $chart, dev_repository: $repository, production_repository: $repository, tag: $tag, digest: $digest,
         dev_ran: {platform: "linux/arm64", digest: $arm64}, production_runs: {platform: "linux/amd64", digest: $amd64}, containers: $containers}' >>"$WORK/evidence-images"
    fi
  done <"$IMAGES_TABLE"
  set_hash="$(jq -r '.production_repository + "@" + .digest' "$WORK/evidence-images" | hash_of_lines)"
  file="$REPO/docs/evidence/promotions/$set_hash.json"
  jq -n -S --slurpfile images "$WORK/evidence-images" --arg set_hash "$set_hash" --arg argo_revision "$argo_revision" --arg path "$smoke" --arg sha256 "$(sha256_file "$REPO/$smoke")" \
    --arg label "$label" --arg began "$SMOKE_BEGAN" --arg ended "$SMOKE_ENDED" '
    {schema: 1, set_hash: $set_hash, environment: "plane-dev", executed_under: "rosetta-on-arm64", recorded_at: "2026-11-07T12:00:00Z", argo_revision: $argo_revision,
     smoke: {published_path: $path, sha256: $sha256, run_id: ("run-" + $label), result: "PASS", branding_overlay: "PASS", started_at: $began, finished_at: $ended},
     images: $images}' >"$file"
  rm -f "$file.sig"
  ssh-keygen -q -Y sign -f "$HOME/.ssh/wayline_evidence_ed25519" -n wayline-evidence "$file" 2>/dev/null
  printf '%s' "$set_hash"
}
set_hash_of() { # set_hash_of <label>
  local chart component kind repository tag
  while read -r chart component kind repository tag; do
    if [[ "$kind" == branded ]]; then printf '%s/%s@%s\n' "$GHCR" "$component" "$(digest_of "$1" "$component")"; else printf '%s@%s\n' "$repository" "$(digest_of "$1" "$component")"; fi
  done <"$IMAGES_TABLE" | hash_of_lines
}
promote_fixture() { # promote_fixture <label>: overlay, render and Application as a merged promotion leaves them
  write_overlay prod "$1"
  render_prod
  cp "$REPO/gitops/clusters/plane-prod/plane-prod-application.yaml.tmpl" "$REPO/gitops/clusters/plane-prod/applications/plane-prod.yaml"
}

write_stubs() {
  local bin="$REPO/.tools/bin" tool
  mkdir -p "$bin"
  for tool in kustomize yq; do ln -sf "$ROOT/.tools/bin/$tool" "$bin/$tool"; done

  cat >"$bin/kubectl" <<'STUB_KUBECTL'
#!/usr/bin/env bash
# Answers what record-dev-evidence.sh asks, from files. Anything else fails.
case " $* " in
  *" -n argocd get application plane-dev -o json "*) cat "$STUB/application.json" ;;
  *" -n plane-dev get pods -o json "*) cat "$STUB/pods.json" ;;
  *" get nodes -o json "*) cat "$STUB/nodes.json" ;;
  *) echo "stub kubectl: not expected: $*" >&2; exit 97 ;;
esac
STUB_KUBECTL

  cat >"$bin/docker" <<'STUB_DOCKER'
#!/usr/bin/env bash
# docker buildx imagetools inspect [--raw] <ref> [--format '{{json .Image}}'], from the stub registry. Nothing else.
[[ "$1 $2 $3" == "buildx imagetools inspect" ]] || { echo "stub docker: not expected: $*" >&2; exit 97; }
shift 3
raw=no reference=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --raw) raw=yes ;;
    --format) shift ;;
    *) reference="$1" ;;
  esac
  shift
done
blob="$REGISTRY/${reference##*@}"
[[ -f "$blob" ]] || { echo "stub docker: $reference: not found" >&2; exit 1; }
if [[ "$raw" == yes ]]; then cat "$blob"; exit 0; fi
if jq -e 'has("manifests")' "$blob" >/dev/null; then echo '{"linux/amd64":{},"linux/arm64":{}}'; exit 0; fi
cat "$REGISTRY/$(jq -r '.config.digest' "$blob")"
STUB_DOCKER

  cat >"$bin/gh" <<'STUB_GH'
#!/usr/bin/env bash
# gh run list and gh run view --log, from files. Run 1001 is a successful push run of whatever commit is asked about.
case "$1 $2" in
  "run list")
    commit=""
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == --commit ]]; then commit="$2"; fi
      shift
    done
    if [[ -e "$STUB/gh-runs.json" ]]; then cat "$STUB/gh-runs.json"; else printf '[{"databaseId":1001,"headSha":"%s","conclusion":"success"}]\n' "$commit"; fi ;;
  "run view") cat "$STUB/gh-run.log" ;;
  *) echo "stub gh: not expected: $*" >&2; exit 97 ;;
esac
STUB_GH

  cat >"$bin/curl" <<'STUB_CURL'
#!/usr/bin/env bash
# What publish-release.sh asks GHCR, from the stub registry. It keeps what it was given, to show where a token went.
out="" url="" config=no
printf '%s\n' "$*" >>"$STUB/curl-arguments"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift ;;
    -K) config=yes; shift ;;
    https://*) url="$1" ;;
  esac
  shift
done
if [[ "$config" == yes ]]; then cat >>"$STUB/curl-config"; fi
printf '%s\n' "$url" >>"$STUB/curl-urls"
if [[ -e "$STUB/curl-hook" ]]; then bash "$STUB/curl-hook"; fi
case "$url" in
  https://ghcr.io/token*) printf '{"token":"stub-bearer"}\n' ;;
  https://ghcr.io/v2/*/manifests/* | https://ghcr.io/v2/*/blobs/*)
    blob="$REGISTRY/${url##*/}"
    [[ -f "$blob" ]] || { echo "stub curl: 404 for $url" >&2; exit 22; }
    cp "$blob" "$out" ;;
  *) echo "stub curl: not expected: $url" >&2; exit 97 ;;
esac
STUB_CURL
  chmod +x "$bin/kubectl" "$bin/docker" "$bin/gh" "$bin/curl"
}

build_template() {
  local bin chart component kind repository tag
  rm -rf "$SCENARIO_DIR"
  mkdir -p "$SCENARIO_DIR"
  git init -q --bare --initial-branch=main --template= "$ORIGIN"
  git init -q --initial-branch=main --template= "$REPO"
  # As on a runner, so a script that commits has to name itself. commit_all and as_someone name theirs.
  git -C "$REPO" config user.useConfigOnly true
  # No gc of its own, in the background, under a repository each scenario deletes.
  git -C "$REPO" config gc.auto 0
  git -C "$REPO" remote add origin "$ORIGIN"
  printf '/.tools/\n/.local/\n/.build/\n' >"$REPO/.gitignore"

  mkdir -p "$REPO/scripts/ci" "$REPO/scripts/lib" "$REPO/.github/workflows" "$REPO/helm/plane/overlays/dev" "$REPO/helm/plane/overlays/prod" \
    "$REPO/gitops/clusters/plane-prod/applications" "$REPO/gitops/clusters/plane-prod/values" "$REPO/gitops/environments/prod" "$REPO/docs/evidence/promotions" "$REPO/docs/evidence/runs" "$REPO/.local/evidence-raw"
  cp "$SCRIPTS_FROM/record-dev-evidence.sh" "$REPO/scripts/"
  cp "$SCRIPTS_FROM/ci/check-prod-evidence.sh" "$SCRIPTS_FROM/ci/promote-prod.sh" "$SCRIPTS_FROM/ci/publish-release.sh" \
    "$SCRIPTS_FROM/ci/lib-release-branch.sh" "$SCRIPTS_FROM/ci/check-deploy-branch.sh" "$REPO/scripts/ci/"
  cp "$SCRIPTS_FROM/lib/common.sh" "$SCRIPTS_FROM/lib/commit-lock.sh" "$REPO/scripts/lib/"
  cat >"$REPO/scripts/render.sh" <<'STUB_RENDER'
#!/usr/bin/env bash
# The real one has a chart to render. This overlay has none, so kustomize alone sets the digests, as it does there.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$*" == "--env prod" ]] || { echo "stub render.sh: not expected: $*" >&2; exit 97; }
.tools/bin/kustomize build helm/plane/overlays/prod >gitops/environments/prod/manifests.yaml
STUB_RENDER
  chmod +x "$REPO/scripts/render.sh"
  write_stubs

  # Never read by the release, and this is what must not cross to it.
  printf 'name: anything\non: push\njobs: {}\n' >"$REPO/.github/workflows/anything.yml"
  printf '# gate-test signers\n%s\n' "$SIGNERS_LINE" >"$REPO/.github/evidence-signers"
  cat >"$REPO/gitops/clusters/plane-prod/plane-prod-application.yaml.tmpl" <<'APPLICATION'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: plane-prod
  namespace: argocd
spec:
  project: plane-prod
  destination:
    server: https://kubernetes.default.svc
    namespace: plane-prod
  source:
    repoURL: ssh://git@ssh.github.com:443/BereketAbera/plane-platform.git
    targetRevision: deploy/plane-prod
    path: gitops/environments/prod
APPLICATION
  cat >"$REPO/gitops/clusters/plane-prod/applications/traefik.yaml" <<'APPLICATION'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: traefik
  namespace: argocd
spec:
  project: platform
  destination:
    server: https://kubernetes.default.svc
    namespace: traefik
  sources:
    - repoURL: https://traefik.github.io/charts
      chart: traefik
      targetRevision: 42.3.0
      helm:
        valueFiles:
          - $values/gitops/clusters/plane-prod/values/traefik.yaml
    - repoURL: ssh://git@ssh.github.com:443/BereketAbera/plane-platform.git
      targetRevision: deploy/plane-prod
      ref: values
APPLICATION
  printf 'deployment: {}\n' >"$REPO/gitops/clusters/plane-prod/values/traefik.yaml"
  write_workloads "$REPO/helm/plane/overlays/prod"
  printf 'the source everything was built from\n' >"$REPO/source.txt"
  printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nimages: []\n' >"$REPO/helm/plane/overlays/dev/kustomization.yaml"
  printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n- workloads.yaml\n' >"$REPO/helm/plane/overlays/prod/kustomization.yaml"
  render_prod
  commit_all 'the source'
  SOURCE_COMMIT="$(head_commit)"

  make_set A
  make_set B
  write_overlay prod null
  render_prod
  commit_all 'the overlay starts at the null digest'

  write_overlay dev A
  commit_all 'dev runs set A'
  DEV_A="$(head_commit)"
  HASH_A="$(write_evidence A "$DEV_A")"
  commit_all 'evidence: dev ran set A'
  EVIDENCE_A="$(head_commit)"
  promote_fixture A
  commit_all 'promote set A'
  PROMOTED_A="$(head_commit)"

  write_overlay dev B
  commit_all 'dev runs set B'
  DEV_B="$(head_commit)"
  HASH_B="$(write_evidence B "$DEV_B")"
  commit_all 'evidence: dev ran set B'
  EVIDENCE_B="$(head_commit)"
  promote_fixture B
  commit_all 'promote set B'
  PROMOTED_B="$(head_commit)"

  [[ "$HASH_A" == "$(set_hash_of A)" && "$HASH_B" == "$(set_hash_of B)" ]] || die "the fixture's set hashes disagree with each other"
  git -C "$REPO" push -q origin "$PROMOTED_B:refs/heads/main"
  # Each scenario copies this, and a pack is one file where loose objects are hundreds.
  git -C "$REPO" gc -q
  git --git-dir="$ORIGIN" gc -q
  rm -rf "$TEMPLATE"
  cp -R "$SCENARIO_DIR" "$TEMPLATE"
}

fresh() { # fresh <commit>: a repository and origin at this commit on main, with no release branch yet
  rm -rf "$SCENARIO_DIR" "$STUB"
  cp -R "$TEMPLATE" "$SCENARIO_DIR"
  mkdir -p "$STUB"
  git -C "$REPO" reset -q --hard "$1"
  git --git-dir="$ORIGIN" update-ref refs/heads/main "$1"
  git -C "$REPO" update-ref refs/remotes/origin/main "$1"
  : >"$OUT"
}

# ---- Helpers for a scenario ---------------------------------------------------------------------------------------------
# stdin is not a terminal, so anything that asks refuses instead of waiting.
in_repo() { (cd "$REPO" && "$@") >"$OUT" 2>&1 </dev/null; }
run_status() { STATUS=0; in_repo "$@" || STATUS=$?; }
expect() { # expect <description> <command...>: one assertion inside a scenario. Its status counts, and its output does not
  local what="$1"
  shift
  if "$@" >/dev/null; then return 0; fi
  warn "  expected: $what"
  printf '%s\n' "$what" >>"$FAILURES"
}
said() { grep -qF -- "$1" "$OUT"; }
not_said() { ! grep -qF -- "$1" "$OUT"; }
equal() { [[ "$1" == "$2" ]]; }
exists() { [[ -e "$1" ]]; }
absent() { [[ ! -e "$1" ]]; }

check() { run_status ./scripts/ci/check-prod-evidence.sh; }
refused() { # refused <what it must say>: the check exits 1 at this commit, for this reason
  check
  expect "the check exits 1, and it exited $STATUS" equal "$STATUS" 1
  expect "the check says: $1" said "$1"
}
passes() { # passes [<set hash>]
  check
  expect "the check exits 0, and it exited $STATUS" equal "$STATUS" 0
  expect "the check names set ${1:-$HASH_A}" said "set_hash=${1:-$HASH_A}"
}
not_yet() {
  check
  expect "the check exits 3, and it exited $STATUS" equal "$STATUS" 3
  expect "it says plane-prod is not promoted yet" said 'not promoted yet'
  expect "it names no set" not_said 'set_hash='
}

evidence_file() { printf '%s/docs/evidence/promotions/%s.json' "$REPO" "${1:-$HASH_A}"; }
sign_file() { # sign_file <file> [<key>] [<namespace>]
  rm -f "$1.sig"
  ssh-keygen -q -Y sign -f "${2:-$HOME/.ssh/wayline_evidence_ed25519}" -n "${3:-wayline-evidence}" "$1" 2>/dev/null
}
jq_edit() { # jq_edit <file> <jq filter>
  jq -S "$2" "$1" >"$1.new"
  mv "$1.new" "$1"
}
signed_edit() { # signed_edit <jq filter> [<set hash>]: a change the owner's key really signed, committed
  jq_edit "$(evidence_file "${2:-}")" "$1"
  sign_file "$(evidence_file "${2:-}")"
  commit_all 'an edit to the evidence, signed'
}
render_file() { printf '%s/gitops/environments/prod/manifests.yaml' "$REPO"; }
replace_text() { # replace_text <file> <text> <replacement>: every occurrence, and there must be one
  python3 -I -B -c '
import sys
path, old, new = sys.argv[1:4]
text = open(path).read()
if old not in text:
    sys.exit("no match for " + old)
open(path, "w").write(text.replace(old, new))
' "$@"
}
overlay_digest() { yq -r ".images[] | select(.newName == \"$2\") | .digest" "$REPO/helm/plane/overlays/$1/kustomization.yaml"; } # overlay_digest <env> <newName>
application_file() { printf '%s/gitops/clusters/plane-prod/applications/plane-prod.yaml' "$REPO"; }

tip() { git --git-dir="$ORIGIN" rev-parse --verify --quiet refs/heads/deploy/plane-prod || true; }
tip_release() { git --git-dir="$ORIGIN" show refs/heads/deploy/plane-prod:RELEASE.json | jq -r "$1"; }
tip_files() { git --git-dir="$ORIGIN" ls-tree -r --name-only refs/heads/deploy/plane-prod; }
tip_web_digest() { git --git-dir="$ORIGIN" show refs/heads/deploy/plane-prod:gitops/environments/prod/manifests.yaml | grep -oE "$GHCR/web@sha256:[a-f0-9]{64}" | sort -u | sed 's/.*@//'; }
publish() { # publish [<run id>]
  run_status env GITHUB_RUN_ID="${1:-77}" GITHUB_RUN_ATTEMPT=1 GITHUB_REPOSITORY=BereketAbera/plane-platform GITHUB_TOKEN=stub-token GITHUB_ACTOR=tester ./scripts/ci/publish-release.sh
}
publish_ok() { publish "$@"; expect "publish exits 0, and it exited $STATUS" equal "$STATUS" 0; }
stays_put() { # stays_put <tip before> <why>
  publish
  expect "publish fails" [ "$STATUS" -ne 0 ]
  expect "the branch stays where it was" equal "$(tip)" "$1"
  expect "publish says: $2" said "$2"
}
at_commit() { # at_commit <commit>: main moves to a commit, here and on origin, as a merge would
  git -C "$REPO" reset -q --hard "$1"
  git -C "$REPO" push -q --force origin "$1:refs/heads/main"
}

# ---- Check: what passes ------------------------------------------------------------------------------------------------
check_passes() {
  passes
  (cd "$REPO" && ./scripts/ci/check-prod-evidence.sh) >"$WORK/stdout" 2>/dev/null </dev/null
  expect "stdout is that one line and nothing else" equal "$(cat "$WORK/stdout")" "set_hash=$HASH_A"
}
check_not_promoted() { not_yet; }
check_not_promoted_all_null() {
  yq -i '.images[].digest = "'"$NULL_DIGEST"'"' "$REPO/helm/plane/overlays/prod/kustomization.yaml"
  render_prod
  commit_all 'every image null'
  not_yet
}
check_nothing_there_yet() {
  git -C "$REPO" rm -rqf gitops
  commit_all 'no hosted trees'
  not_yet
}
check_older_evidenced_set_passes() {
  # Set B's commit, with set A's digests: what a rollback leaves. A is older, and no clock looks at that.
  promote_fixture A
  commit_all 'back to set A'
  passes "$HASH_A"
}

# ---- Check: the signature ----------------------------------------------------------------------------------------------
check_refuses_tampered_json() {
  jq_edit "$(evidence_file)" '.recorded_at = "2030-01-01T00:00:00Z"'
  commit_all 'edited after signing'
  refused 'does not verify'
}
check_refuses_wrong_signer() {
  sign_file "$(evidence_file)" "$OTHER_KEY"
  commit_all 'signed by someone else'
  refused 'does not verify'
}
check_refuses_wrong_namespace() {
  sign_file "$(evidence_file)" "$HOME/.ssh/wayline_evidence_ed25519" other-purpose
  commit_all 'signed for another purpose'
  refused 'does not verify'
}
check_refuses_another_principal() {
  # The right key, trusted for something else.
  printf 'someone-else %s\n' "$(cut -d' ' -f1-2 "$HOME/.ssh/wayline_evidence_ed25519.pub")" >"$REPO/.github/evidence-signers"
  commit_all 'the key, under another principal'
  refused 'does not verify'
}
check_refuses_missing_signature() {
  rm -f "$(evidence_file).sig"
  commit_all 'no signature'
  refused 'has no signature'
}
check_refuses_signers_only_in_the_tree() {
  # The evidence is signed by a key only the working tree trusts. The commit does not.
  sign_file "$(evidence_file)" "$OTHER_KEY"
  commit_all 'signed by someone else'
  printf 'wayline-evidence %s\n' "$(cut -d' ' -f1-2 "$OTHER_KEY.pub")" >"$REPO/.github/evidence-signers"
  refused 'does not verify'
}
check_ignores_signers_in_the_tree() {
  : >"$REPO/.github/evidence-signers"
  passes
}
check_refuses_no_signers_file() {
  git -C "$REPO" rm -qf .github/evidence-signers
  commit_all 'nobody may sign'
  refused 'so nobody may sign'
}

# ---- Check: the commit, not the working tree --------------------------------------------------------------------------
check_reads_evidence_from_the_commit() {
  # Tampered in the commit, whole in the tree: the commit is what would ship.
  cp "$(evidence_file)" "$WORK/whole.json"
  jq_edit "$(evidence_file)" '.recorded_at = "2030-01-01T00:00:00Z"'
  commit_all 'edited after signing'
  cp "$WORK/whole.json" "$(evidence_file)"
  refused 'does not verify'
}
check_reads_the_render_from_the_commit() {
  replace_text "$(render_file)" "$(digest_of A web)" "$(digest_of B web)"
  commit_all 'the render moves with no evidence'
  git -C "$REPO" show "$PROMOTED_A:gitops/environments/prod/manifests.yaml" >"$(render_file)"
  refused 'no evidence covers exactly'
}
check_refuses_an_edited_check() {
  printf '# an edit\n' >>"$REPO/scripts/ci/check-prod-evidence.sh"
  refused 'is not what commit'
}
check_refuses_a_check_not_in_the_commit() {
  git -C "$REPO" rm -q --cached scripts/ci/check-prod-evidence.sh
  as_someone git -C "$REPO" commit -q -m 'the check leaves the commit, and stays on disk'
  refused 'is not in commit'
}
check_refuses_an_argument() {
  run_status ./scripts/ci/check-prod-evidence.sh --skip
  expect "exit 1, and it exited $STATUS" equal "$STATUS" 1
  expect "it says so" said 'takes no arguments'
}
check_ignores_gits_environment() {
  # A repository that passes, and GIT_DIR pointing at it from one that does not.
  git clone -q "$REPO" "$WORK/passing"
  jq_edit "$(evidence_file)" '.recorded_at = "2030-01-01T00:00:00Z"'
  commit_all 'edited after signing'
  run_status env GIT_DIR="$WORK/passing/.git" GIT_WORK_TREE="$WORK/passing" ./scripts/ci/check-prod-evidence.sh
  rm -rf "$WORK/passing"
  expect "exit 1, and it exited $STATUS" equal "$STATUS" 1
  expect "it read this repository" said 'does not verify'
}
check_refuses_shallow_history() {
  git clone -q --depth 1 "file://$REPO" "$WORK/shallow"
  (cd "$WORK/shallow" && PATH="$REPO/.tools/bin:$PATH" ./scripts/ci/check-prod-evidence.sh) >"$OUT" 2>&1 </dev/null && STATUS=0 || STATUS=$?
  rm -rf "$WORK/shallow"
  expect "exit 1, and it exited $STATUS" equal "$STATUS" 1
  expect "it says so" said 'shallow clone'
}
check_status_3_from_a_tool_is_a_refusal() {
  # jq exits 3 when it cannot compile a program. That must not read as not promoted, which would release this commit.
  printf '#!/bin/sh\nexit 3\n' >"$REPO/.tools/bin/jq"
  chmod +x "$REPO/.tools/bin/jq"
  check
  expect "exit 1, and it exited $STATUS" equal "$STATUS" 1
}

# ---- Check: the smoke --------------------------------------------------------------------------------------------------
check_refuses_failed_smoke() {
  signed_edit '.smoke.result = "FAIL"'
  refused 'records a smoke that did not pass'
}
check_refuses_branding_not_pass() {
  signed_edit '.smoke.branding_overlay = "SKIP"'
  refused 'records branding-overlay as SKIP'
}
check_refuses_stale_smoke() {
  smoke_times A
  signed_edit '(.images[] | select(.component == "web") | .containers[0].started_at) = "'"$AFTER_SMOKE"'"'
  refused 'web has a container started at or after the smoke began'
}
check_refuses_a_container_started_with_the_smoke() {
  smoke_times A
  signed_edit '(.images[] | select(.component == "web") | .containers[0].started_at) = "'"$SMOKE_BEGAN"'"'
  refused 'web has a container started at or after the smoke began'
}
check_refuses_a_time_it_cannot_read() {
  signed_edit '(.images[] | select(.component == "web") | .containers[0].started_at) = "yesterday"'
  refused 'web has a container started at or after the smoke began'
}
check_refuses_a_replaced_container_beyond_the_worker() {
  smoke_times A
  signed_edit '(.images[] | select(.component == "web") | .containers[0]) |= (.started_at = "'"$DURING_SMOKE"'" | .replaced_by_smoke = true)'
  refused 'web claims a container the smoke replaced'
}
check_refuses_only_replaced_containers() {
  signed_edit '(.images[] | select(.component == "backend") | .containers) |= map(select(.replaced_by_smoke == true))'
  refused 'backend has no container that was there when the smoke began'
}
check_refuses_a_replacement_after_the_smoke() {
  smoke_times A
  signed_edit '(.images[] | select(.component == "backend") | .containers[] | select(.replaced_by_smoke == true) | .started_at) = "'"$AFTER_SMOKE"'"'
  refused 'backend has a container started at or after the smoke began'
}
check_refuses_no_containers() {
  signed_edit '(.images[] | select(.component == "web") | .containers) = []'
  refused 'web names no container that ran it'
}
check_refuses_a_smoke_file_that_changed() {
  jq_edit "$REPO/docs/evidence/runs/$(smoke_name A)" '.host = "changed"'
  commit_all 'the smoke changed after signing'
  refused 'is not the file'
}
check_refuses_a_missing_smoke_file() {
  git -C "$REPO" rm -qf "docs/evidence/runs/$(smoke_name A)"
  commit_all 'the smoke is gone'
  refused 'which is not in this commit'
}
check_refuses_a_smoke_path_outside_runs() {
  signed_edit '.smoke.published_path = "../../etc/passwd"'
  refused 'names no published smoke'
}
resign_smoke() { # resign_smoke <jq filter>: the published smoke says something else, and the evidence signs that file
  local file
  file="docs/evidence/runs/$(smoke_name A)"
  jq_edit "$REPO/$file" "$1"
  signed_edit '.smoke.sha256 = "'"$(sha256_file "$REPO/$file")"'"'
}
check_refuses_a_published_smoke_that_failed() {
  resign_smoke '.result = "FAIL"'
  refused 'names a published smoke that says FAIL'
}
check_refuses_a_published_smoke_of_another_mode() {
  resign_smoke '.mode = "verify"'
  refused 'no full dev smoke'
}
check_refuses_a_published_branding_skip() {
  resign_smoke '(.steps[] | select(.name == "branding-overlay") | .status) = "SKIP"'
  refused 'branding-overlay is SKIP'
}
check_refuses_a_published_smoke_of_other_digests() {
  resign_smoke '(.steps[] | select(.name == "branding-overlay") | .data.branded.web) = "'"$(digest_of B web)"'"'
  refused 'ran other branded digests'
}
check_refuses_other_smoke_times() {
  signed_edit '.smoke.started_at = "2026-11-07T09:59:00Z"'
  refused 'gives other times for its smoke'
}

# ---- Check: the set ----------------------------------------------------------------------------------------------------
check_refuses_a_set_covering_some_images() {
  signed_edit '.images |= map(select(.component != "web"))'
  refused 'does not cover exactly'
  expect "it names what is missing" said "$GHCR/web@$(digest_of A web)"
}
check_refuses_a_smaller_set_under_its_own_name() {
  # A properly signed set of eight, filed under its own hash, is no evidence for a render of nine.
  local smaller hash
  smaller="$WORK/smaller.json"
  jq -S '.images |= map(select(.component != "web"))' "$(evidence_file)" >"$smaller"
  hash="$(jq -r '.images[] | .production_repository + "@" + .digest' "$smaller" | hash_of_lines)"
  jq -S --arg hash "$hash" '.set_hash = $hash' "$smaller" >"$(evidence_file "$hash")"
  sign_file "$(evidence_file "$hash")"
  git -C "$REPO" rm -qf "docs/evidence/promotions/$HASH_A.json" "docs/evidence/promotions/$HASH_A.json.sig"
  commit_all 'only a smaller set has evidence'
  refused 'no evidence covers exactly'
  expect "it names the image no evidence names" said "no evidence names $GHCR/web@$(digest_of A web)"
}
check_refuses_a_digest_not_in_the_set() {
  replace_text "$(render_file)" "$(digest_of A web)" "$(digest_of B web)"
  commit_all 'a digest with no evidence'
  refused 'no evidence covers exactly'
  expect "it names that digest" said "no evidence names $GHCR/web@$(digest_of B web)"
}
check_refuses_a_mix_of_two_sets() {
  # Each digest has evidence, in two files. It has to be one file, because dev ran them together.
  replace_text "$(render_file)" "$(digest_of B web)" "$(digest_of A web)"
  commit_all 'web from one set, the rest from another'
  refused 'no evidence covers exactly'
}
check_refuses_another_repository() {
  replace_text "$(render_file)" "$GHCR/web@" "ghcr.io/someone-else/web@"
  commit_all 'the same digest from another repository'
  refused 'no evidence covers exactly'
}
check_refuses_a_digest_outside_the_images() {
  printf -- '---\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: planted\ndata:\n  note: sha256:%064d\n' 7 >>"$(render_file)"
  commit_all 'a digest in a ConfigMap'
  refused 'holds a digest outside its images'
}
check_refuses_an_image_in_a_job() {
  printf -- '---\napiVersion: batch/v1\nkind: Job\nmetadata:\n  name: planted\nspec:\n  template:\n    spec:\n      containers:\n      - name: main\n        image: docker.io/library/busybox@sha256:%064d\n' 8 >>"$(render_file)"
  commit_all 'one more image, in a Job'
  refused 'no evidence covers exactly'
  expect "it names that image" said "no evidence names docker.io/library/busybox@"
}
check_refuses_an_image_with_no_digest() {
  printf -- '---\napiVersion: v1\nkind: Pod\nmetadata:\n  name: planted\nspec:\n  containers:\n  - name: main\n    image: docker.io/library/busybox:latest\n' >>"$(render_file)"
  commit_all 'an image by tag'
  refused 'not pinned by digest'
}
check_refuses_a_hidden_image_field() {
  # JSON style, which a grep for image: at the start of a line would not see.
  printf -- '---\n{"apiVersion": "v1", "kind": "Pod", "metadata": {"name": "planted"}, "spec": {"containers": [{"name": "main", "image": "docker.io/library/busybox:latest"}]}}\n' >>"$(render_file)"
  commit_all 'an image in JSON style'
  refused 'not pinned by digest'
}
check_refuses_no_images() {
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: empty\n' >"$(render_file)"
  commit_all 'an empty render'
  refused 'names no image'
}
check_refuses_null_digest_with_application() {
  cp "$REPO/gitops/clusters/plane-prod/plane-prod-application.yaml.tmpl" "$(application_file)"
  commit_all 'the Application, with the null digest still there'
  refused 'still names the null digest'
}
check_refuses_null_digest_in_one_image() {
  replace_text "$(render_file)" "$(digest_of A web)" "$NULL_DIGEST"
  commit_all 'web at the null digest'
  refused 'still names the null digest'
}
check_refuses_real_digests_with_no_evidence_and_no_application() {
  git -C "$REPO" rm -qf "docs/evidence/promotions/$HASH_A.json" "docs/evidence/promotions/$HASH_A.json.sig"
  promote_fixture A
  rm -f "$(application_file)"
  commit_all 'real digests, no evidence, no Application'
  refused 'no evidence covers exactly'
}
check_refuses_half_null() {
  write_overlay prod A
  render_prod
  replace_text "$(render_file)" "$(digest_of A web)" "$NULL_DIGEST"
  commit_all 'half promoted'
  refused 'beside real Wayline digests'
}
check_refuses_an_application_with_no_render() {
  git -C "$REPO" rm -qf gitops/environments/prod/manifests.yaml
  commit_all 'no render'
  refused 'exists and gitops/environments/prod/manifests.yaml does not'
}
check_refuses_a_stray_file_beside_the_render() {
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: planted\n' >"$REPO/gitops/environments/prod/planted.yaml"
  commit_all 'a second file Argo CD would read'
  refused 'Argo CD reads all of'
}
check_refuses_a_wayline_image_elsewhere() {
  mkdir -p "$REPO/gitops/clusters/plane-prod/platform/planted"
  printf 'image: %s/web@sha256:%064d\n' "$GHCR" 9 >"$REPO/gitops/clusters/plane-prod/platform/planted/pod.yaml"
  commit_all 'a Wayline image outside the render'
  refused 'may name a Wayline image'
}

# ---- Check: what Argo CD would act on and this would not read -------------------------------------------------------------
HOSTED=gitops/clusters/plane-prod
plant_an_application() { # plant_an_application <file>: an Application on a branch nothing reviewed
  mkdir -p "$(dirname "$REPO/$1")"
  sed -e 's|name: plane-prod$|name: planted|' -e 's|targetRevision: deploy/plane-prod|targetRevision: unreviewed-branch|' -e 's|path: gitops/environments/prod|path: anything|' \
    "$REPO/$HOSTED/plane-prod-application.yaml.tmpl" >"$REPO/$1"
}
check_refuses_a_symlink_in_applications() {
  # Root would read through the link, and git and every reader that wants a regular file would pass over it.
  plant_an_application "$HOSTED/values/notes.yaml"
  ln -s ../values/notes.yaml "$REPO/$HOSTED/applications/notes.yaml"
  commit_all 'a link in applications/'
  refused 'is a symlink or a submodule'
}
check_refuses_applications_as_a_symlink() {
  git -C "$REPO" mv "$HOSTED/applications" "$HOSTED/values/elsewhere"
  ln -s values/elsewhere "$REPO/$HOSTED/applications"
  commit_all 'applications/ is a link to another folder'
  refused 'is a symlink or a submodule'
}
check_refuses_a_symlink_before_it_is_promoted() {
  # Not promoted must not read as nothing to look at. The platform is released either way.
  plant_an_application "$HOSTED/values/notes.yaml"
  ln -s ../values/notes.yaml "$REPO/$HOSTED/applications/notes.yaml"
  commit_all 'a link in applications/'
  refused 'is a symlink or a submodule'
}
check_refuses_a_submodule() {
  git -C "$REPO" update-index --add --cacheinfo "160000,$(head_commit),$HOSTED/platform/vendored"
  as_someone git -C "$REPO" commit -q -m 'a submodule'
  refused 'is a symlink or a submodule'
}
check_refuses_an_argocd_source_file() {
  # Argo CD merges this into the source of the Application reading the folder, so it could swap the backup's image.
  mkdir -p "$REPO/$HOSTED/platform/backup"
  printf 'kustomize:\n  images:\n    - docker.io/restic/restic=ghcr.io/attacker/evil:latest\n' >"$REPO/$HOSTED/platform/backup/.argocd-source-backup.yaml"
  commit_all 'an override beside the manifests'
  refused 'would be merged into'
}
check_refuses_a_kustomization_by_another_name() {
  # Argo CD builds a directory that holds one, and the checks read that directory as plain files.
  mkdir -p "$REPO/$HOSTED/platform/backup"
  printf 'resources: [plane-prod.yaml]\nimages:\n  - {name: docker.io/restic/restic, newName: ghcr.io/attacker/evil}\n' >"$REPO/$HOSTED/platform/backup/Kustomization"
  commit_all 'a kustomization under a name collect does not look for'
  refused 'makes Argo CD build this directory'
}
check_refuses_jsonnet_outside_applications() {
  mkdir -p "$REPO/$HOSTED/platform/planted"
  printf '{}\n' >"$REPO/$HOSTED/platform/planted/app.jsonnet"
  commit_all 'a file only Argo CD can read'
  refused 'would be evaluated by Argo CD'
}
check_refuses_a_file_it_cannot_parse() {
  printf 'a: [\n' >"$REPO/$HOSTED/values/broken.yaml"
  commit_all 'a broken file'
  refused 'cannot be parsed'
}
check_refuses_an_application_in_a_new_folder() {
  plant_an_application "$HOSTED/extras/notes.yaml"
  commit_all 'an Application nothing else reads'
  refused 'holds an Application, and only'
}
check_refuses_an_application_in_values() {
  plant_an_application "$HOSTED/values/notes.yaml"
  commit_all 'an Application among the values'
  refused 'holds an Application, and only'
}
check_refuses_something_else_in_applications() {
  # Root applies whatever is here, under project platform, which allows every kind and namespace.
  printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: planted\n  namespace: monitoring\nspec:\n  selector: {matchLabels: {app: planted}}\n  template:\n    metadata: {labels: {app: planted}}\n    spec:\n      containers:\n        - {name: main, image: "ghcr.io/bereketabera/wl/backend@sha256:%064d"}\n' 9 >"$REPO/$HOSTED/applications/extra.yaml"
  commit_all 'a Deployment root would apply'
  refused 'holds something other than an Application'
}
check_refuses_a_list_in_applications() {
  printf 'apiVersion: v1\nkind: List\nitems:\n  - {apiVersion: argoproj.io/v1alpha1, kind: Application, metadata: {name: planted}}\n' >"$REPO/$HOSTED/applications/extra.yaml"
  commit_all 'an Application inside a List'
  refused 'holds something other than an Application'
}
check_refuses_overrides_on_the_application() {
  yq -i '.spec.source.helm.parameters = [{"name": "image.tag", "value": "latest"}]' "$REPO/$HOSTED/applications/plane-prod.yaml"
  commit_all 'an override on what reads the render'
  refused 'sets more on its source than where to read'
}
check_finds_a_quoted_name_reading_the_render() {
  # Git quotes this name in its plain listing, and a quoted name would end in neither .yaml nor anything else this looks for.
  replace_text "$REPO/$HOSTED/plane-prod-application.yaml.tmpl" 'name: plane-prod' 'name: plane-too'
  cp "$REPO/$HOSTED/plane-prod-application.yaml.tmpl" "$REPO/$HOSTED/applications/caf$(printf '\303\251').yaml"
  commit_all 'an Application under a name Git quotes'
  refused 'also reads the Plane render'
}
check_refuses_tracked_tools() {
  # This would pass any signature, and neither the check nor the signers change.
  printf '#!/bin/sh\nexit 0\n' >"$REPO/.tools/bin/ssh-keygen"
  chmod +x "$REPO/.tools/bin/ssh-keygen"
  jq_edit "$(evidence_file)" '.recorded_at = "2030-01-01T00:00:00Z"'
  git -C "$REPO" add -f .tools/bin/ssh-keygen
  commit_all 'edited after signing, and a tool that agrees'
  refused 'tracks files under .tools'
}

# ---- Check: who reads the render ---------------------------------------------------------------------------------------
check_refuses_another_application_reading_the_render() {
  # Exit 3 says nothing reads this render, and this file does.
  replace_text "$REPO/gitops/clusters/plane-prod/plane-prod-application.yaml.tmpl" 'name: plane-prod' 'name: plane-too'
  cp "$REPO/gitops/clusters/plane-prod/plane-prod-application.yaml.tmpl" "$REPO/gitops/clusters/plane-prod/applications/sideways.yaml"
  commit_all 'an Application under another file name'
  refused 'also reads the Plane render'
}
check_refuses_another_file_named_plane_prod() {
  sed 's|path: gitops/environments/prod|path: gitops/clusters/plane-prod/values|' "$REPO/gitops/clusters/plane-prod/plane-prod-application.yaml.tmpl" >"$REPO/gitops/clusters/plane-prod/applications/sideways.yaml"
  commit_all 'an Application called plane-prod in another file'
  refused 'also reads the Plane render'
}
edit_application() { # edit_application <yq expression>
  yq -i "$1" "$(application_file)"
  commit_all 'the Application changes'
}
check_refuses_application_with_another_path() {
  edit_application '.spec.source.path = "gitops/clusters/plane-prod/values"'
  refused 'reads path gitops/clusters/plane-prod/values'
}
check_refuses_application_on_another_branch() {
  edit_application '.spec.source.targetRevision = "main"'
  refused 'reads revision main'
}
check_refuses_application_from_another_repository() {
  edit_application '.spec.source.repoURL = "https://example.invalid/fork.git"'
  refused 'reads https://example.invalid/fork.git'
}
check_refuses_application_with_a_second_source() {
  edit_application '.spec.sources = [.spec.source, {"repoURL": "https://example.invalid/fork.git", "path": "x", "targetRevision": "main"}]'
  refused 'has several sources'
}
check_refuses_application_of_another_namespace() {
  edit_application '.spec.destination.namespace = "default"'
  refused 'deploys to namespace default'
}
check_refuses_an_application_it_cannot_read() {
  printf 'a: [\n' >"$REPO/gitops/clusters/plane-prod/applications/broken.yaml"
  commit_all 'a broken file'
  refused 'is not YAML'
}
check_refuses_a_jsonnet_application() {
  printf '{}\n' >"$REPO/gitops/clusters/plane-prod/applications/sideways.jsonnet"
  commit_all 'a file only Argo CD can read'
  refused 'Argo CD would read it and this cannot'
}

# ---- Check: what each image is ---------------------------------------------------------------------------------------
check_refuses_arm64_entry() {
  signed_edit '(.images[] | select(.component == "web") | .platform) = "linux/arm64"'
  refused 'web is recorded as linux/arm64'
}
check_refuses_index_entry() {
  signed_edit '(.images[] | select(.component == "web") | .media_type) = "application/vnd.oci.image.index.v1+json"'
  refused 'not a plain manifest'
}
check_refuses_arm64_production_child() {
  signed_edit '(.images[] | select(.component == "postgres") | .production_runs.platform) = "linux/arm64"'
  refused 'does not say production runs the linux/amd64 child'
}
check_refuses_an_index_with_no_dev_child() {
  signed_edit '(.images[] | select(.component == "postgres")) |= del(.dev_ran)'
  refused 'does not say which child of the index dev ran'
}
check_refuses_wayline_recorded_as_upstream() {
  # The upstream rules do not ask about arm64 or a plain manifest, so being filed there must not be a way around them.
  signed_edit '(.images[] | select(.component == "web")) |= (.kind = "upstream-index" | .dev_repository = .production_repository | .dev_ran = {platform: "linux/arm64", digest: .digest} | .production_runs = {platform: "linux/amd64", digest: .digest})'
  refused 'is a Wayline image recorded as an upstream one'
}
check_refuses_an_unknown_kind() {
  signed_edit '(.images[] | select(.component == "web") | .kind) = "trust-me"'
  refused 'is of kind trust-me'
}
check_refuses_another_execution_claim() {
  signed_edit '.executed_under = "native-arm64"'
  refused 'records execution under native-arm64'
}
check_refuses_another_environment() {
  signed_edit '.environment = "plane-prod-sim"'
  refused 'was not recorded in plane-dev'
}
check_refuses_a_wrong_set_hash_inside() {
  signed_edit '.set_hash = "something-else"'
  refused 'says its set is something-else'
}
check_refuses_another_schema() {
  signed_edit '.schema = 2'
  refused 'this reads 1'
}
check_refuses_evidence_it_cannot_read() {
  printf '{"images": 7}\n' >"$(evidence_file)"
  sign_file "$(evidence_file)"
  commit_all 'signed nonsense'
  check
  expect "exit 1, and it exited $STATUS" equal "$STATUS" 1
  expect "it says it proved nothing" said 'proved nothing'
}

# ---- Check: history ----------------------------------------------------------------------------------------------------
check_refuses_argo_revision_off_history() {
  # A commit dev could have run, published to the laptop's own remote and never to GitHub.
  local side
  side="$(as_someone git -C "$REPO" commit-tree -m 'only on the laptop' "$DEV_A^{tree}")"
  signed_edit '.argo_revision = "'"$side"'"'
  refused 'which is not in this commit'
}
check_refuses_a_dev_overlay_that_disagrees() {
  # In history, and at that commit dev was told to run another set.
  signed_edit '.argo_revision = "'"$DEV_A"'"' "$HASH_B"
  refused 'names others'
}
check_refuses_image_revision_off_history() {
  local side
  side="$(as_someone git -C "$REPO" commit-tree -m 'never on main' "$DEV_A^{tree}")"
  signed_edit '(.images[] | select(.component == "web") | .revision) = "'"$side"'"'
  refused 'says an image was built from'
}
check_refuses_a_revision_with_a_bad_shape() {
  signed_edit '(.images[] | select(.component == "web") | .revision) = "--all"'
  refused 'records no revision'
}

# ---- Promote -----------------------------------------------------------------------------------------------------------
promote() { run_status ./scripts/ci/promote-prod.sh "$@"; }
message() { cat "$REPO/.build/promote-prod-message.txt"; }
no_worktree_left() { [[ "$(git -C "$REPO" worktree list | wc -l | tr -d ' ')" == 1 ]]; }
nothing_changed() { [[ -z "$(git -C "$REPO" status --porcelain -- helm gitops)" ]]; }

promote_first_promotion() {
  local before
  before="$(head_commit)"
  promote "$HASH_A"
  expect "it exits 0, and it exited $STATUS" equal "$STATUS" 0
  expect "the Application is the template" cmp -s "$REPO/gitops/clusters/plane-prod/plane-prod-application.yaml.tmpl" "$(application_file)"
  expect "web is on GHCR at set A's digest" equal "$(overlay_digest prod "$GHCR/web")" "$(digest_of A web)"
  expect "the render names it" grep -qF "$GHCR/web@$(digest_of A web)" "$(render_file)"
  expect "postgres keeps its tag and digest" grep -qF "docker.io/library/postgres:15.19-alpine@$(digest_of A postgres)" "$(render_file)"
  expect "no null digest is left" not_in_render "$NULL_DIGEST"
  expect "nothing was committed" equal "$(head_commit)" "$before"
  expect "the checkout's index is untouched" equal "$(git -C "$REPO" diff --cached --name-only)" ""
  expect "no worktree is left behind" no_worktree_left
  expect "the message says first promotion" grep -q 'first promotion' "$REPO/.build/promote-prod-message.txt"
  expect "the message names the set" grep -qF "Promote-Set: $HASH_A" "$REPO/.build/promote-prod-message.txt"
  # What the pull request merges has to pass where it counts.
  commit_all 'the pull request merges'
  passes
}
not_in_render() { ! grep -qF -- "$1" "$(render_file)"; }
promote_second_promotion() {
  local application
  application="$(cat "$(application_file)")"
  promote "$HASH_B"
  expect "it exits 0, and it exited $STATUS" equal "$STATUS" 0
  expect "web moves to set B" equal "$(overlay_digest prod "$GHCR/web")" "$(digest_of B web)"
  expect "the Application is as it was" equal "$(cat "$(application_file)")" "$application"
  expect "the message does not say first" not_in_message 'first promotion'
  commit_all 'the pull request merges'
  passes "$HASH_B"
}
not_in_message() { ! grep -qF -- "$1" "$REPO/.build/promote-prod-message.txt"; }
promote_already_holds_the_set() {
  promote "$HASH_A"
  expect "it exits 0, and it exited $STATUS" equal "$STATUS" 0
  expect "it says so" said 'already holds set'
  expect "nothing changed" nothing_changed
  expect "there is no message, so no pull request opens" absent "$REPO/.build/promote-prod-message.txt"
}
promote_rollback_to_an_older_set() {
  promote "$HASH_A"
  expect "it exits 0, and it exited $STATUS" equal "$STATUS" 0
  expect "web goes back to set A" equal "$(overlay_digest prod "$GHCR/web")" "$(digest_of A web)"
  commit_all 'the pull request merges'
  passes "$HASH_A"
  # The whole way, with the branch already at the newer set.
  at_commit "$PROMOTED_B"
  publish_ok
  expect "the branch starts at set B" equal "$(tip_web_digest)" "$(digest_of B web)"
  git -C "$REPO" reset -q --hard ORIG_HEAD
  at_commit "$(head_commit)"
  publish_ok 78
  expect "the branch goes back to set A" equal "$(tip_web_digest)" "$(digest_of A web)"
  expect "and says so" equal "$(tip_release .set_hash)" "$HASH_A"
}
promote_refuses_an_unknown_set() {
  promote "$(printf 'f%.0s' {1..64})"
  expect "it fails" [ "$STATUS" -ne 0 ]
  expect "it says so" said 'make record-dev-evidence writes it'
  expect "nothing changed" nothing_changed
}
promote_refuses_a_bad_hash() {
  mkdir -p "$REPO/planted"
  promote '../../../planted/x'
  expect "it fails" [ "$STATUS" -ne 0 ]
  expect "it says why" said 'a set hash is 64'
}
promote_refuses_uncommitted_evidence() {
  cp "$(evidence_file "$HASH_B")" "$WORK/keep.json"
  git -C "$REPO" rm -qf "docs/evidence/promotions/$HASH_B.json"
  commit_all 'evidence not on main'
  cp "$WORK/keep.json" "$(evidence_file "$HASH_B")"
  promote "$HASH_B"
  expect "it fails" [ "$STATUS" -ne 0 ]
  expect "it says why" said 'it has to be merged to main first'
  expect "nothing changed" nothing_changed
}
promote_refuses_what_the_check_refuses() {
  jq_edit "$(evidence_file "$HASH_B")" '.recorded_at = "2030-01-01T00:00:00Z"'
  commit_all 'edited after signing'
  promote "$HASH_B"
  expect "it fails" [ "$STATUS" -ne 0 ]
  expect "the check said why" said 'does not verify'
  expect "it says nothing is left" said 'nothing is left to merge'
  expect "the overlay and render are back as they were" nothing_changed
  expect "web is still at set A" equal "$(overlay_digest prod "$GHCR/web")" "$(digest_of A web)"
  expect "there is no message" absent "$REPO/.build/promote-prod-message.txt"
  expect "no worktree is left behind" no_worktree_left
}
promote_first_refusal_leaves_no_application() {
  jq_edit "$(evidence_file)" '.recorded_at = "2030-01-01T00:00:00Z"'
  commit_all 'edited after signing'
  promote "$HASH_A"
  expect "it fails" [ "$STATUS" -ne 0 ]
  expect "the Application it copied is gone" absent "$(application_file)"
  expect "the overlay and render are back as they were" nothing_changed
}
promote_refuses_a_dirty_overlay() {
  printf '# an edit\n' >>"$REPO/helm/plane/overlays/prod/kustomization.yaml"
  promote "$HASH_A"
  expect "it fails" [ "$STATUS" -ne 0 ]
  expect "it says why" said 'uncommitted changes under'
  expect "the edit is still there" grep -q '# an edit' "$REPO/helm/plane/overlays/prod/kustomization.yaml"
}
promote_refuses_a_digest_field_it_cannot_use() {
  # Only safe text reaches kustomize, signature or none: the signature is checked after this.
  jq_edit "$(evidence_file)" '(.images[] | select(.component == "web") | .production_repository) = "--load-restrictor"'
  commit_all 'an argument dressed as a repository'
  promote "$HASH_A"
  expect "it fails" [ "$STATUS" -ne 0 ]
  expect "it says why" said 'names an image this cannot use'
  expect "the overlay and render are back as they were" nothing_changed
}

# ---- Publish -----------------------------------------------------------------------------------------------------------
publish_no_cluster_tree() {
  git -C "$REPO" rm -rqf gitops/clusters
  commit_all 'no hosted tree yet'
  publish_ok
  expect "it says why" said 'there is nothing to release yet'
  expect "no branch appeared" equal "$(tip)" ""
}
publish_platform_only() {
  publish_ok
  expect "it says the release holds the platform" said 'holds the platform alone'
  expect "the branch exists" [ -n "$(tip)" ]
  expect "it has no parent" equal "$(git --git-dir="$ORIGIN" rev-list --count refs/heads/deploy/plane-prod)" 1
  expect "RELEASE.json names this commit" equal "$(tip_release .main_commit)" "$EVIDENCE_A"
  expect "RELEASE.json names the run" equal "$(tip_release .run.id)" 77
  expect "RELEASE.json has a link to the run" equal "$(tip_release .run.url)" 'https://github.com/BereketAbera/plane-platform/actions/runs/77'
  expect "RELEASE.json has no set" equal "$(tip_release .set_hash)" null
  expect "GHCR was not asked about the null digest" absent "$STUB/curl-urls"
}
publish_holds_only_the_hosted_trees() {
  local unexpected
  publish_ok
  unexpected="$(tip_files | grep -vE '^(RELEASE\.json|gitops/clusters/plane-prod/.*|gitops/environments/prod/.*)$' || true)"
  expect "only those paths are on the branch, and it holds: $unexpected" equal "$unexpected" ""
  expect "no workflow file" not_on_branch '.github/workflows/anything.yml'
  expect "the render is there" on_branch 'gitops/environments/prod/manifests.yaml'
  expect "the Application is there" on_branch 'gitops/clusters/plane-prod/applications/plane-prod.yaml'
  expect "the values are there" on_branch 'gitops/clusters/plane-prod/values/traefik.yaml'
  expect "the tree on the branch is the commit's, file for file" equal \
    "$(git --git-dir="$ORIGIN" rev-parse refs/heads/deploy/plane-prod:gitops/clusters/plane-prod)" "$(git -C "$REPO" rev-parse HEAD:gitops/clusters/plane-prod)"
  expect "the working tree is untouched" equal "$(git -C "$REPO" status --porcelain)" ""
  expect "and the checkout's index" equal "$(git -C "$REPO" diff --cached --name-only)" ""
}
on_branch() { tip_files | grep -qxF -- "$1"; }
not_on_branch() { ! tip_files | grep -qxF -- "$1"; }
publish_later_release_has_the_tip_as_parent() {
  local first
  publish_ok
  first="$(tip)"
  at_commit "$PROMOTED_A"
  publish_ok 78
  expect "the branch moved" [ "$(tip)" != "$first" ]
  expect "its parent is the previous tip, and not main" equal "$(git --git-dir="$ORIGIN" rev-parse refs/heads/deploy/plane-prod^)" "$first"
  expect "its history holds only releases" equal "$(git --git-dir="$ORIGIN" rev-list --count refs/heads/deploy/plane-prod)" 2
  expect "RELEASE.json names the newer commit" equal "$(tip_release .main_commit)" "$PROMOTED_A"
  expect "RELEASE.json names the newer run" equal "$(tip_release .run.id)" 78
  expect "RELEASE.json names the set" equal "$(tip_release .set_hash)" "$HASH_A"
  expect "the branch runs set A" equal "$(tip_web_digest)" "$(digest_of A web)"
}
publish_no_op_when_the_trees_match() {
  local first
  publish_ok
  first="$(tip)"
  printf 'unrelated\n' >"$REPO/source.txt"
  commit_all 'a change the hosted trees do not hold'
  at_commit "$(head_commit)"
  rm -f "$STUB/curl-urls"
  publish_ok 78
  expect "the branch stays where it was" equal "$(tip)" "$first"
  expect "it says why" said 'already holds what'
  expect "RELEASE.json still names the older commit, which is fine" equal "$(tip_release .main_commit)" "$PROMOTED_A"
  expect "GHCR was not asked" absent "$STUB/curl-urls"
}
publish_refuses_going_backwards() {
  publish_ok
  local newest
  newest="$(tip)"
  git -C "$REPO" reset -q --hard "$PROMOTED_A"
  stays_put "$newest" 'Refusing to move backwards'
  expect "RELEASE.json still names the newer commit" equal "$(tip_release .main_commit)" "$PROMOTED_B"
}
publish_rerun_of_the_same_commit_changes_nothing() {
  local first
  publish_ok
  first="$(tip)"
  publish_ok 78
  expect "the branch stays where it was" equal "$(tip)" "$first"
}
publish_refuses_failed_evidence() {
  local first
  publish_ok
  first="$(tip)"
  at_commit "$PROMOTED_B"
  jq_edit "$(evidence_file "$HASH_B")" '.recorded_at = "2030-01-01T00:00:00Z"'
  commit_all 'a merged pull request whose evidence does not verify'
  at_commit "$(head_commit)"
  stays_put "$first" 'this commit reaches nothing'
}
publish_refuses_a_digest_with_no_evidence_on_the_first_release() {
  git -C "$REPO" rm -qf "docs/evidence/promotions/$HASH_A.json" "docs/evidence/promotions/$HASH_A.json.sig"
  commit_all 'evidence gone'
  at_commit "$(head_commit)"
  stays_put '' 'this commit reaches nothing'
  expect "no branch appeared" equal "$(tip)" ""
}
publish_rollback_by_revert() {
  local release_b
  publish_ok
  release_b="$(tip)"
  as_someone git -C "$REPO" revert --no-edit "$PROMOTED_B" >/dev/null
  at_commit "$(head_commit)"
  publish_ok 78
  expect "the branch moved forwards" equal "$(git --git-dir="$ORIGIN" rev-parse refs/heads/deploy/plane-prod^)" "$release_b"
  expect "the branch runs set A again" equal "$(tip_web_digest)" "$(digest_of A web)"
  expect "RELEASE.json names the revert" equal "$(tip_release .main_commit)" "$(head_commit)"
  expect "RELEASE.json names the older set" equal "$(tip_release .set_hash)" "$HASH_A"
}
publish_refuses_off_main() {
  printf 'on a branch\n' >"$REPO/source.txt"
  commit_all 'not on main'
  stays_put '' 'is not on origin'
  expect "no branch appeared" equal "$(tip)" ""
}
publish_refuses_an_unreadable_origin() {
  # An origin that cannot answer must not look like one with no release branch, or this would start a new root.
  git -C "$REPO" remote set-url origin "$WORK/no-such-repository.git"
  publish
  expect "it fails" [ "$STATUS" -ne 0 ]
  expect "it says why" said 'could not read origin'
}
publish_needs_a_run() {
  run_status env GITHUB_TOKEN=stub-token ./scripts/ci/publish-release.sh
  expect "it fails" [ "$STATUS" -ne 0 ]
  expect "it says why" said 'GITHUB_RUN_ID is not set'
  expect "no branch appeared" equal "$(tip)" ""
}
publish_needs_a_token_to_read_ghcr() {
  run_status env GITHUB_RUN_ID=77 ./scripts/ci/publish-release.sh
  expect "it fails" [ "$STATUS" -ne 0 ]
  expect "it says why" said 'reading GHCR takes GITHUB_TOKEN'
  expect "no branch appeared" equal "$(tip)" ""
}
publish_keeps_tokens_off_the_command_line() {
  publish_ok
  expect "curl was called" exists "$STUB/curl-arguments"
  expect "no token in curl's arguments" no_token_in_arguments
  expect "the token went by stdin" grep -q 'stub-token' "$STUB/curl-config"
  expect "and the bearer" grep -q 'stub-bearer' "$STUB/curl-config"
}
no_token_in_arguments() { ! grep -qE 'stub-token|stub-bearer' "$STUB/curl-arguments"; }
publish_refuses_what_ghcr_lacks() {
  mv "$REGISTRY/$(digest_of A admin)" "$REGISTRY/$(digest_of A admin).gone"
  publish
  mv "$REGISTRY/$(digest_of A admin).gone" "$REGISTRY/$(digest_of A admin)"
  expect "it fails" [ "$STATUS" -ne 0 ]
  expect "it says why" said 'GHCR does not serve'
  expect "no branch appeared" equal "$(tip)" ""
}
# A set whose web digest GHCR would serve as something else. The evidence is signed and claims a plain linux/amd64 image,
# so only reading GHCR can catch it.
promote_with_web() { # promote_with_web <label> <digest>
  make_set "$1" web "$2"
  write_overlay dev "$1"
  commit_all "dev runs set $1"
  write_evidence "$1" "$(head_commit)" >/dev/null
  commit_all "evidence for set $1"
  promote_fixture "$1"
  commit_all "promote set $1"
  at_commit "$(head_commit)"
}
publish_refuses_an_index_on_ghcr() {
  promote_with_web I "$(store_index 'wayline web as an index')"
  stays_put '' 'not a plain image manifest'
  expect "no branch appeared" equal "$(tip)" ""
}
publish_refuses_arm64_on_ghcr() {
  promote_with_web R "$(store_manifest "$(store_config 'web for arm64' arm64 "$SOURCE_COMMIT")")"
  stays_put '' 'is for linux/arm64'
}
publish_refuses_another_revision_on_ghcr() {
  promote_with_web L "$(store_manifest "$(store_config 'web from elsewhere' amd64 "$DEV_A")")"
  stays_put '' 'says it was built from'
}
publish_refuses_a_config_that_does_not_hash() {
  local config manifest
  config="$(store_config 'web whose config is swapped' amd64 "$SOURCE_COMMIT")"
  manifest="$(store_manifest "$config")"
  promote_with_web C "$manifest"
  printf '{"architecture":"amd64","os":"linux","note":"not the config it hashes to"}\n' >"$REGISTRY/$config"
  stays_put '' 'as the config'
}
publish_refuses_bytes_that_do_not_hash() {
  local saved
  saved="$WORK/saved-manifest"
  cp "$REGISTRY/$(digest_of A web)" "$saved"
  printf '{"schemaVersion":2}\n' >"$REGISTRY/$(digest_of A web)"
  publish
  cp "$saved" "$REGISTRY/$(digest_of A web)"
  expect "it fails" [ "$STATUS" -ne 0 ]
  expect "it says why" said 'does not hash to that digest'
  expect "no branch appeared" equal "$(tip)" ""
}
publish_refuses_a_branch_that_moved() {
  # The branch moves while GHCR is being read. The push is not forced, so it loses.
  local moved
  publish_ok
  at_commit "$PROMOTED_B"
  cat >"$STUB/curl-hook" <<HOOK
rm -f "$STUB/curl-hook"
parent="\$(git --git-dir="$ORIGIN" rev-parse refs/heads/deploy/plane-prod)"
new="\$(GIT_AUTHOR_NAME=x GIT_AUTHOR_EMAIL=x@invalid GIT_COMMITTER_NAME=x GIT_COMMITTER_EMAIL=x@invalid git --git-dir="$ORIGIN" commit-tree "\$parent^{tree}" -p "\$parent" -m 'someone else got there first')"
git --git-dir="$ORIGIN" update-ref refs/heads/deploy/plane-prod "\$new"
HOOK
  publish
  moved="$(git --git-dir="$ORIGIN" log -1 --format=%s refs/heads/deploy/plane-prod)"
  expect "it fails" [ "$STATUS" -ne 0 ]
  expect "it says why" said 'could not push'
  expect "the other commit stays" equal "$moved" 'someone else got there first'
}
publish_refuses_foreign_files_on_the_branch() {
  # A workflow file on this branch would run, and GITHUB_TOKEN may not remove one, so a person has to look.
  local index="$WORK/foreign-index" blob tree commit
  publish_ok
  blob="$(printf 'name: planted\n' | git --git-dir="$ORIGIN" hash-object -w --stdin)"
  GIT_INDEX_FILE="$index" git --git-dir="$ORIGIN" read-tree refs/heads/deploy/plane-prod
  GIT_INDEX_FILE="$index" git --git-dir="$ORIGIN" update-index --add --cacheinfo "100644,$blob,.github/workflows/planted.yml"
  tree="$(GIT_INDEX_FILE="$index" git --git-dir="$ORIGIN" write-tree)"
  commit="$(as_someone git --git-dir="$ORIGIN" commit-tree "$tree" -p refs/heads/deploy/plane-prod -m 'pushed by hand')"
  git --git-dir="$ORIGIN" update-ref refs/heads/deploy/plane-prod "$commit"
  at_commit "$PROMOTED_B"
  stays_put "$commit" 'holds more than a release should'
}
publish_a_name_git_quotes_is_no_foreign_file() {
  printf 'deployment: {}\n' >"$REPO/gitops/clusters/plane-prod/values/caf$(printf '\303\251').yaml"
  commit_all 'a values file under a name Git quotes'
  at_commit "$(head_commit)"
  publish_ok
  printf 'unrelated\n' >"$REPO/source.txt"
  commit_all 'a change the hosted trees do not hold'
  at_commit "$(head_commit)"
  publish_ok 78
  run_status ./scripts/ci/check-deploy-branch.sh
  expect "the daily look agrees, and it exited $STATUS" equal "$STATUS" 0
}
publish_refuses_a_tip_with_no_release() {
  local tree commit
  tree="$(printf '' | git --git-dir="$ORIGIN" mktree)"
  commit="$(as_someone git --git-dir="$ORIGIN" commit-tree "$tree" -m 'pushed by hand')"
  git --git-dir="$ORIGIN" update-ref refs/heads/deploy/plane-prod "$commit"
  stays_put "$commit" 'no RELEASE.json naming a main commit'
}
push_by_hand() { # A push to the branch that moves the web digest and keeps RELEASE.json. Prints the commit it made.
  local index="$WORK/hand-index" blob tree commit
  blob="$(git --git-dir="$ORIGIN" show refs/heads/deploy/plane-prod:gitops/environments/prod/manifests.yaml | sed "s/$(digest_of A web)/$(digest_of B web)/" | git --git-dir="$ORIGIN" hash-object -w --stdin)"
  GIT_INDEX_FILE="$index" git --git-dir="$ORIGIN" read-tree refs/heads/deploy/plane-prod
  GIT_INDEX_FILE="$index" git --git-dir="$ORIGIN" update-index --add --cacheinfo "100644,$blob,gitops/environments/prod/manifests.yaml"
  tree="$(GIT_INDEX_FILE="$index" git --git-dir="$ORIGIN" write-tree)"
  rm -f "$index"
  commit="$(as_someone git --git-dir="$ORIGIN" commit-tree "$tree" -p refs/heads/deploy/plane-prod -m 'pushed by hand')"
  git --git-dir="$ORIGIN" update-ref refs/heads/deploy/plane-prod "$commit"
  printf '%s' "$commit"
}
publish_refuses_a_branch_pushed_by_hand() {
  # Rerunning the same commit used to overwrite it and say nothing, and so did the next real release.
  local pushed
  publish_ok
  pushed="$(push_by_hand)"
  stays_put "$pushed" 'so someone pushed it by hand'
  expect "it names the commit" said "$pushed"
  at_commit "$PROMOTED_B"
  stays_put "$pushed" 'so someone pushed it by hand'
}
publish_refuses_going_back_to_no_set() {
  # A revert of the first promotion leaves exit 3, and root would prune Application plane-prod with Plane still running.
  local released
  publish_ok
  released="$(tip)"
  as_someone git -C "$REPO" revert --no-edit "$PROMOTED_A" >/dev/null
  at_commit "$(head_commit)"
  stays_put "$released" 'a revert of the first promotion'
  expect "the Application is still on the branch" on_branch 'gitops/clusters/plane-prod/applications/plane-prod.yaml'
  expect "RELEASE.json still names the set" equal "$(tip_release .set_hash)" "$HASH_A"
}
publish_platform_only_twice() {
  # A branch that has never run a set is free to stay that way.
  local first
  publish_ok
  first="$(tip)"
  printf 'deployment: {replicas: 1}\n' >"$REPO/gitops/clusters/plane-prod/values/traefik.yaml"
  commit_all 'a change to the platform, and still no promotion'
  at_commit "$(head_commit)"
  publish_ok 78
  expect "the branch moved" [ "$(tip)" != "$first" ]
  expect "RELEASE.json has no set" equal "$(tip_release .set_hash)" null
}
publish_refuses_tracked_tools() {
  # common.sh puts this first on PATH with the token in the environment, so it must not get that far.
  printf '#!/bin/sh\nprintf "%%s" "$GITHUB_TOKEN" >"$STUB/stolen"\nexit 0\n' >"$REPO/.tools/bin/jq"
  chmod +x "$REPO/.tools/bin/jq"
  git -C "$REPO" add -f .tools/bin/jq
  commit_all 'a tool in the commit'
  at_commit "$(head_commit)"
  stays_put '' 'would run as tools with the token in reach'
  expect "it never ran" absent "$STUB/stolen"
}
publish_writes_the_job_summary() {
  run_status env GITHUB_STEP_SUMMARY="$STUB/summary" GITHUB_RUN_ID=77 GITHUB_TOKEN=stub-token ./scripts/ci/publish-release.sh
  expect "it exits 0, and it exited $STATUS" equal "$STATUS" 0
  expect "the summary says where the branch went" grep -q 'deploy/plane-prod is now' "$STUB/summary"
}

# ---- The daily look at the branch ---------------------------------------------------------------------------------------
deploy_branch_check() { run_status ./scripts/ci/check-deploy-branch.sh; }
deploy_branch_check_no_branch() {
  deploy_branch_check
  expect "exit 0, and it exited $STATUS" equal "$STATUS" 0
  expect "it says so" said 'no deploy/plane-prod yet'
}
deploy_branch_check_holds_what_was_released() {
  publish_ok
  deploy_branch_check
  expect "exit 0, and it exited $STATUS" equal "$STATUS" 0
  expect "it says so" said 'holds what main'
}
deploy_branch_check_after_a_release_that_changed_nothing() {
  # RELEASE.json keeps naming the older commit, and that is what a release leaves, so it must not read as a push.
  publish_ok
  printf 'unrelated\n' >"$REPO/source.txt"
  commit_all 'a change the hosted trees do not hold'
  at_commit "$(head_commit)"
  publish_ok 78
  deploy_branch_check
  expect "exit 0, and it exited $STATUS" equal "$STATUS" 0
}
deploy_branch_check_finds_a_hand_push() {
  local pushed
  publish_ok
  pushed="$(push_by_hand)"
  deploy_branch_check
  expect "exit 1, and it exited $STATUS" equal "$STATUS" 1
  expect "it says so" said 'so someone pushed it by hand'
  expect "it names the commit" said "$pushed"
  expect "it changed nothing" equal "$(tip)" "$pushed"
}
deploy_branch_check_finds_foreign_files() {
  local index="$WORK/foreign-index" blob tree commit
  publish_ok
  blob="$(printf 'name: planted\n' | git --git-dir="$ORIGIN" hash-object -w --stdin)"
  GIT_INDEX_FILE="$index" git --git-dir="$ORIGIN" read-tree refs/heads/deploy/plane-prod
  GIT_INDEX_FILE="$index" git --git-dir="$ORIGIN" update-index --add --cacheinfo "100644,$blob,.github/workflows/planted.yml"
  tree="$(GIT_INDEX_FILE="$index" git --git-dir="$ORIGIN" write-tree)"
  commit="$(as_someone git --git-dir="$ORIGIN" commit-tree "$tree" -p refs/heads/deploy/plane-prod -m 'pushed by hand')"
  git --git-dir="$ORIGIN" update-ref refs/heads/deploy/plane-prod "$commit"
  deploy_branch_check
  expect "exit 1, and it exited $STATUS" equal "$STATUS" 1
  expect "it says so" said 'holds more than a release does'
}
deploy_branch_check_finds_no_release_file() {
  local tree commit
  tree="$(printf '' | git --git-dir="$ORIGIN" mktree)"
  commit="$(as_someone git --git-dir="$ORIGIN" commit-tree "$tree" -m 'pushed by hand')"
  git --git-dir="$ORIGIN" update-ref refs/heads/deploy/plane-prod "$commit"
  deploy_branch_check
  expect "exit 1, and it exited $STATUS" equal "$STATUS" 1
  expect "it says so" said 'has no RELEASE.json naming a main commit'
}
deploy_branch_check_finds_a_commit_off_main() {
  # A forged RELEASE.json, naming a commit whose trees match what was pushed.
  local index="$WORK/forged-index" blob tree commit forged
  publish_ok
  forged="$(as_someone git -C "$REPO" commit-tree "$(git -C "$REPO" rev-parse 'HEAD^{tree}')" -m 'on no branch')"
  git -C "$REPO" push -q origin "$forged:refs/heads/elsewhere"
  blob="$(git --git-dir="$ORIGIN" show refs/heads/deploy/plane-prod:RELEASE.json | jq --arg forged "$forged" '.main_commit = $forged' | git --git-dir="$ORIGIN" hash-object -w --stdin)"
  GIT_INDEX_FILE="$index" git --git-dir="$ORIGIN" read-tree refs/heads/deploy/plane-prod
  GIT_INDEX_FILE="$index" git --git-dir="$ORIGIN" update-index --add --cacheinfo "100644,$blob,RELEASE.json"
  tree="$(GIT_INDEX_FILE="$index" git --git-dir="$ORIGIN" write-tree)"
  commit="$(as_someone git --git-dir="$ORIGIN" commit-tree "$tree" -p refs/heads/deploy/plane-prod -m 'pushed by hand')"
  git --git-dir="$ORIGIN" update-ref refs/heads/deploy/plane-prod "$commit"
  deploy_branch_check
  expect "exit 1, and it exited $STATUS" equal "$STATUS" 1
  expect "it says so" said "which is not on origin's main"
}
deploy_branch_check_says_nothing_when_it_cannot_read() {
  git -C "$REPO" remote set-url origin "$WORK/no-such-origin"
  deploy_branch_check
  expect "exit 2, and it exited $STATUS" equal "$STATUS" 2
  expect "it says so" said 'says nothing about deploy/plane-prod'
}

# ---- Record -------------------------------------------------------------------------------------------------------------
# What a dev that really ran set <label> looks like: its smoke, raw and published, and the cluster's answers.
write_cluster() { # write_cluster <label> <argo revision>
  local label="$1" revision="$2" chart component kind repository tag digest image
  smoke_times "$label"
  jq -n --arg revision "$revision" '{status: {sync: {status: "Synced", revision: $revision}, health: {status: "Healthy"}}}' >"$STUB/application.json"
  printf '{"items":[{"status":{"nodeInfo":{"architecture":"arm64"}}}]}\n' >"$STUB/nodes.json"
  : >"$WORK/pods"
  pod() { # pod <name> <image> <repository for imageID> <digest> <started>
    jq -n -c --arg name "$1" --arg image "$2" --arg id "$3@$4" --arg started "$5" '
      {metadata: {name: $name}, status: {phase: "Running", containerStatuses: [{name: "main", ready: true, imageID: $id, state: {running: {startedAt: $started}}}]},
       spec: {containers: [{name: "main", image: $image}]}}' >>"$WORK/pods"
  }
  while read -r chart component kind repository tag; do
    digest="$(digest_of "$label" "$component")"
    if [[ "$kind" == branded ]]; then
      repository="localhost:5001/wayline/$component"
      image="$repository@$digest"
    else
      image="$repository:$tag@$digest"
    fi
    case "$component" in
      backend)
        pod plane-api-wl-1 "$image" "$repository" "$digest" "$BEFORE_SMOKE"
        pod plane-beat-worker-wl-1 "$image" "$repository" "$digest" "$BEFORE_SMOKE"
        pod plane-worker-wl-2 "$image" "$repository" "$digest" "$DURING_SMOKE"
        ;;
      *) pod "plane-$component-wl-1" "$image" "$repository" "$digest" "$BEFORE_SMOKE" ;;
    esac
  done <"$IMAGES_TABLE"
  # What the overlay does not name: restarting one of these proves or disproves nothing about it.
  pod postgres-exporter-1 quay.io/prometheuscommunity/postgres-exporter:v0.20.1@sha256:aaaa quay.io/prometheuscommunity/postgres-exporter "sha256:$(printf '%064d' 4)" "$AFTER_SMOKE"
  jq -s '{items: .}' "$WORK/pods" >"$STUB/pods.json"
  : >"$STUB/gh-run.log"
  for component in admin backend space web; do printf 'ok %s/%s@%s\n' "$GHCR" "$component" "$(digest_of "$label" "$component")" >>"$STUB/gh-run.log"; done
}
ready_to_record() { # ready_to_record <label> <argo revision>: after make test-e2e ENV=dev and make publish-evidence
  local name
  name="$(smoke_name "$1")"
  mkdir -p "$REPO/.local/evidence-raw" "$REPO/docs/evidence/runs"
  write_smoke "$1" "$REPO/.local/evidence-raw/$name"
  cp "$REPO/.local/evidence-raw/$name" "$REPO/docs/evidence/runs/$name"
  write_cluster "$1" "$2"
}
raw_smoke() { printf '%s/.local/evidence-raw/%s' "$REPO" "$(smoke_name "${1:-A}")"; }
published_smoke() { printf '%s/docs/evidence/runs/%s' "$REPO" "$(smoke_name "${1:-A}")"; }
both_smokes() { jq_edit "$(raw_smoke)" "$1"; jq_edit "$(published_smoke)" "$1"; }
record() { run_status ./scripts/record-dev-evidence.sh; }
record_refused() { # record_refused <what it must say>
  record
  expect "it fails" [ "$STATUS" -ne 0 ]
  expect "it says: $1" said "$1"
  expect "it wrote no evidence" no_evidence_written
}
no_evidence_written() { [[ ! -d "$REPO/docs/evidence/promotions" || -z "$(find "$REPO/docs/evidence/promotions" -type f)" ]]; }
pod_edit() { jq_edit "$STUB/pods.json" "$1"; }

record_passes_and_the_check_accepts_it() {
  # The platform goes first, as it does for real.
  publish_ok 70
  expect "the first release names no set" equal "$(tip_release .set_hash)" null
  ready_to_record A "$DEV_A"
  record
  expect "it exits 0, and it exited $STATUS" equal "$STATUS" 0
  expect "the evidence is at the set's hash" exists "$(evidence_file)"
  expect "and signed" exists "$(evidence_file).sig"
  expect "it records the digest" jq -e --arg digest "$(digest_of A web)" 'any(.images[]; .component == "web" and .digest == $digest)' "$(evidence_file)"
  expect "it records a plain amd64 manifest" jq -e 'any(.images[]; .component == "web" and .platform == "linux/amd64" and (.media_type | test("manifest")))' "$(evidence_file)"
  expect "it records the image's revision label" jq -e --arg revision "$SOURCE_COMMIT" 'any(.images[]; .component == "web" and .revision == $revision)' "$(evidence_file)"
  expect "it records the run that built it" jq -e 'any(.images[]; .component == "web" and .built_by_run == 1001)' "$(evidence_file)"
  expect "it records the Argo revision" jq -e --arg revision "$DEV_A" '.argo_revision == $revision' "$(evidence_file)"
  expect "it records where it ran" jq -e '.executed_under == "rosetta-on-arm64" and .environment == "plane-dev"' "$(evidence_file)"
  expect "it records the published smoke's hash" jq -e --arg sha256 "$(sha256_file "$(published_smoke)")" '.smoke.sha256 == $sha256' "$(evidence_file)"
  expect "it records which children of an index ran where" jq -e 'any(.images[]; .component == "postgres" and .dev_ran.platform == "linux/arm64" and .production_runs.platform == "linux/amd64" and (.dev_ran.digest != .production_runs.digest))' "$(evidence_file)"
  expect "it marks the worker the smoke replaced, and only that" jq -e '[.images[].containers[] | select(.replaced_by_smoke == true) | .pod] == ["plane-worker-wl-2"]' "$(evidence_file)"
  expect "the exporter is no part of it" not_in_evidence postgres-exporter
  # The whole way: this is the only proof that what this writes is what the check reads.
  commit_all 'evidence, as make record-dev-evidence tells you to'
  at_commit "$(head_commit)"
  promote "$HASH_A"
  expect "promote takes it, and exited $STATUS" equal "$STATUS" 0
  commit_all 'the pull request merges'
  at_commit "$(head_commit)"
  publish_ok
  expect "it reaches the branch" equal "$(tip_release .set_hash)" "$HASH_A"
  expect "the branch runs that digest" equal "$(tip_web_digest)" "$(digest_of A web)"
}
not_in_evidence() { ! grep -qF -- "$1" "$(evidence_file)"; }
record_newest_smoke_failed() {
  # The older one passed. The newest one is what decides.
  ready_to_record A "$DEV_A"
  jq -S '.run_id = "run-newer" | .started_at = "2026-11-07T10:20:00Z" | .finished_at = "2026-11-07T10:30:00Z" | .result = "FAIL"' "$(raw_smoke)" >"$REPO/.local/evidence-raw/smoke-dev-zzz.json"
  record_refused 'its result is FAIL'
}
record_newest_smoke_by_what_it_says() {
  # An older failure under a name that sorts last, and a newer pass under one that sorts first.
  ready_to_record A "$DEV_A"
  jq -S '.started_at = "2026-11-01T10:20:00Z" | .finished_at = "2026-11-01T10:30:00Z" | .result = "FAIL"' "$(raw_smoke)" >"$REPO/.local/evidence-raw/smoke-dev-zzz.json"
  mv "$(raw_smoke)" "$REPO/.local/evidence-raw/smoke-dev-aaa.json"
  cp "$REPO/.local/evidence-raw/smoke-dev-aaa.json" "$REPO/docs/evidence/runs/smoke-dev-aaa.json"
  record
  expect "the newer pass decides, and it exited $STATUS" equal "$STATUS" 0
  expect "it names that file" jq -e '.smoke.published_path == "docs/evidence/runs/smoke-dev-aaa.json"' "$(evidence_file)"
}
record_refuses_a_smoke_it_cannot_read() {
  ready_to_record A "$DEV_A"
  printf '{"truncated"' >"$REPO/.local/evidence-raw/smoke-dev-zzz.json"
  record_refused 'it could be the newest dev smoke'
}
record_no_smoke_at_all() {
  ready_to_record A "$DEV_A"
  rm -f "$(raw_smoke)"
  record_refused 'no dev smoke'
}
record_branding_overlay_skipped() {
  ready_to_record A "$DEV_A"
  both_smokes '(.steps[] | select(.name == "branding-overlay") | .status) = "SKIP"'
  record_refused 'branding-overlay is SKIP'
}
record_a_branded_image_skipped() {
  ready_to_record A "$DEV_A"
  both_smokes '(.steps[] | select(.name == "branding-admin") | .status) = "SKIP"'
  record_refused 'branding-admin is SKIP'
}
record_smoke_in_verify_mode() {
  ready_to_record A "$DEV_A"
  both_smokes '.mode = "verify"'
  record_refused 'it ran in mode verify'
}
record_smoke_not_published() {
  ready_to_record A "$DEV_A"
  rm -f "$(published_smoke)"
  record_refused 'has to name a file Git keeps'
}
record_published_copy_differs() {
  ready_to_record A "$DEV_A"
  jq_edit "$(published_smoke)" '.started_at = "2026-11-07T09:59:00Z"'
  record_refused 'does not say what'
}
record_argo_not_synced() {
  ready_to_record A "$DEV_A"
  jq_edit "$STUB/application.json" '.status.sync.status = "OutOfSync"'
  record_refused 'is OutOfSync/Healthy'
}
record_argo_revision_off_main() {
  # make gitops-publish can publish what GitHub has not got.
  ready_to_record A "$DEV_A"
  git --git-dir="$ORIGIN" update-ref refs/heads/main "$SOURCE_COMMIT"
  record_refused 'which is not on'
}
record_overlay_has_a_null_digest() {
  ready_to_record A "$DEV_A"
  replace_text "$REPO/helm/plane/overlays/dev/kustomization.yaml" "$(digest_of A web)" "$NULL_DIGEST"
  commit_all 'the failure drill'
  at_commit "$(head_commit)"
  jq_edit "$STUB/application.json" '.status.sync.revision = "'"$(head_commit)"'"'
  record_refused 'no real digest'
}
record_smoke_of_other_digests() {
  ready_to_record A "$DEV_A"
  both_smokes '(.steps[] | select(.name == "branding-overlay") | .data.branded.web) = "'"$(digest_of B web)"'"'
  record_refused 'the newest smoke checked other branded digests'
}
record_digest_not_running() {
  ready_to_record A "$DEV_A"
  pod_edit '.items |= map(select(.metadata.name != "plane-web-wl-1"))'
  record_refused 'no container in plane-dev runs web'
}
record_image_id_is_what_counts() {
  # The spec names the digest, and what is running is something else.
  ready_to_record A "$DEV_A"
  pod_edit '(.items[] | select(.metadata.name == "plane-web-wl-1") | .status.containerStatuses[0].imageID) = "localhost:5001/wayline/web@'"$(digest_of B web)"'"'
  record_refused 'no container in plane-dev runs web'
}
record_container_not_ready() {
  ready_to_record A "$DEV_A"
  pod_edit '(.items[] | select(.metadata.name == "plane-web-wl-1") | .status.containerStatuses[0].ready) = false'
  record_refused 'is not ready'
}
web_pod_at_set_b() { # web_pod_at_set_b <jq filter for the extra pod>: another web pod in the list, running set B's digest
  jq --arg image "localhost:5001/wayline/web@$(digest_of B web)" '.items += [.items[] | select(.metadata.name == "plane-web-wl-1")
    | .metadata.name = "plane-web-wl-0" | .status.containerStatuses[0].imageID = $image | .spec.containers[0].image = $image | '"$1"']' "$STUB/pods.json" >"$STUB/pods.new"
  mv "$STUB/pods.new" "$STUB/pods.json"
}
record_ignores_a_pod_on_its_way_out() {
  # Going, and running the digest from before, which is neither proof nor problem.
  ready_to_record A "$DEV_A"
  web_pod_at_set_b '.metadata.deletionTimestamp = "2026-11-07T09:00:00Z"'
  record
  expect "it exits 0, and it exited $STATUS" equal "$STATUS" 0
}
record_ignores_a_finished_pod() {
  # A hook Job's pod, say, which ran what it ran and is not running now.
  ready_to_record A "$DEV_A"
  web_pod_at_set_b '.status.phase = "Succeeded"'
  record
  expect "it exits 0, and it exited $STATUS" equal "$STATUS" 0
}
record_container_started_during_smoke() {
  ready_to_record A "$DEV_A"
  smoke_times A
  pod_edit '(.items[] | select(.metadata.name == "plane-web-wl-1") | .status.containerStatuses[0].state.running.startedAt) = "'"$DURING_SMOKE"'"'
  record_refused 'not before the smoke began'
}
record_young_worker_with_no_negative_control() {
  # The exemption is the smoke's to give.
  ready_to_record A "$DEV_A"
  both_smokes '.steps |= map(select(.name != "worker-negative-control"))'
  record_refused 'plane-worker-wl-2/main started at'
}
record_worker_started_after_the_smoke() {
  ready_to_record A "$DEV_A"
  smoke_times A
  pod_edit '(.items[] | select(.metadata.name == "plane-worker-wl-2") | .status.containerStatuses[0].state.running.startedAt) = "'"$AFTER_SMOKE"'"'
  record_refused 'plane-worker-wl-2/main started at'
}
record_only_the_replaced_worker_runs_backend() {
  ready_to_record A "$DEV_A"
  pod_edit '.items |= map(select(.metadata.name != "plane-api-wl-1" and .metadata.name != "plane-beat-worker-wl-1"))'
  record_refused 'no container of backend was there when the smoke began'
}
record_older_digest_still_running() {
  ready_to_record A "$DEV_A"
  web_pod_at_set_b '.'
  record_refused 'plane-web-wl-0/main runs'
}
record_node_not_arm64() {
  ready_to_record A "$DEV_A"
  printf '{"items":[{"status":{"nodeInfo":{"architecture":"amd64"}}}]}\n' >"$STUB/nodes.json"
  record_refused 'a node here is not arm64'
}
# Dev runs set <label>, whose web digest is the given one, and the rest as in set A.
dev_runs_web() { # dev_runs_web <label> <web digest>
  make_set "$1" web "$2"
  write_overlay dev "$1"
  commit_all "dev runs set $1"
  at_commit "$(head_commit)"
  ready_to_record "$1" "$(head_commit)"
}
record_branded_is_an_index() {
  dev_runs_web I "$(store_index 'wayline web as an index')"
  record_refused 'an index, not a plain manifest'
}
record_branded_is_arm64() {
  dev_runs_web R "$(store_manifest "$(store_config 'web for arm64' arm64 "$SOURCE_COMMIT")")"
  record_refused 'is linux/arm64'
}
record_branded_not_on_ghcr() {
  ready_to_record A "$DEV_A"
  mv "$REGISTRY/$(digest_of A web)" "$WORK/web-manifest"
  record
  mv "$WORK/web-manifest" "$REGISTRY/$(digest_of A web)"
  expect "it fails" [ "$STATUS" -ne 0 ]
  expect "it says why" said 'Docker cannot read'
  expect "it wrote no evidence" no_evidence_written
}
record_bytes_do_not_hash() {
  ready_to_record A "$DEV_A"
  cp "$REGISTRY/$(digest_of A web)" "$WORK/web-manifest"
  printf '{"schemaVersion":2}\n' >"$REGISTRY/$(digest_of A web)"
  record
  cp "$WORK/web-manifest" "$REGISTRY/$(digest_of A web)"
  expect "it fails" [ "$STATUS" -ne 0 ]
  expect "it says why" said 'does not hash to that digest'
  expect "it wrote no evidence" no_evidence_written
}
record_revision_off_main() {
  local side
  side="$(as_someone git -C "$REPO" commit-tree -m 'built from a branch' "$DEV_A^{tree}")"
  dev_runs_web E "$(store_manifest "$(store_config 'web from a branch' amd64 "$side")")"
  record_refused 'which is not on origin'
}
record_no_revision_label() {
  dev_runs_web N "$(store_manifest "$(store_config 'web with no label' amd64 '')")"
  record_refused 'has no revision label'
}
record_no_successful_run() {
  ready_to_record A "$DEV_A"
  printf '[{"databaseId":1001,"headSha":"%s","conclusion":"failure"}]\n' "$SOURCE_COMMIT" >"$STUB/gh-runs.json"
  record_refused 'no successful images.yml push run'
}
record_digest_not_in_the_run_log() {
  # A run of that commit succeeded, and this digest is not what it built.
  ready_to_record A "$DEV_A"
  grep -vF "$(digest_of A web)" "$STUB/gh-run.log" >"$STUB/gh-run.new"
  mv "$STUB/gh-run.new" "$STUB/gh-run.log"
  record_refused 'no successful images.yml push run'
}
record_upstream_is_not_an_index() {
  ready_to_record A "$DEV_A"
  local plain
  plain="$(store_manifest "$(store_config 'postgres, one platform' amd64 "$SOURCE_COMMIT")")"
  mkdir -p "$SETS/U"
  cp "$SETS/A"/* "$SETS/U/"
  printf '%s' "$plain" >"$SETS/U/postgres"
  write_overlay dev U
  commit_all 'dev runs a plain postgres'
  at_commit "$(head_commit)"
  ready_to_record U "$(head_commit)"
  record_refused 'is not an index with one linux/arm64 and one linux/amd64 child'
}
record_no_key() {
  ready_to_record A "$DEV_A"
  mv "$HOME/.ssh/wayline_evidence_ed25519" "$WORK/key"
  record
  mv "$WORK/key" "$HOME/.ssh/wayline_evidence_ed25519"
  expect "it fails" [ "$STATUS" -ne 0 ]
  expect "it says why" said 'only that key may sign'
  expect "it wrote no evidence" no_evidence_written
}
record_key_the_signers_do_not_accept() {
  ready_to_record A "$DEV_A"
  printf 'wayline-evidence %s\n' "$(cut -d' ' -f1-2 "$OTHER_KEY.pub")" >"$REPO/.github/evidence-signers"
  record_refused 'does not accept'
}

# ---- Workflows ----------------------------------------------------------------------------------------------------------
# yq reads what GitHub would run. These fail if a later edit quietly widens what the release job may do.
as_json() { yq -o=json '.' "$1" >"$WORK/workflow.json"; }
workflow_says() { jq -r "$1" "$WORK/workflow.json"; } # workflow_says <jq filter>
workflow_release_job() {
  local job='.jobs["release-plane-prod"]' checkout='[.steps[] | select(.uses // "" | test("actions/checkout"))][0]'
  as_json "$ROOT/.github/workflows/ci.yml"
  expect "it needs the three others" equal "$(workflow_says "$job.needs | sort | join(\" \")")" 'lint manifests security'
  expect "only on a push to main" equal "$(workflow_says "$job.if")" "github.event_name == 'push' && github.ref == 'refs/heads/main'"
  expect "two permissions and no more" equal "$(workflow_says "$job.permissions | to_entries | map(.key + \"=\" + .value) | sort | join(\" \")")" 'contents=write packages=read'
  expect "the workflow itself grants nothing" equal "$(workflow_says '.permissions | length')" 0
  expect "no credentials left in the checkout" equal "$(workflow_says "$job | $checkout | .with[\"persist-credentials\"]")" false
  expect "all of history, for ancestry" equal "$(workflow_says "$job | $checkout | .with[\"fetch-depth\"]")" 0
  expect "nothing a cache could poison in the one job that can write" equal "$(workflow_says "[$job.steps[] | select(.uses // \"\" | test(\"actions/cache\"))] | length")" 0
  expect "it runs the publish script" equal "$(workflow_says "[$job.steps[] | select(.run // \"\" | test(\"scripts/ci/publish-release.sh\"))] | length")" 1
  expect "no other job may write" equal "$(workflow_says '[.jobs | to_entries[] | select(.key != "release-plane-prod") | .value.permissions | to_entries[] | select(.value != "read")] | length')" 0
}
workflow_promote_job() {
  local job='.jobs["open-pull-request"]' checkout='[.steps[] | select(.uses // "" | test("actions/checkout"))][0]'
  as_json "$ROOT/.github/workflows/promote-plane-prod.yml"
  expect "dispatch only" equal "$(workflow_says '.on | keys | join(" ")')" workflow_dispatch
  expect "it asks for set_hash" equal "$(workflow_says '.on.workflow_dispatch.inputs.set_hash.required')" true
  expect "the workflow itself grants nothing" equal "$(workflow_says '.permissions | length')" 0
  expect "only what opening a pull request takes" equal "$(workflow_says "$job.permissions | to_entries | map(.key + \"=\" + .value) | sort | join(\" \")")" 'contents=write pull-requests=write'
  expect "every action pinned to a commit" equal "$(workflow_says "[$job.steps[] | select(.uses) | .uses | select(test(\"@[a-f0-9]{40}$\") | not)] | length")" 0
  expect "no credentials left in the checkout" equal "$(workflow_says "$job | $checkout | .with[\"persist-credentials\"]")" false
  expect "it goes through the script, which checks first" equal "$(workflow_says "[$job.steps[] | select(.run // \"\" | test(\"scripts/ci/promote-prod.sh\"))] | length")" 1
  expect "the input reaches no shell by expansion" equal "$(workflow_says '[.jobs[].steps[] | select(.run // "" | test("inputs\\."))] | length')" 0
  expect "the pull request holds the Application" grep -qF 'gitops/clusters/plane-prod/applications/plane-prod.yaml' "$ROOT/.github/workflows/promote-plane-prod.yml"
}
workflow_deploy_branch_check() {
  local job='.jobs.compare' checkout='[.steps[] | select(.uses // "" | test("actions/checkout"))][0]'
  as_json "$ROOT/.github/workflows/check-deploy-branch.yml"
  expect "each day, and by hand" equal "$(workflow_says '.on | keys | sort | join(" ")')" 'schedule workflow_dispatch'
  expect "the workflow itself grants nothing" equal "$(workflow_says '.permissions | length')" 0
  expect "it can read and no more" equal "$(workflow_says "$job.permissions | to_entries | map(.key + \"=\" + .value) | join(\" \")")" 'contents=read'
  expect "no credentials left in the checkout" equal "$(workflow_says "$job | $checkout | .with[\"persist-credentials\"]")" false
  expect "it runs the comparison" equal "$(workflow_says "[$job.steps[] | select(.run // \"\" | test(\"scripts/ci/check-deploy-branch.sh\"))] | length")" 1
}
workflow_gate_runs_in_make_ci() {
  as_json "$ROOT/.github/workflows/ci.yml"
  expect "make ci runs this" grep -qE '^[[:space:]]*for check in .*test-prod-gate' "$ROOT/Makefile"
  expect "the Manifests job runs this" equal "$(workflow_says '[.jobs.manifests.steps[] | select(.run // "" | test("scripts/ci/test-prod-gate.sh"))] | length')" 1
  expect "the Manifests job, which the release needs, checks the quotas too" equal "$(workflow_says '[.jobs.manifests.steps[] | select(.run // "" | test("scripts/ci/check-capacity.sh"))] | length')" 1
}

# ---- The real tree ------------------------------------------------------------------------------------------------------
# The fixture has its own overlay and Application, so these keep the real ones honest. A gate that refuses them would hold
# production back for good, and only on the day of the first promotion would anyone find out.
real_application_is_what_the_check_wants() {
  cp "$ROOT/gitops/clusters/plane-prod/plane-prod-application.yaml.tmpl" "$(application_file)"
  commit_all 'the real Application'
  passes
}
real_tree_passes_the_refusals() {
  # Not promoted, so exit 3 says everything above the render let the real tree through.
  rm -rf "$REPO/gitops/clusters/plane-prod"
  cp -R "$ROOT/gitops/clusters/plane-prod" "$REPO/gitops/clusters/plane-prod"
  rm -f "$REPO/gitops/clusters/plane-prod/applications/plane-prod.yaml"
  commit_all 'the real hosted tree'
  not_yet
}
real_render_runs_only_what_the_overlay_names() {
  # Evidence is one set per overlay, so an image the overlay cannot move could never have evidence.
  local rendered named
  rendered="$(yq -o=json -I=0 '.' "$ROOT/gitops/environments/prod/manifests.yaml" | jq -r '.. | objects | select(has("image")) | .image | sub(":[^/@]*@"; "@")' | LC_ALL=C sort -u)"
  named="$(yq -r '.images[] | (.newName // .name) + "@" + .digest' "$ROOT/helm/plane/overlays/prod/kustomization.yaml" | LC_ALL=C sort -u)"
  expect "the render's images are the overlay's. Render: $rendered. Overlay: $named" equal "$rendered" "$named"
}
real_overlays_name_the_same_images() {
  # Dev's digests are the ones with evidence, so a chart image only one of them names could never be in a set both hold.
  local dev prod
  dev="$(yq -r '.images[].name' "$ROOT/helm/plane/overlays/dev/kustomization.yaml" | LC_ALL=C sort)"
  prod="$(yq -r '.images[].name' "$ROOT/helm/plane/overlays/prod/kustomization.yaml" | LC_ALL=C sort)"
  expect "dev's overlay and prod's name the same chart images" equal "$dev" "$prod"
  expect "prod's Wayline images are the GHCR names evidence maps to" equal \
    "$(yq -r '.images[] | select(.newName | test("^ghcr.io/")) | .newName' "$ROOT/helm/plane/overlays/prod/kustomization.yaml" | LC_ALL=C sort | sed 's|.*/||')" \
    "$(yq -r '.images[] | select(.newName | test("^localhost:5001/")) | .newName' "$ROOT/helm/plane/overlays/dev/kustomization.yaml" | LC_ALL=C sort | sed 's|.*/||')"
}
real_signers_accept_a_signature_from_that_key() {
  # With no private key at hand, the shape of the line is what can be read here. A signature's principal is checked for real above.
  expect "it names the signer and one Ed25519 key" equal "$(grep -cE '^wayline-evidence ssh-ed25519 [A-Za-z0-9+/=]+( .*)?$' "$ROOT/.github/evidence-signers")" 1
  expect "and nothing else is trusted" equal "$(grep -cvE '^(#.*|wayline-evidence ssh-ed25519 .*)$' "$ROOT/.github/evidence-signers" || true)" 0
}

# ---- The run ------------------------------------------------------------------------------------------------------------
passed=0
failed=0
scenario() { # scenario <name> <function> <commit to start from>
  local name="$1" body="$2" start="$3" stopped=0
  if [[ -n "${GATE_EXACT:-}" ]]; then
    [[ "$name" == "$GATE_EXACT" ]] || return 0
  else
    [[ -z "$FILTER" || "$name" == *"$FILTER"* ]] || return 0
  fi
  fresh "$start"
  : >"$FAILURES"
  # A command failing in a scenario's own setup ends that scenario and not the run. Not under `if`, which would switch
  # errexit off inside the function.
  set +e
  (
    set -e
    "$body"
  )
  stopped=$?
  set -e
  if [[ "$stopped" -ne 0 ]]; then
    warn "  a command in the scenario itself failed, with status $stopped"
    printf 'stopped\n' >>"$FAILURES"
  fi
  if [[ ! -s "$FAILURES" ]]; then
    ok "$name"
    passed=$((passed + 1))
  else
    warn "$name FAILED. Its last command printed:"
    sed 's/^/    /' "$OUT" | tail -n 25 >&2
    failed=$((failed + 1))
  fi
}

log "Building the fixture"
build_template

scenario check-passes check_passes "$PROMOTED_A"
scenario check-not-promoted check_not_promoted "$EVIDENCE_A"
scenario check-not-promoted-all-null check_not_promoted_all_null "$EVIDENCE_A"
scenario check-nothing-there-yet check_nothing_there_yet "$SOURCE_COMMIT"
scenario check-older-evidenced-set-passes check_older_evidenced_set_passes "$PROMOTED_B"
scenario check-refuses-tampered-json check_refuses_tampered_json "$PROMOTED_A"
scenario check-refuses-wrong-signer check_refuses_wrong_signer "$PROMOTED_A"
scenario check-refuses-wrong-namespace check_refuses_wrong_namespace "$PROMOTED_A"
scenario check-refuses-another-principal check_refuses_another_principal "$PROMOTED_A"
scenario check-refuses-missing-signature check_refuses_missing_signature "$PROMOTED_A"
scenario check-refuses-signers-only-in-the-tree check_refuses_signers_only_in_the_tree "$PROMOTED_A"
scenario check-ignores-signers-in-the-tree check_ignores_signers_in_the_tree "$PROMOTED_A"
scenario check-refuses-no-signers-file check_refuses_no_signers_file "$PROMOTED_A"
scenario check-reads-evidence-from-the-commit check_reads_evidence_from_the_commit "$PROMOTED_A"
scenario check-reads-the-render-from-the-commit check_reads_the_render_from_the_commit "$PROMOTED_A"
scenario check-refuses-an-edited-check check_refuses_an_edited_check "$PROMOTED_A"
scenario check-refuses-a-check-not-in-the-commit check_refuses_a_check_not_in_the_commit "$PROMOTED_A"
scenario check-refuses-an-argument check_refuses_an_argument "$PROMOTED_A"
scenario check-ignores-gits-environment check_ignores_gits_environment "$PROMOTED_A"
scenario check-refuses-shallow-history check_refuses_shallow_history "$PROMOTED_A"
scenario check-status-3-from-a-tool-is-a-refusal check_status_3_from_a_tool_is_a_refusal "$PROMOTED_A"
scenario check-refuses-failed-smoke check_refuses_failed_smoke "$PROMOTED_A"
scenario check-refuses-branding-not-pass check_refuses_branding_not_pass "$PROMOTED_A"
scenario check-refuses-stale-smoke check_refuses_stale_smoke "$PROMOTED_A"
scenario check-refuses-a-container-started-with-the-smoke check_refuses_a_container_started_with_the_smoke "$PROMOTED_A"
scenario check-refuses-a-time-it-cannot-read check_refuses_a_time_it_cannot_read "$PROMOTED_A"
scenario check-refuses-a-replaced-container-beyond-the-worker check_refuses_a_replaced_container_beyond_the_worker "$PROMOTED_A"
scenario check-refuses-only-replaced-containers check_refuses_only_replaced_containers "$PROMOTED_A"
scenario check-refuses-a-replacement-after-the-smoke check_refuses_a_replacement_after_the_smoke "$PROMOTED_A"
scenario check-refuses-no-containers check_refuses_no_containers "$PROMOTED_A"
scenario check-refuses-a-smoke-file-that-changed check_refuses_a_smoke_file_that_changed "$PROMOTED_A"
scenario check-refuses-a-missing-smoke-file check_refuses_a_missing_smoke_file "$PROMOTED_A"
scenario check-refuses-a-smoke-path-outside-runs check_refuses_a_smoke_path_outside_runs "$PROMOTED_A"
scenario check-refuses-a-published-smoke-that-failed check_refuses_a_published_smoke_that_failed "$PROMOTED_A"
scenario check-refuses-a-published-smoke-of-another-mode check_refuses_a_published_smoke_of_another_mode "$PROMOTED_A"
scenario check-refuses-a-published-branding-skip check_refuses_a_published_branding_skip "$PROMOTED_A"
scenario check-refuses-a-published-smoke-of-other-digests check_refuses_a_published_smoke_of_other_digests "$PROMOTED_A"
scenario check-refuses-other-smoke-times check_refuses_other_smoke_times "$PROMOTED_A"
scenario check-refuses-a-set-covering-some-images check_refuses_a_set_covering_some_images "$PROMOTED_A"
scenario check-refuses-a-smaller-set-under-its-own-name check_refuses_a_smaller_set_under_its_own_name "$PROMOTED_A"
scenario check-refuses-a-digest-not-in-the-set check_refuses_a_digest_not_in_the_set "$PROMOTED_A"
scenario check-refuses-a-mix-of-two-sets check_refuses_a_mix_of_two_sets "$PROMOTED_B"
scenario check-refuses-another-repository check_refuses_another_repository "$PROMOTED_A"
scenario check-refuses-a-digest-outside-the-images check_refuses_a_digest_outside_the_images "$PROMOTED_A"
scenario check-refuses-an-image-in-a-job check_refuses_an_image_in_a_job "$PROMOTED_A"
scenario check-refuses-an-image-with-no-digest check_refuses_an_image_with_no_digest "$PROMOTED_A"
scenario check-refuses-a-hidden-image-field check_refuses_a_hidden_image_field "$PROMOTED_A"
scenario check-refuses-no-images check_refuses_no_images "$PROMOTED_A"
scenario check-refuses-null-digest-with-application check_refuses_null_digest_with_application "$EVIDENCE_A"
scenario check-refuses-null-digest-in-one-image check_refuses_null_digest_in_one_image "$PROMOTED_A"
scenario check-refuses-real-digests-with-no-evidence-and-no-application check_refuses_real_digests_with_no_evidence_and_no_application "$EVIDENCE_A"
scenario check-refuses-half-null check_refuses_half_null "$EVIDENCE_A"
scenario check-refuses-an-application-with-no-render check_refuses_an_application_with_no_render "$PROMOTED_A"
scenario check-refuses-a-stray-file-beside-the-render check_refuses_a_stray_file_beside_the_render "$PROMOTED_A"
scenario check-refuses-a-wayline-image-elsewhere check_refuses_a_wayline_image_elsewhere "$PROMOTED_A"
scenario check-refuses-another-application-reading-the-render check_refuses_another_application_reading_the_render "$EVIDENCE_A"
scenario check-refuses-another-file-named-plane-prod check_refuses_another_file_named_plane_prod "$EVIDENCE_A"
scenario check-refuses-application-with-another-path check_refuses_application_with_another_path "$PROMOTED_A"
scenario check-refuses-application-on-another-branch check_refuses_application_on_another_branch "$PROMOTED_A"
scenario check-refuses-application-from-another-repository check_refuses_application_from_another_repository "$PROMOTED_A"
scenario check-refuses-application-with-a-second-source check_refuses_application_with_a_second_source "$PROMOTED_A"
scenario check-refuses-application-of-another-namespace check_refuses_application_of_another_namespace "$PROMOTED_A"
scenario check-refuses-an-application-it-cannot-read check_refuses_an_application_it_cannot_read "$PROMOTED_A"
scenario check-refuses-a-jsonnet-application check_refuses_a_jsonnet_application "$PROMOTED_A"
scenario check-refuses-arm64-entry check_refuses_arm64_entry "$PROMOTED_A"
scenario check-refuses-index-entry check_refuses_index_entry "$PROMOTED_A"
scenario check-refuses-arm64-production-child check_refuses_arm64_production_child "$PROMOTED_A"
scenario check-refuses-an-index-with-no-dev-child check_refuses_an_index_with_no_dev_child "$PROMOTED_A"
scenario check-refuses-wayline-recorded-as-upstream check_refuses_wayline_recorded_as_upstream "$PROMOTED_A"
scenario check-refuses-an-unknown-kind check_refuses_an_unknown_kind "$PROMOTED_A"
scenario check-refuses-another-execution-claim check_refuses_another_execution_claim "$PROMOTED_A"
scenario check-refuses-another-environment check_refuses_another_environment "$PROMOTED_A"
scenario check-refuses-a-wrong-set-hash-inside check_refuses_a_wrong_set_hash_inside "$PROMOTED_A"
scenario check-refuses-another-schema check_refuses_another_schema "$PROMOTED_A"
scenario check-refuses-evidence-it-cannot-read check_refuses_evidence_it_cannot_read "$PROMOTED_A"
scenario check-refuses-argo-revision-off-history check_refuses_argo_revision_off_history "$PROMOTED_A"
scenario check-refuses-a-dev-overlay-that-disagrees check_refuses_a_dev_overlay_that_disagrees "$PROMOTED_B"
scenario check-refuses-image-revision-off-history check_refuses_image_revision_off_history "$PROMOTED_A"
scenario check-refuses-a-revision-with-a-bad-shape check_refuses_a_revision_with_a_bad_shape "$PROMOTED_A"

scenario promote-first-promotion promote_first_promotion "$EVIDENCE_A"
scenario promote-second-promotion promote_second_promotion "$EVIDENCE_B"
scenario promote-already-holds-the-set promote_already_holds_the_set "$PROMOTED_A"
scenario promote-rollback-to-an-older-set promote_rollback_to_an_older_set "$PROMOTED_B"
scenario promote-refuses-an-unknown-set promote_refuses_an_unknown_set "$PROMOTED_A"
scenario promote-refuses-a-bad-hash promote_refuses_a_bad_hash "$PROMOTED_A"
scenario promote-refuses-uncommitted-evidence promote_refuses_uncommitted_evidence "$EVIDENCE_B"
scenario promote-refuses-what-the-check-refuses promote_refuses_what_the_check_refuses "$EVIDENCE_B"
scenario promote-first-refusal-leaves-no-application promote_first_refusal_leaves_no_application "$EVIDENCE_A"
scenario promote-refuses-a-dirty-overlay promote_refuses_a_dirty_overlay "$EVIDENCE_A"
scenario promote-refuses-a-digest-field-it-cannot-use promote_refuses_a_digest_field_it_cannot_use "$EVIDENCE_A"

scenario publish-no-cluster-tree publish_no_cluster_tree "$SOURCE_COMMIT"
scenario publish-platform-only publish_platform_only "$EVIDENCE_A"
scenario publish-holds-only-the-hosted-trees publish_holds_only_the_hosted_trees "$PROMOTED_A"
scenario publish-later-release-has-the-tip-as-parent publish_later_release_has_the_tip_as_parent "$EVIDENCE_A"
scenario publish-no-op-when-the-trees-match publish_no_op_when_the_trees_match "$PROMOTED_A"
scenario publish-rerun-of-the-same-commit-changes-nothing publish_rerun_of_the_same_commit_changes_nothing "$PROMOTED_A"
scenario publish-refuses-going-backwards publish_refuses_going_backwards "$PROMOTED_B"
scenario publish-refuses-failed-evidence publish_refuses_failed_evidence "$PROMOTED_A"
scenario publish-refuses-a-digest-with-no-evidence-on-the-first-release publish_refuses_a_digest_with_no_evidence_on_the_first_release "$PROMOTED_A"
scenario publish-rollback-by-revert publish_rollback_by_revert "$PROMOTED_B"
scenario publish-refuses-off-main publish_refuses_off_main "$PROMOTED_A"
scenario publish-refuses-an-unreadable-origin publish_refuses_an_unreadable_origin "$PROMOTED_A"
scenario publish-needs-a-run publish_needs_a_run "$PROMOTED_A"
scenario publish-needs-a-token-to-read-ghcr publish_needs_a_token_to_read_ghcr "$PROMOTED_A"
scenario publish-keeps-tokens-off-the-command-line publish_keeps_tokens_off_the_command_line "$PROMOTED_A"
scenario publish-refuses-what-ghcr-lacks publish_refuses_what_ghcr_lacks "$PROMOTED_A"
scenario publish-refuses-an-index-on-ghcr publish_refuses_an_index_on_ghcr "$EVIDENCE_A"
scenario publish-refuses-arm64-on-ghcr publish_refuses_arm64_on_ghcr "$EVIDENCE_A"
scenario publish-refuses-another-revision-on-ghcr publish_refuses_another_revision_on_ghcr "$EVIDENCE_A"
scenario publish-refuses-a-config-that-does-not-hash publish_refuses_a_config_that_does_not_hash "$EVIDENCE_A"
scenario publish-refuses-bytes-that-do-not-hash publish_refuses_bytes_that_do_not_hash "$PROMOTED_A"
scenario publish-refuses-a-branch-that-moved publish_refuses_a_branch_that_moved "$PROMOTED_A"
scenario publish-refuses-foreign-files-on-the-branch publish_refuses_foreign_files_on_the_branch "$PROMOTED_A"
scenario publish-refuses-a-tip-with-no-release publish_refuses_a_tip_with_no_release "$PROMOTED_A"
scenario publish-writes-the-job-summary publish_writes_the_job_summary "$PROMOTED_A"

scenario record-passes-and-the-check-accepts-it record_passes_and_the_check_accepts_it "$DEV_A"
scenario record-newest-smoke-failed record_newest_smoke_failed "$DEV_A"
scenario record-newest-smoke-by-what-it-says record_newest_smoke_by_what_it_says "$DEV_A"
scenario record-refuses-a-smoke-it-cannot-read record_refuses_a_smoke_it_cannot_read "$DEV_A"
scenario record-no-smoke-at-all record_no_smoke_at_all "$DEV_A"
scenario record-branding-overlay-skipped record_branding_overlay_skipped "$DEV_A"
scenario record-a-branded-image-skipped record_a_branded_image_skipped "$DEV_A"
scenario record-smoke-in-verify-mode record_smoke_in_verify_mode "$DEV_A"
scenario record-smoke-not-published record_smoke_not_published "$DEV_A"
scenario record-published-copy-differs record_published_copy_differs "$DEV_A"
scenario record-argo-not-synced record_argo_not_synced "$DEV_A"
scenario record-argo-revision-off-main record_argo_revision_off_main "$DEV_A"
scenario record-overlay-has-a-null-digest record_overlay_has_a_null_digest "$DEV_A"
scenario record-smoke-of-other-digests record_smoke_of_other_digests "$DEV_A"
scenario record-digest-not-running record_digest_not_running "$DEV_A"
scenario record-image-id-is-what-counts record_image_id_is_what_counts "$DEV_A"
scenario record-container-not-ready record_container_not_ready "$DEV_A"
scenario record-container-started-during-smoke record_container_started_during_smoke "$DEV_A"
scenario record-young-worker-with-no-negative-control record_young_worker_with_no_negative_control "$DEV_A"
scenario record-worker-started-after-the-smoke record_worker_started_after_the_smoke "$DEV_A"
scenario record-only-the-replaced-worker-runs-backend record_only_the_replaced_worker_runs_backend "$DEV_A"
scenario record-older-digest-still-running record_older_digest_still_running "$DEV_A"
scenario record-ignores-a-pod-on-its-way-out record_ignores_a_pod_on_its_way_out "$DEV_A"
scenario record-ignores-a-finished-pod record_ignores_a_finished_pod "$DEV_A"
scenario record-node-not-arm64 record_node_not_arm64 "$DEV_A"
scenario record-branded-is-an-index record_branded_is_an_index "$DEV_A"
scenario record-branded-is-arm64 record_branded_is_arm64 "$DEV_A"
scenario record-branded-not-on-ghcr record_branded_not_on_ghcr "$DEV_A"
scenario record-bytes-do-not-hash record_bytes_do_not_hash "$DEV_A"
scenario record-revision-off-main record_revision_off_main "$DEV_A"
scenario record-no-revision-label record_no_revision_label "$DEV_A"
scenario record-no-successful-run record_no_successful_run "$DEV_A"
scenario record-digest-not-in-the-run-log record_digest_not_in_the_run_log "$DEV_A"
scenario record-upstream-is-not-an-index record_upstream_is_not_an_index "$DEV_A"
scenario record-no-key record_no_key "$DEV_A"
scenario record-key-the-signers-do-not-accept record_key_the_signers_do_not_accept "$DEV_A"

scenario check-refuses-a-symlink-in-applications check_refuses_a_symlink_in_applications "$PROMOTED_A"
scenario check-refuses-applications-as-a-symlink check_refuses_applications_as_a_symlink "$PROMOTED_A"
scenario check-refuses-a-symlink-before-it-is-promoted check_refuses_a_symlink_before_it_is_promoted "$EVIDENCE_A"
scenario check-refuses-a-submodule check_refuses_a_submodule "$PROMOTED_A"
scenario check-refuses-an-argocd-source-file check_refuses_an_argocd_source_file "$PROMOTED_A"
scenario check-refuses-a-kustomization-by-another-name check_refuses_a_kustomization_by_another_name "$PROMOTED_A"
scenario check-refuses-jsonnet-outside-applications check_refuses_jsonnet_outside_applications "$PROMOTED_A"
scenario check-refuses-a-file-it-cannot-parse check_refuses_a_file_it_cannot_parse "$PROMOTED_A"
scenario check-refuses-an-application-in-a-new-folder check_refuses_an_application_in_a_new_folder "$PROMOTED_A"
scenario check-refuses-an-application-in-values check_refuses_an_application_in_values "$PROMOTED_A"
scenario check-refuses-something-else-in-applications check_refuses_something_else_in_applications "$PROMOTED_A"
scenario check-refuses-a-list-in-applications check_refuses_a_list_in_applications "$PROMOTED_A"
scenario check-refuses-overrides-on-the-application check_refuses_overrides_on_the_application "$PROMOTED_A"
scenario check-finds-a-quoted-name-reading-the-render check_finds_a_quoted_name_reading_the_render "$EVIDENCE_A"
scenario check-refuses-tracked-tools check_refuses_tracked_tools "$PROMOTED_A"
scenario publish-a-name-git-quotes-is-no-foreign-file publish_a_name_git_quotes_is_no_foreign_file "$PROMOTED_A"
scenario publish-refuses-a-branch-pushed-by-hand publish_refuses_a_branch_pushed_by_hand "$PROMOTED_A"
scenario publish-refuses-going-back-to-no-set publish_refuses_going_back_to_no_set "$PROMOTED_A"
scenario publish-platform-only-twice publish_platform_only_twice "$EVIDENCE_A"
scenario publish-refuses-tracked-tools publish_refuses_tracked_tools "$PROMOTED_A"
scenario deploy-branch-check-no-branch deploy_branch_check_no_branch "$PROMOTED_A"
scenario deploy-branch-check-holds-what-was-released deploy_branch_check_holds_what_was_released "$PROMOTED_A"
scenario deploy-branch-check-after-a-release-that-changed-nothing deploy_branch_check_after_a_release_that_changed_nothing "$PROMOTED_A"
scenario deploy-branch-check-finds-a-hand-push deploy_branch_check_finds_a_hand_push "$PROMOTED_A"
scenario deploy-branch-check-finds-foreign-files deploy_branch_check_finds_foreign_files "$PROMOTED_A"
scenario deploy-branch-check-finds-no-release-file deploy_branch_check_finds_no_release_file "$PROMOTED_A"
scenario deploy-branch-check-finds-a-commit-off-main deploy_branch_check_finds_a_commit_off_main "$PROMOTED_A"
scenario deploy-branch-check-says-nothing-when-it-cannot-read deploy_branch_check_says_nothing_when_it_cannot_read "$PROMOTED_A"

scenario real-application-is-what-the-check-wants real_application_is_what_the_check_wants "$PROMOTED_A"
scenario real-tree-passes-the-refusals real_tree_passes_the_refusals "$EVIDENCE_A"
scenario real-render-runs-only-what-the-overlay-names real_render_runs_only_what_the_overlay_names "$SOURCE_COMMIT"
scenario real-overlays-name-the-same-images real_overlays_name_the_same_images "$SOURCE_COMMIT"
scenario real-signers-accept-a-signature-from-that-key real_signers_accept_a_signature_from_that_key "$SOURCE_COMMIT"
scenario workflow-release-job workflow_release_job "$SOURCE_COMMIT"
scenario workflow-promote-job workflow_promote_job "$SOURCE_COMMIT"
scenario workflow-gate-runs-in-make-ci workflow_gate_runs_in_make_ci "$SOURCE_COMMIT"
scenario workflow-deploy-branch-check workflow_deploy_branch_check "$SOURCE_COMMIT"

ran=$((passed + failed))
[[ "$ran" -gt 0 ]] || die "no scenario's name contains '$FILTER${GATE_EXACT:-}'"
[[ "$failed" -eq 0 ]] || die "$failed of $ran gate scenario(s) failed"
ok "$ran gate scenario(s) passed"
