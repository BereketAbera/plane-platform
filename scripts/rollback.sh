#!/usr/bin/env bash
# Undo the most recent promotion of an environment with `git revert`, then publish, so Git stays
# the source of truth and auto-sync stays on. Run it again to step back one promotion further.
#
#   scripts/rollback.sh dev
#   scripts/rollback.sh prod-sim CONFIRM=yes
#
# This is the emergency path, so it does not depend on what may be broken:
# - A rollback of prod-sim publishes with SKIP_BACKUP=yes, so a failing backup cannot strand the revert
#   on main, and with SKIP_DEV_CHECK, because it must not need plane-dev to be healthy. gitops-publish
#   logs that, and the revert commit says so in a trailer.
# - A rollback of dev needs neither, because a publish that moves no image in prod-sim asks the cluster
#   nothing. A publish is all of main, though, so if main holds a change that does move one, and Argo CD
#   has not read it, this stops before reverting and names it. make rollback ENV=prod-sim withdraws it.
#   OVERRIDE_DEV_CHECK="<reason>" goes on instead and is logged, and that publish still asks plane-dev,
#   which the same reason gets past, and takes the dump unless SKIP_BACKUP=yes.
# - prod-sim gets one dump of its own first, which may fail or run out of time without stopping the
#   rollback. SKIP_BACKUP=yes leaves it out, and ROLLBACK_DUMP_TIMEOUT sets the limit in seconds.
# - A revert that never reached Argo CD is published by the next run, instead of a second promotion
#   being reverted, unless a promotion newer than it waits too. That one is what this run reverts.
# - A promotion that never reached Argo CD can have something else waiting under it. A publish is all of
#   main, so withdrawing only the newest would send the rest to prod-sim under the waiver above, with no
#   check and no dump. So this stops before that and names them.
# - A later change beside an image line makes the revert conflict in the rendered file. That file is
#   generated, so rendering replaces it and the rollback goes on. A conflict anywhere else stops it.
# - A promotion that was already put back by hand is reported as undone, and main is still published.
#
# If it stops, it undoes the revert it started and touches nothing else, so what someone else has
# staged or edited in this checkout stays as it was. It takes the commit lock in lib/commit-lock.sh
# from before the revert until the commit.
#
# This rolls back images, not the database: migrations are forward-only, and old code starts
# against the newer schema with no warning. The dump taken before a prod-sim promotion is the
# way back for data, through make restore. The dump taken here holds the newer schema, so after a
# rollback BACKUP=latest names the wrong one. The output names the dump to use: the newest from before
# the promotion first went out, which gitops-publish records. A promotion that never reached Argo CD
# moved nothing, so then the output says there is nothing to restore, and names no dump.
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
# shellcheck source=lib/dev-check.sh
source "$(dirname "$0")/lib/dev-check.sh"
# shellcheck source=lib/commit-lock.sh
source "$(dirname "$0")/lib/commit-lock.sh"

usage() { die "usage: $0 dev|prod-sim [CONFIRM=yes] [SKIP_BACKUP=yes] [OVERRIDE_DEV_CHECK=reason]"; }

for arg in "$@"; do
  case "$arg" in
    dev | prod-sim) ENV="$arg" ;;
    ENV=* | CONFIRM=* | SKIP_BACKUP=* | ROLLBACK_DUMP_TIMEOUT=* | OVERRIDE_DEV_CHECK=*) export "${arg?}" ;;
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
REVERT_HEAD_FILE="$(git rev-parse --git-path REVERT_HEAD)"
if [[ "$ENV" == dev ]]; then OTHER_RENDERED=gitops/environments/prod-sim/manifests.yaml; else OTHER_RENDERED=gitops/environments/dev/manifests.yaml; fi

[[ "$(git symbolic-ref --quiet --short HEAD || true)" == main ]] || die "roll back from main: gitops-publish pushes main"
# So any revert in this checkout from here on is this run's, and stopping can clear it.
refuse_what_is_under_way() {
  local under_way
  under_way="$(git_operation_under_way)"
  if [[ "$under_way" == REVERT_HEAD ]]; then
    die "a revert of $(git log -1 --format='%h %s' REVERT_HEAD) is under way in this checkout, so this changed nothing. If it is an earlier run's, git status shows what it left: put those paths back with git restore --source=HEAD --staged --worktree -- <path>, run git revert --quit, then run this again."
  elif [[ -n "$under_way" ]]; then
    die "$under_way says a git operation is under way in this checkout, and a revert cannot be committed beside it, so this changed nothing. Finish it or abort it first."
  fi
}
refuse_what_is_under_way
[[ -z "$(git status --porcelain -- "$OVERLAY" "$RENDERED")" ]] || die "$OVERLAY or $RENDERED has uncommitted changes"

