#!/usr/bin/env bash
# Push main to the bare repo that plane-git serves to Argo CD. This is the only writer of that
# path. The working repo stays the source of truth, so the bare repo can be rebuilt at any time.
#
#   scripts/gitops-publish.sh                creates the bare repo if absent, then pushes main
#   SKIP_BACKUP=yes scripts/gitops-publish.sh   publishes a prod-sim digest change with no dump
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

guard_disk 1
cd "$ROOT"

BARE="$LOCAL_DIR/git/plane-platform.git"
PROD_SIM_MANIFESTS=gitops/environments/prod-sim/manifests.yaml

new="$(git rev-parse -q --verify refs/heads/main || true)"
[[ -n "$new" ]] || die "no main branch to publish: commit first"

if [[ ! -d "$BARE" ]]; then
  mkdir -p "$LOCAL_DIR/git"
  # plane-git runs as an unprivileged UID, so every object must stay world-readable under any umask.
  git init --quiet --bare --shared=0755 --initial-branch=main "$BARE"
  ok "created $BARE"
fi

old="$(git --git-dir="$BARE" rev-parse -q --verify refs/heads/main || true)"
if [[ "$old" == "$new" ]]; then
  ok "main is already published at ${new:0:12}"
  exit 0
fi

# A promotion merged on GitHub reaches the cluster here, not in the workflow, which cannot talk to
# the cluster. So this is where such a promotion must take the dump the contract requires.
if [[ -n "$old" && "${SKIP_BACKUP:-}" != yes ]] && git cat-file -e "$old" 2>/dev/null &&
  git diff "$old" "$new" -- "$PROD_SIM_MANIFESTS" | grep -qE '^[-+].*@sha256:'; then
  log "This publish changes a prod-sim image, so taking a backup first"
  "$ROOT/scripts/backup.sh" prod-sim || die "backup failed, nothing was published. SKIP_BACKUP=yes overrides."
fi

# Plain push on purpose: a non-fast-forward means history was rewritten, and Argo CD would then
# follow that rewrite with no record of it. Reverts are the way back.
git push --quiet "$BARE" refs/heads/main:refs/heads/main ||
  die "push refused. If main was rewritten, restore it or delete $BARE to republish from scratch."
ok "published main ${new:0:12} to $BARE"

current="$(git symbolic-ref --quiet --short HEAD || true)"
[[ "$current" == main ]] || warn "HEAD is on ${current:-a detached commit}: main was published, not this checkout"
