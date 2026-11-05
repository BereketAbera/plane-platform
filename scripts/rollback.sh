#!/usr/bin/env bash
# Undo the most recent promotion of an environment with `git revert`, then publish, so Git stays
# the source of truth and auto-sync stays on. Run it again to step back one promotion further.
#
#   scripts/rollback.sh dev
#   scripts/rollback.sh prod-sim CONFIRM=yes
#
# This is the emergency path, so it does not depend on what may be broken:
# - It publishes with SKIP_BACKUP=yes, so a failing backup cannot strand the revert on main, and with
#   SKIP_DEV_CHECK, because a rollback of prod-sim must not need plane-dev to be healthy. gitops-publish
#   logs that, and the revert commit of a prod-sim rollback says so in a trailer.
# - prod-sim gets one dump of its own first, which may fail or run out of time without stopping the
#   rollback. SKIP_BACKUP=yes leaves it out, and ROLLBACK_DUMP_TIMEOUT sets the limit in seconds.
# - A revert that never reached Argo CD is published by the next run, instead of a second promotion
#   being reverted.
#
# This rolls back images, not the database: migrations are forward-only, and old code starts
# against the newer schema with no warning. The dump taken before a prod-sim promotion is the
# way back for data, through make restore. The dump taken here holds the newer schema, so after a
# rollback BACKUP=latest names the wrong one. The output names the dump to use.
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

usage() { die "usage: $0 dev|prod-sim [CONFIRM=yes] [SKIP_BACKUP=yes]"; }

for arg in "$@"; do
  case "$arg" in
    dev | prod-sim) ENV="$arg" ;;
    ENV=* | CONFIRM=* | SKIP_BACKUP=* | ROLLBACK_DUMP_TIMEOUT=*) export "${arg?}" ;;
    *) usage ;;
  esac
done
ENV="${ENV:-}"
[[ "$ENV" == dev || "$ENV" == prod-sim ]] || usage

guard_disk 1
cd "$ROOT"

OVERLAY="helm/plane/overlays/$ENV"
RENDERED="gitops/environments/$ENV/manifests.yaml"
BARE="$LOCAL_DIR/git/plane-platform.git"
BACKUPS="$LOCAL_DIR/backups/$ENV"

[[ "$(git symbolic-ref --quiet --short HEAD || true)" == main ]] || die "roll back from main: gitops-publish pushes main"
[[ -z "$(git status --porcelain -- "$OVERLAY" "$RENDERED")" ]] || die "$OVERLAY or $RENDERED has uncommitted changes"

# A squash merge on GitHub may drop the trailer but keeps the subject, so match either.
promotions="$(git log -E --format=%H \
  --grep="^Promote-Env: $ENV\$" --grep="^promote\\($ENV\\):" -- "$OVERLAY")"

DEV_CHECK_WAIVER="an emergency path must not need plane-dev to be healthy"

publish() { # publish <the commit being reverted>
  # With both skips gitops-publish does not touch the cluster, which may be what is broken.
  log "Publishing with SKIP_BACKUP=yes and SKIP_DEV_CHECK: the publish takes no dump and does not ask plane-dev"
  SKIP_BACKUP=yes SKIP_DEV_CHECK="rollback of ${1:0:12}: $DEV_CHECK_WAIVER" "$ROOT/scripts/gitops-publish.sh" ||
    die "the revert $(git rev-parse --short HEAD) is on main but did not reach Argo CD. Fix the cause and run this again: it publishes that revert and reverts nothing else."
}

reverted_by() { # reverted_by <commit>: the commit it reverts, if any
  git log -1 --format=%B "$1" | sed -n 's/^This reverts commit \([0-9a-f]\{40\}\).*/\1/p'
}

# A revert of this environment's promotion that Argo CD has not been given yet: an earlier run
# committed it and then failed to publish. Reverting again would take out a second promotion.
published="$(git --git-dir="$BARE" rev-parse -q --verify refs/heads/main 2>/dev/null || true)"
if [[ -n "$published" ]] && git cat-file -e "$published" 2>/dev/null; then
  while read -r commit; do
    [[ -n "$commit" ]] || continue
    reverted="$(reverted_by "$commit")"
    if [[ -n "$reverted" ]] && grep -qxF "$reverted" <<<"$promotions"; then
      log "$(git log -1 --format='%h %s' "$commit") is on main but was never published. Publishing it, and reverting nothing else."
      publish "$reverted"
      ok "rollback of ${reverted:0:12} published. Run this again to step back one promotion further."
      exit 0
    fi
  done < <(git rev-list "$published..refs/heads/main" -- "$OVERLAY")
fi