# A squash merge on GitHub may drop the trailer but keeps the subject, so match either.
promotions="$(git log -E --format=%H \
  --grep="^Promote-Env: $ENV\$" --grep="^promote\\($ENV\\):" -- "$OVERLAY")"

DEV_CHECK_WAIVER="an emergency path must not need plane-dev to be healthy"

publish() { # publish <the commit being reverted> <the commit that has to reach Argo CD>
  local status=0
  if [[ "$ENV" == prod-sim ]]; then
    # With both skips gitops-publish does not touch the cluster, which may be what is broken.
    log "Publishing with SKIP_BACKUP=yes and SKIP_DEV_CHECK: the publish takes no dump and does not ask plane-dev"
    SKIP_BACKUP=yes SKIP_DEV_CHECK="rollback of ${1:0:12}: $DEV_CHECK_WAIVER" "$ROOT/scripts/gitops-publish.sh" || status=$?
  else
    "$ROOT/scripts/gitops-publish.sh" || status=$?
  fi
  [[ "$status" -eq 0 ]] || die "$(git log -1 --format='%h %s' "$2") is on main but did not reach Argo CD. Fix the cause and run this again: it publishes that and reverts nothing else."
}

reverted_by() { # reverted_by <commit>: the commit it reverts, if any
  git log -1 --format=%B "$1" | sed -n 's/^This reverts commit \([0-9a-f]\{40\}\).*/\1/p'
}

