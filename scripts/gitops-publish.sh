#!/usr/bin/env bash
# Push main to the bare repo that plane-git serves to Argo CD. This is the only writer of that
# path. The working repo stays the source of truth, so the bare repo can be rebuilt at any time.
#
#   scripts/gitops-publish.sh                creates the bare repo if absent, then pushes main
#   SKIP_BACKUP=yes scripts/gitops-publish.sh   publishes a prod-sim digest change with no dump
#
# A publish that brings prod-sim a digest must have plane-dev Synced and Healthy with that digest in a
# ready container, as in promote.sh. SKIP_BACKUP does not change that. Three ways past it:
#   OVERRIDE_DEV_CHECK="<reason>"   runs the check and goes ahead if it fails, logging the reason
#   SKIP_DEV_CHECK="<reason>"       does not ask the cluster at all, and logs the reason. For rollback,
#                                   which must work while dev is broken, and has no other caller
#   no cluster in reach             the check is skipped, and this says so
# Both reasons go in .local/evidence-raw/promotion-overrides.log.
#
# Promotion covers image lines only. Any other change to prod-sim's rendered manifests gets a warning and
# is published: helm/plane/components/hardening and the chart are shared, so they reach both environments
# in one push.
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
# shellcheck source=lib/dev-check.sh
source "$(dirname "$0")/lib/dev-check.sh"

guard_disk 1
cd "$ROOT"

BARE="$LOCAL_DIR/git/plane-platform.git"
DEV_MANIFESTS=gitops/environments/dev/manifests.yaml
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
# the cluster. So this is where such a promotion must prove itself on plane-dev and take the dump the
# contract requires, in that order, so a refused publish costs no dump.
# grep reads to the end, not -q. With -q it stops at the first match, git dies of SIGPIPE on a large
# diff, and under pipefail the pipeline reads as no match, which would skip both.
if [[ -n "$old" ]] && git cat-file -e "$old" 2>/dev/null &&
  git diff "$old" "$new" -- "$PROD_SIM_MANIFESTS" | grep -E '^[-+].*@sha256:' >/dev/null; then
  # The digests on added lines. An image that was only removed brings nothing to prove.
  added=()
  while read -r digest; do added+=("$digest"); done < <(git diff "$old" "$new" -- "$PROD_SIM_MANIFESTS" |
    sed -n 's/^+.*@\(sha256:[a-f0-9]\{64\}\).*/\1/p' | sort -u)

  # A cluster with no prod-sim database has nothing running to protect or to dump, which is what make
  # up meets after make destroy. If kubectl cannot tell, go on, and the backup fails and stops this
  # publish. With both skips set nothing here asks the cluster anything, as rollback needs.
  database=not-asked
  if [[ -z "${SKIP_DEV_CHECK:-}" || "${SKIP_BACKUP:-}" != yes ]]; then
    database="$(kc --request-timeout=10s -n plane-prod-sim get statefulset plane-pgdb-wl --ignore-not-found -o name 2>/dev/null || echo unknown)"
  fi

  if [[ ${#added[@]} -gt 0 ]]; then
    if [[ -n "${SKIP_DEV_CHECK:-}" ]]; then
      record_dev_check not-run "$SKIP_DEV_CHECK" "" "${added[@]}"
      warn "plane-dev check not run for this publish: $SKIP_DEV_CHECK. Logged in ${DEV_CHECK_LOG#"$ROOT"/}."
    elif [[ -z "$database" ]]; then
      log "This publish changes a prod-sim image, but prod-sim has no database yet, so there is nothing running for the plane-dev check to protect"
    else
      log "This publish changes a prod-sim image, so plane-dev must have proven it"
      check_dev_proven "${added[@]}" || refuse_unproven_dev "Nothing was published."
    fi
  fi

  if [[ "${SKIP_BACKUP:-}" != yes ]]; then
    if [[ -n "$database" ]]; then
      log "This publish changes a prod-sim image, so taking a backup first"
      "$ROOT/scripts/backup.sh" prod-sim || die "backup failed, nothing was published. SKIP_BACKUP=yes overrides."
    else
      log "This publish changes a prod-sim image, but prod-sim has no database yet, so nothing to back up"
    fi
  fi
fi

# Everything above asks about image lines, because those are what make promote moves. Any other line in
# the rendered prod-sim file goes straight to prod-sim with this push, unchecked on plane-dev, and when it
# comes from what the overlays share, with no time in dev first. That is how those paths work, so this
# says so and goes on. It reads the render and not the paths, so a comment in the component stays quiet.
if [[ -n "$old" ]] && git cat-file -e "$old" 2>/dev/null; then
  beyond_images="$(git diff -U0 "$old" "$new" -- "$PROD_SIM_MANIFESTS" | grep -E '^[-+]' | grep -vE '^(---|\+\+\+) |^[-+][[:space:]-]*image: ' || true)"
  if [[ -n "$beyond_images" ]]; then
    reach=prod-sim
    git diff --quiet "$old" "$new" -- "$DEV_MANIFESTS" || reach="dev and prod-sim together"
    warn "publishing $(wc -l <<<"$beyond_images" | tr -d ' ') changed line(s) in prod-sim's manifests that are not images. Promotion does not cover them, so nothing checks them on plane-dev or takes a dump for them: they reach $reach with this push. Changed under helm/plane:"
    # sed reads to the end, for the same reason as the grep above.
    git diff --name-only "$old" "$new" -- helm/plane | sed -n '1,10s/^/       /p' >&2
  fi
fi

# ADR 0011: Argo CD reads this repository, not GitHub, so nothing below stops a commit that CI and
# review never saw. This flow works with no GitHub at all, so it warns and goes on. It compares with
# origin/main as last fetched, so a stale ref can only overstate the gap.
if git rev-parse -q --verify refs/remotes/origin/main >/dev/null; then
  ahead="$(git rev-list --count refs/remotes/origin/main..refs/heads/main)"
  if [[ "$ahead" -gt 0 ]]; then
    warn "publishing $ahead commit(s) on main that are not on origin/main, so GitHub CI and review have not seen them. Newest:"
    git log --format='       %h %s' -n 5 refs/remotes/origin/main..refs/heads/main >&2
  fi
else
  warn "origin/main is unknown here, so this cannot say whether GitHub CI and review saw these commits"
fi

# Plain push on purpose: a non-fast-forward means history was rewritten, and Argo CD would then
# follow that rewrite with no record of it. Reverts are the way back.
git push --quiet "$BARE" refs/heads/main:refs/heads/main ||
  die "push refused. If main was rewritten, restore it or delete $BARE to republish from scratch."
ok "published main ${new:0:12} to $BARE"

current="$(git symbolic-ref --quiet --short HEAD || true)"
[[ "$current" == main ]] || warn "HEAD is on ${current:-a detached commit}: main was published, not this checkout"
