#!/usr/bin/env bash
# Does deploy/plane-prod hold what a release left there? Read-only.
#
#   scripts/ci/check-deploy-branch.sh
#
# Exit 0 it does, or there is no branch yet. 1 it does not, and it says what differs. 2 the branch could not be read, which says nothing.
#
# GitHub Free has no protected branches for a private repository, so anyone with write access can push that branch, and so can a job
# with contents: write, whatever its comments say. Root and its children sync what it holds, so writing it amounts to cluster-admin.
# Nothing short of a paid plan or verification on the cluster prevents that. This only detects it, and by then Argo CD may have deployed
# it. check-deploy-branch.yml runs this each day, make remote-status runs it, and publish-release.sh refuses on the same comparison.
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=lib-release-branch.sh
source "$(dirname "$0")/lib-release-branch.sh"

[[ $# -eq 0 ]] || die "usage: $0, which reads origin's $BRANCH"
cd "$ROOT"

unreadable() { warn "$1, so this says nothing about $BRANCH"; exit 2; }

remote_tip="$(remote_git ls-remote origin "refs/heads/$BRANCH")" || unreadable "could not read origin"
TIP="${remote_tip%%[[:space:]]*}"
if [[ -z "$TIP" ]]; then
  ok "origin has no $BRANCH yet, so nothing has been released"
  exit 0
fi
remote_git fetch --quiet origin "+refs/heads/main:refs/remotes/origin/main" "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" || unreadable "could not fetch origin's main and $BRANCH"

foreign="$(git ls-tree -r --name-only "$TIP" | grep -vE "^(RELEASE\.json|$CLUSTER_TREE/.*|$ENVIRONMENT_TREE/.*)$" || true)"
[[ -z "$foreign" ]] || die "$BRANCH at $TIP holds more than a release does, so someone pushed it by hand: ${foreign//$'\n'/, }"
recorded="$(git cat-file blob "$TIP:RELEASE.json" 2>/dev/null | jq -r '.main_commit // ""' 2>/dev/null || true)"
[[ "$recorded" =~ ^[a-f0-9]{40}$ ]] || die "$BRANCH at $TIP has no RELEASE.json naming a main commit, so someone pushed it by hand"
git merge-base --is-ancestor "$recorded" refs/remotes/origin/main 2>/dev/null || die "$BRANCH at $TIP says it came from $recorded, which is not on origin's main"
different="$(release_trees_that_differ "$TIP" "$recorded")"
[[ -z "$different" ]] || die "$BRANCH at $TIP says it came from $recorded and differs from that commit under ${different//$'\n'/ and }, so someone pushed it by hand. Argo CD may have deployed it. Read: git diff $recorded $TIP -- ${different//$'\n'/ }"
ok "$BRANCH at ${TIP:0:12} holds what main ${recorded:0:12} released"
