#!/usr/bin/env bash
# Changing tracked files in a checkout where other work goes on at the same time. promote.sh and
# rollback.sh edit the overlay, stage it and commit, and other commits are made in this same checkout, under the
# lock below. A plain `git add` or a `git status` takes .git/index.lock for a moment and knows nothing
# of that lock, so anything writing the index has to wait for that too. Source this after
# scripts/lib/common.sh, from inside the repository.

COMMIT_LOCK_HELD=no

# Held from before the first edit until the commit, so nobody else's `git commit` can take a half-made
# change, and never during a dump or a publish, which can take minutes. Waiting is normal. It gives up
# after COMMIT_LOCK_WAIT seconds, because a process that was killed leaves the directory behind.
take_commit_lock() {
  local waited=0 limit="${COMMIT_LOCK_WAIT:-300}"
  COMMIT_LOCK="$(git rev-parse --git-common-dir)/agent-commit.lockdir"
  until mkdir "$COMMIT_LOCK" 2>/dev/null; do
    if [[ "$waited" -ge "$limit" ]]; then
      die "$COMMIT_LOCK is still there after ${limit}s, so this changed nothing. If no commit is running in this checkout it was left behind: remove it with rmdir $COMMIT_LOCK and run this again."
    fi
    if [[ $((waited % 30)) -eq 0 ]]; then log "Waiting for $COMMIT_LOCK, because another commit is under way in this checkout. Gives up at ${limit}s."; fi
    sleep 2
    waited=$((waited + 2))
  done
  COMMIT_LOCK_HELD=yes
}

release_commit_lock() {
  if [[ "$COMMIT_LOCK_HELD" == yes ]]; then
    COMMIT_LOCK_HELD=no
    rmdir "$COMMIT_LOCK" || warn "could not remove $COMMIT_LOCK, so commits here will wait for it: rmdir $COMMIT_LOCK"
  fi
}

# A git operation someone left unfinished here. A commit of named paths would finish a revert in whatever
# state it is, and git refuses one during a merge or a cherry-pick. Prints its marker, or nothing.
git_operation_under_way() {
  local state
  for state in REVERT_HEAD MERGE_HEAD CHERRY_PICK_HEAD; do
    if [[ -e "$(git rev-parse --git-path "$state")" ]]; then
      printf '%s\n' "$state"
      return 0
    fi
  done
}

# Waits for no longer than INDEX_LOCK_WAIT seconds. If the file is still there then, git's own error
# says what it is and what to do about it.
wait_for_index() {
  local lock waited=0 limit="${INDEX_LOCK_WAIT:-10}"
  lock="$(git rev-parse --git-path index.lock)"
  while [[ -e "$lock" && "$waited" -lt "$limit" ]]; do
    sleep 1
    waited=$((waited + 1))
  done
}

# Runs git once the index is free, and once more if it still lost the race for it. Anything else that
# fails, a commit hook for one, is not tried twice. It prints git's error if it gives up.
git_when_index_free() { # git_when_index_free <git arguments...>
  local output
  for _ in 1 2; do
    wait_for_index
    if output="$(git "$@" 2>&1)"; then
      if [[ -n "$output" ]]; then printf '%s\n' "$output"; fi
      return 0
    fi
    [[ "$output" == *index.lock* ]] || break
  done
  printf '%s\n' "$output" >&2
  return 1
}

# Puts these paths back as HEAD has them, in the index and on disk, and touches nothing else. A path
# with nothing to put back is left out, so a held index cannot fail what has nothing to do. A path HEAD
# does not have goes, because git restore calls that an error, which is what a revert leaves behind when
# the commit it reverts changed a file a later commit removed.
restore_from_head() { # restore_from_head <path...>
  local path status=0
  for path in "$@"; do
    if [[ -n "$(git status --porcelain -- "$path")" ]]; then
      if git cat-file -e "HEAD:$path" 2>/dev/null; then
        git_when_index_free restore --source=HEAD --staged --worktree -- "$path" || status=1
      else
        git_when_index_free rm --force --quiet --cached --ignore-unmatch -- "$path" || status=1
        rm -f -- "$path" || status=1
      fi
    fi
  done
  return "$status"
}