already_reverted="$(git log --format=%B | sed -n 's/^This reverts commit \([0-9a-f]\{40\}\).*/\1/p')"

target=""
while read -r commit; do
  [[ -n "$commit" ]] || continue
  if ! grep -qxF "$commit" <<<"$already_reverted"; then
    target="$commit"
    break
  fi
done <<<"$promotions"

[[ -n "$target" ]] || die "no promotion of $ENV left to roll back"
log "Rolling back: $(git log -1 --format='%h %s' "$target")"

if [[ "$ENV" == prod-sim && "${CONFIRM:-}" != yes ]]; then
  warn "Images roll back, the database schema does not. See docs/runbooks for restoring the dump."
  [[ -t 0 ]] || die "prod-sim needs CONFIRM=yes when not run from a terminal"
  read -r -p "Revert this promotion in prod-sim? Type yes: " answer
  [[ "$answer" == yes ]] || die "not confirmed, nothing changed"
fi

newest_dump() { # The newest finished backup. Names are UTC timestamps, so they sort by time.
  local dir newest=""
  for dir in "$BACKUPS"/*; do
    if [[ -f "$dir/manifest.json" && "$(basename "$dir")" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]; then newest="$(basename "$dir")"; fi
  done
  printf '%s' "$newest"
}

run_with_limit() { # run_with_limit <seconds> <command...>: fails if the command fails or outlives the limit
  local limit="$1" pid waited=0
  shift
  "$@" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [[ "$waited" -ge "$limit" ]]; then
      pkill -TERM -P "$pid" 2>/dev/null || true
      kill -TERM "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
}

# Only prod-sim, as with every other dump the contract requires. It runs before the revert, so it
# holds what the bad promotion left, for looking at later. The dump to restore from is the older one.
restore_from=""
if [[ "$ENV" == prod-sim ]]; then
  restore_from="$(newest_dump)"
  if [[ "${SKIP_BACKUP:-}" == yes ]]; then
    warn "SKIP_BACKUP=yes: no dump taken before this rollback"
  else
    limit="${ROLLBACK_DUMP_TIMEOUT:-300}"
    log "Taking a best-effort dump of prod-sim first, limited to ${limit}s. A failure here does not stop the rollback."
    if run_with_limit "$limit" "$ROOT/scripts/backup.sh" prod-sim; then
      ok "best-effort dump taken: $(newest_dump)"
    else
      warn "best-effort dump failed or ran out of time, so this rollback has no dump of its own. Going on. A backup Job may still be running in the cluster."
    fi
  fi
fi

# One commit holding the revert and any re-render, so a failure here leaves nothing behind. A later
# commit may have changed what the overlay renders to, so the reverted file can be stale, or conflict
# when that change sits beside an image line. It is generated and rendered next, so a conflict there
# means nothing and must not hold up this path. A conflict anywhere else stops it.
if ! revert_errors="$(git revert --no-commit "$target" 2>&1 >/dev/null)"; then
  if [[ "$(git diff --name-only --diff-filter=U)" != "$RENDERED" ]]; then
    printf '%s\n' "$revert_errors" >&2
    git revert --abort || true
    die "the revert conflicts with a later change to $OVERLAY. Nothing changed. Resolve it by hand."
  fi
  log "The revert conflicts only in $RENDERED, which is generated, so rendering replaces it"
fi
if ! "$ROOT/scripts/render.sh"; then
  git revert --abort || true
  die "rendering after the revert failed. Nothing changed."
fi
# Named paths, so anything else someone had staged stays out of the revert.
paths=("$RENDERED")
while read -r path; do paths+=("$path"); done < <(git diff-tree --no-commit-id --name-only -r "$target")
git add -- "${paths[@]}"
# strip, because a conflict leaves comment lines in the message git prepared.
commit_flags=(--quiet --no-edit --cleanup=strip)
[[ "$ENV" != prod-sim ]] || commit_flags+=(--trailer "Promote-Dev-Check: not run: $DEV_CHECK_WAIVER")
git commit "${commit_flags[@]}" -- "${paths[@]}"
ok "committed $(git rev-parse --short HEAD): $(git log -1 --format=%s)"

publish "$target"

if [[ "$ENV" == prod-sim ]]; then
  if [[ -n "$restore_from" ]]; then
    warn "Images are back, the schema is not. To restore data use make restore ENV=prod-sim BACKUP=$restore_from, the newest dump from before this rollback. Check that it predates $(git log -1 --format='%h from %cI' "$target"). BACKUP=latest may name the dump taken just now, which holds the newer schema."
  else
    warn "Images are back, the schema is not, and no finished dump from before this rollback exists in ${BACKUPS#"$ROOT"/}."
  fi
fi