# Names are UTC timestamps, so they sort by time, and a dump's name is when it started. A dump from the
# same second as a publish cannot hold what that publish did, because Argo CD had not read it yet.
newest_dump() { # newest_dump [<time>]: the newest finished backup, from no later than that time
  local dir name latest="${1:-99999999T999999Z}" newest=""
  for dir in "$BACKUPS"/*; do
    name="$(basename "$dir")"
    if [[ -f "$dir/manifest.json" && "$name" =~ ^[0-9]{8}T[0-9]{6}Z$ && ! "$name" > "$latest" ]]; then newest="$name"; fi
  done
  printf '%s' "$newest"
}

dumps_after() { # dumps_after <time>: the finished backups from later than that time, on one line
  local dir name names=""
  for dir in "$BACKUPS"/*; do
    name="$(basename "$dir")"
    if [[ -f "$dir/manifest.json" && "$name" =~ ^[0-9]{8}T[0-9]{6}Z$ && "$name" > "$1" ]]; then names+="${names:+ }$name"; fi
  done
  printf '%s' "$names"
}

# When the publish that first sent this commit went out. Prints nothing if the record cannot say: the first
# entry holding it may have started from a bare repository that had it already, or had nothing at all, so
# it first went out before the record began.
first_published_at() { # first_published_at <commit>
  local at old new
  [[ -f "$PUBLISH_LOG" ]] || return 0
  while read -r at old new; do
    git merge-base --is-ancestor "$1" "$new" 2>/dev/null || continue
    if [[ "$old" != - ]] && ! git merge-base --is-ancestor "$1" "$old" 2>/dev/null; then printf '%s' "$at"; fi
    return 0
  done <"$PUBLISH_LOG"
}

# Which dump takes prod-sim back to before a promotion. It goes by when the promotion first went out, not by
# its commit: a refused publish leaves the commit on main, and the run that later sends it takes a newer
# dump just before it does, and restoring an older one loses the writes between the two. A promotion merged
# on GitHub also takes its dump at that publish. With no record of the publish, the commit is all there is.
RESTORE_FROM=""
RESTORE_WHEN=""
RESTORE_NOTE=""
find_restore_point() { # find_restore_point <promotion>: before this run's own dump, which is no way back
  local at committed later
  at="$(first_published_at "$1")"
  if [[ -n "$at" ]]; then
    RESTORE_FROM="$(newest_dump "$at")"
    RESTORE_WHEN="the publish that first sent $(git log -1 --format=%h "$1"), at $at"
  else
    committed="$(TZ=UTC git log -1 --date='format-local:%Y%m%dT%H%M%SZ' --format=%cd "$1")"
    RESTORE_FROM="$(newest_dump "$committed")"
    RESTORE_WHEN="$(git log -1 --format='%h from %cI' "$1")"
    later="$(dumps_after "$committed")"
    RESTORE_NOTE=" No record says when it first went out, so this goes by its commit. A promotion merged on GitHub, or sent by a later run after a refusal, took its dump at that publish, so for one of those the right dump is the one from just before it.${later:+ Finished since the commit: $later.}"
  fi
}

# Read just before a publish, because a dump takes minutes and someone else may publish meanwhile. A bare
# repository that is gone, or holds history unknown here, cannot say no, so the output still names a dump.
reached_argo() { # reached_argo <commit>: yes or no
  local now
  now="$(git --git-dir="$BARE" rev-parse -q --verify refs/heads/main 2>/dev/null || true)"
  if [[ -n "$now" ]] && git cat-file -e "$now" 2>/dev/null && ! git merge-base --is-ancestor "$1" "$now"; then
    echo no
  else
    echo yes
  fi
}

say_what_to_restore() { # say_what_to_restore <promotion> <whether it reached Argo CD before this publish>
  [[ "$ENV" == prod-sim ]] || return 0
  if [[ "$2" == no ]]; then
    ok "$(git log -1 --format=%h "$1") never reached Argo CD, so prod-sim's images and schema did not move. There is nothing to restore."
  elif [[ -n "$RESTORE_FROM" ]]; then
    warn "Images are back, the schema is not. To restore data use make restore ENV=prod-sim BACKUP=$RESTORE_FROM, the newest finished dump older than $RESTORE_WHEN.$RESTORE_NOTE BACKUP=latest may name the dump taken just now, which holds the newer schema."
  else
    warn "Images are back, the schema is not, and no finished dump older than $RESTORE_WHEN exists in ${BACKUPS#"$ROOT"/}.$RESTORE_NOTE"
  fi
}

# Withdrawing a promotion Argo CD never read should move nothing in prod-sim. If what would be left still moves
# it, something else waits on main, and this rollback's waiver would send that along with no check and no dump.
refuse_sending_what_waits() { # refuse_sending_what_waits <promotion> <what would be left on main>
  [[ "$ENV" == prod-sim && -n "$published" ]] || return 0
  git cat-file -e "$published" 2>/dev/null || return 0
  prod_sim_digests_move "$published" "$2" || return 0
  local waiting
  waiting="$(commits_moving_prod_sim "$published" "$2")"
  die "$(git log -1 --format=%h "$1") never reached Argo CD, and main holds more that moves prod-sim's images and has not gone out either: ${waiting//$'\n'/; }. A publish is all of main, so withdrawing only this one would send the rest to prod-sim with no check of plane-dev and no dump. Nothing changed. Take them all off with git revert, newest first, then run this again, which publishes those reverts."
}

published="$(git --git-dir="$BARE" rev-parse -q --verify refs/heads/main 2>/dev/null || true)"

# A rollback of dev has no business moving prod-sim, and a publish takes all of main. This comes first,
# so it also covers the next block, and an earlier run's revert that a new commit has since joined.
if [[ "$ENV" == dev ]] && prod_sim_digests_move "$published" HEAD; then
  moving="$(commits_moving_prod_sim "$published" HEAD)"
  warn "Main holds a change to prod-sim's images that Argo CD has not read, and a publish is all of main, so this rollback would send it to prod-sim:"
  sed 's/^/       /' <<<"$moving" >&2
  if [[ -z "${OVERRIDE_DEV_CHECK:-}" ]]; then
    die "Nothing changed. Withdraw it first, with make rollback ENV=prod-sim if it is a promotion and git revert if not. Or set OVERRIDE_DEV_CHECK=\"<reason>\" to send it along, which is logged, and that publish still asks plane-dev and takes the dump unless SKIP_BACKUP=yes."
  fi
  added=()
  while read -r digest; do added+=("$digest"); done < <(prod_sim_digests_added "$published" HEAD)
  record_dev_check overridden "$(override_reason "$OVERRIDE_DEV_CHECK")" "rollback of dev carries: ${moving//$'\n'/; }" ${added[@]+"${added[@]}"}
  warn "OVERRIDE_DEV_CHECK: sending it along. Logged in ${DEV_CHECK_LOG#"$ROOT"/}."
fi

# A revert of this environment's promotion that Argo CD has not been given yet: an earlier run
# committed it and then failed to publish. Reverting again would take out a second promotion.
if [[ -n "$published" ]] && git cat-file -e "$published" 2>/dev/null; then
  while read -r commit; do
    [[ -n "$commit" ]] || continue
    # A promotion newer than such a revert is what a rollback means now, and publishing would send it.
    if grep -qxF "$commit" <<<"$promotions"; then break; fi
    reverted="$(reverted_by "$commit")"
    if [[ -n "$reverted" ]] && grep -qxF "$reverted" <<<"$promotions"; then
      reached="$(reached_argo "$reverted")"
      if [[ "$reached" == no ]]; then refuse_sending_what_waits "$reverted" HEAD; fi
      log "$(git log -1 --format='%h %s' "$commit") is on main but was never published. Publishing it, and reverting nothing else."
      find_restore_point "$reverted"
      publish "$reverted" "$commit"
      ok "rollback of ${reverted:0:12} published. Run this again to step back one promotion further."
      say_what_to_restore "$reverted" "$reached"
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
if [[ "$(reached_argo "$target")" == no ]]; then refuse_sending_what_waits "$target" "$target^"; fi

# What the revert can touch. The render is here because rendering replaces it, whatever the commit did.
revert_paths=("$RENDERED")
while IFS= read -r -d '' path; do revert_paths+=("$path"); done < <(git diff-tree -z --no-commit-id --name-only -r "$target")

# A promotion can carry other files. Stopping must not take someone's edit in one of them with it.
refuse_edits_in_the_way() {
  local edited
  edited="$(git status --porcelain -- "${revert_paths[@]}")"
  [[ -z "$edited" ]] || die "the revert would touch files with uncommitted changes, so this changed nothing. Commit or put them back first: ${edited//$'\n'/; }"
}
refuse_edits_in_the_way

if [[ "$ENV" == prod-sim && "${CONFIRM:-}" != yes ]]; then
  if [[ "$(reached_argo "$target")" == no ]]; then
    warn "This promotion never reached Argo CD, so this only takes it off main."
  else
    warn "Images roll back, the database schema does not. See docs/runbooks for restoring the dump."
  fi
  [[ -t 0 ]] || die "prod-sim needs CONFIRM=yes when not run from a terminal"
  read -r -p "Revert this promotion in prod-sim? Type yes: " answer
  [[ "$answer" == yes ]] || die "not confirmed, nothing changed"
fi

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
# holds what the bad promotion left, for looking at later. The dump to restore from is an older one.
if [[ "$ENV" == prod-sim ]]; then
  find_restore_point "$target"
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

reverting=no

# Puts back only what the revert touched. git revert --abort is git reset --merge, which also deletes
# whatever else is staged in this checkout, and fails outright on a file with staged and unstaged edits.
undo_revert() {
  restore_from_head "${revert_paths[@]}" || return 1
  # Not when the revert never started, because --quit forgets any git operation under way.
  if [[ -e "$REVERT_HEAD_FILE" ]]; then git revert --quit || return 1; fi
  reverting=no
}

stop_revert() { # stop_revert <what happened> <what to do next>
  if undo_revert; then
    die "$1 Nothing changed. $2"
  fi
  reverting=no
  die "$1 The revert is still in this checkout, because git could not write the index. Once it can, clear it: git restore --source=HEAD --staged --worktree -- ${revert_paths[*]}, then git revert --quit. Then: $2"
}

on_exit() {
  local status=$?
  if [[ "$reverting" == yes && "$status" -ne 0 ]]; then
    undo_revert || warn "the revert is still in this checkout. Clear it: git restore --source=HEAD --staged --worktree -- ${revert_paths[*]}, then git revert --quit"
  fi
  release_commit_lock
}
trap on_exit EXIT
# bash does not run an EXIT trap on a signal it has no trap for, and from here this may hold the commit
# lock and a revert under way.
trap 'exit 130' INT
trap 'exit 143' TERM

# One commit holding the revert and any re-render. A later commit may have changed what the overlay
# renders to, so the reverted file can be stale, or conflict when that change sits beside an image line.
# It is generated and rendered next, so a conflict there means nothing and must not hold up this path.
# A conflict anywhere else stops it. The dump above took minutes, so the checks at the top may be stale.
take_commit_lock
refuse_what_is_under_way
refuse_edits_in_the_way
other_render_was_clean=no
if [[ -z "$(git status --porcelain -- "$OTHER_RENDERED")" ]]; then other_render_was_clean=yes; fi
wait_for_index
reverting=yes
if ! revert_errors="$(git revert --no-commit "$target" 2>&1 >/dev/null)"; then
  all_conflicts="$(git diff --name-only --diff-filter=U)"
  conflicts="$(grep -vxF "$RENDERED" <<<"$all_conflicts" || true)"
  if [[ -z "$all_conflicts" ]]; then
    printf '%s\n' "$revert_errors" >&2
    stop_revert "git could not start the revert of ${target:0:12}." "Run this again once the cause above is gone."
  elif [[ -n "$conflicts" ]]; then
    printf '%s\n' "$revert_errors" >&2
    stop_revert "the revert conflicts with a later change to ${conflicts//$'\n'/, }." "Resolve it by hand: git revert ${target:0:12}, fix the conflict, then make gitops-publish."
  fi
  log "The revert conflicts only in $RENDERED, which is generated, so rendering replaces it"
fi
render_status=0
"$ROOT/scripts/render.sh" || render_status=$?
# It writes both environments, and this is about one. If the other's render was stale it stays stale in
# Git, where make render and CI find it, and not as a change in this checkout that stops the next run.
if [[ "$other_render_was_clean" == yes ]]; then
  restore_from_head "$OTHER_RENDERED" || warn "$OTHER_RENDERED changed on disk and could not be put back: git restore -- $OTHER_RENDERED"
fi
if [[ "$render_status" -ne 0 ]]; then
  stop_revert "rendering after the revert failed." "Fix the render and run this again."
fi

# git add refuses a path the revert removed, and git commit a path that is nowhere any more, such as a
# file the promotion added and a later commit removed. So each gets only what it can take.
to_add=()
to_commit=()
for path in "${revert_paths[@]}"; do
  if [[ -e "$path" || -n "$(git ls-files -- "$path")" ]]; then
    to_add+=("$path")
    to_commit+=("$path")
  elif git cat-file -e "HEAD:$path" 2>/dev/null; then
    to_commit+=("$path")
  fi
done
# Named paths, so anything else someone had staged stays out of the revert.
if ! git_when_index_free add -- "${to_add[@]}"; then
  stop_revert "could not stage the revert." "Run this again once git can write the index."
fi

if git diff --cached --quiet -- "${to_commit[@]}"; then
  undo_revert || stop_revert "reverting ${target:0:12} would change nothing." "Run this again."
  release_commit_lock
  ok "$(git log -1 --format='%h %s' "$target") is already undone: reverting it would change nothing, so there is no new commit. To step back further, revert the promotion before it by hand with git revert, then make gitops-publish."
  reached="$(reached_argo "$target")"
  # It may have been put back by a commit nobody has published.
  publish "$target" "$(git rev-parse HEAD)"
  say_what_to_restore "$target" "$reached"
  exit 0
fi

# strip, because a conflict leaves comment lines in the message git prepared.
commit_flags=(--quiet --no-edit --cleanup=strip)
[[ "$ENV" != prod-sim ]] || commit_flags+=(--trailer "Promote-Dev-Check: not run: $DEV_CHECK_WAIVER")
if ! git_when_index_free commit "${commit_flags[@]}" -- "${to_commit[@]}"; then
  stop_revert "could not commit the revert." "Run this again once the cause above is gone."
fi
# Before the lock goes, so this names what this run made and not what someone commits next.
revert_commit="$(git rev-parse HEAD)"
reverting=no
release_commit_lock
ok "committed $(git rev-parse --short "$revert_commit"): $(git log -1 --format=%s "$revert_commit")"

reached="$(reached_argo "$target")"
publish "$target" "$revert_commit"
say_what_to_restore "$target" "$reached"
