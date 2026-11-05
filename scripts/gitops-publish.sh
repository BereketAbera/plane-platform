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
#   SKIP_DEV_CHECK="<reason>"       does not ask the cluster at all, and logs the reason. For a rollback
#                                   of prod-sim, which must work while dev is broken, and has no other caller
#   no cluster in reach             the check is skipped, and this says so
# Both reasons go in .local/evidence-raw/promotion-overrides.log.
#
# A publish is all of main, up to the commit it found when it started. So a dev change waits behind a
# prod-sim digest that is refused, and leaves with it, and a refusal names what it is waiting behind.
#
# Promotion covers image lines only. Any other change to prod-sim's rendered manifests gets a warning and
# is published: helm/plane/components/hardening and the chart are shared, so they reach both environments
# in one push. A digest changed by hand also gets a warning if make promote would have refused it.
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
# shellcheck source=lib/dev-check.sh
source "$(dirname "$0")/lib/dev-check.sh"

guard_disk 1
cd "$ROOT"

BARE="$LOCAL_DIR/git/plane-platform.git"
DEV_MANIFESTS=gitops/environments/dev/manifests.yaml
PROD_SIM_OVERLAY=helm/plane/overlays/prod-sim/kustomization.yaml

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
if prod_sim_digests_move "$old" "$new"; then
  moving="$(commits_moving_prod_sim "$old" "$new")"
  log "This publish moves prod-sim's images, through:"
  sed 's/^/       /' <<<"$moving"
  added=()
  while read -r digest; do added+=("$digest"); done < <(prod_sim_digests_added "$old" "$new")

  # make promote ties each digest to its image through what dev recorded. A change by hand never met
  # that, and the plane-dev check below is content with a digest that runs anywhere in dev, under any
  # image. CI has this check too and cannot block a merge. Only a warning: rollback uses this path.
  pairs=()
  while read -r name digest; do
    for added_digest in ${added[@]+"${added[@]}"}; do
      if [[ "$digest" == "$added_digest" ]]; then pairs+=("$name=$digest"); fi
    done
  done < <(git show "$new:$PROD_SIM_OVERLAY" | yq -r '.images[] | .name + " " + .digest')
  if [[ ${#pairs[@]} -gt 0 ]] && ! invariant="$("$ROOT/scripts/ci/check-promoted-digests.sh" "${pairs[@]}" 2>&1 >/dev/null)"; then
    warn "this publish moves a prod-sim image in a way make promote would refuse, so look at where that change came from:"
    sed 's/^/       /' <<<"$invariant" >&2
  fi

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
      if ! check_dev_proven "${added[@]}"; then
        if ! git diff --quiet "$old" "$new" -- "$DEV_MANIFESTS"; then
          warn "A publish is all of main, so the change to dev in this push is held behind what moves prod-sim: ${moving//$'\n'/; }. If that is a promotion, make rollback ENV=prod-sim withdraws it and publishes the rest. If not, git revert it."
        fi
        refuse_unproven_dev "Nothing was published."
      fi
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
beyond_images() { # beyond_images <render>: the lines this push changes in it that are not an image
  git diff -U0 "$old" "$new" -- "$1" | grep -E '^[-+]' | grep -vE '^(---|\+\+\+) |^[-+][[:space:]-]*image: ' || true
}
if [[ -n "$old" ]] && git cat-file -e "$old" 2>/dev/null; then
  prod_sim_lines="$(beyond_images "$PROD_SIM_MANIFESTS")"
  if [[ -n "$prod_sim_lines" ]]; then
    reach=prod-sim
    if [[ -n "$(beyond_images "$DEV_MANIFESTS")" ]]; then reach="dev and prod-sim together"; fi
    sources="$(git diff --name-only "$old" "$new" -- helm/plane)"
    what_changed="Changed under helm/plane:"
    if [[ -z "$sources" ]]; then
      what_changed="The render changed with no source change under helm/plane, so the next make render undoes this."
    fi
    warn "publishing $(wc -l <<<"$prod_sim_lines" | tr -d ' ') changed line(s) in prod-sim's manifests that are not images. Promotion does not cover them, so nothing checks them on plane-dev or takes a dump for them: they reach $reach with this push. $what_changed"
    if [[ -n "$sources" ]]; then
      sed -n '1,10s/^/       /p' <<<"$sources" >&2
      source_count="$(wc -l <<<"$sources" | tr -d ' ')"
      if [[ "$source_count" -gt 10 ]]; then printf '       and %d more\n' "$((source_count - 10))" >&2; fi
    fi
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
# follow that rewrite with no record of it. Reverts are the way back. It pushes the commit everything
# above looked at, because other work commits in this checkout, and a dump takes minutes. So a publish
# that lands during this one's dump also refuses this push, and what this one came to send has gone out.
if ! pushed="$(git push --quiet "$BARE" "$new:refs/heads/main" 2>&1)"; then
  now="$(git --git-dir="$BARE" rev-parse -q --verify refs/heads/main || true)"
  if [[ -n "$now" ]] && git merge-base --is-ancestor "$new" "$now" 2>/dev/null; then
    ok "another publish already sent ${new:0:12} while this one ran: Argo CD reads ${now:0:12}, which holds it"
    exit 0
  fi
  printf '%s\n' "$pushed" >&2
  die "push refused. If main was rewritten, restore it or delete $BARE to republish from scratch."
fi
if [[ -n "$pushed" ]]; then printf '%s\n' "$pushed" >&2; fi
ok "published main ${new:0:12} to $BARE"
# A promotion's dump comes just before the publish that first sends it, and that is not always near its
# commit, so make rollback ENV=prod-sim reads this to name the right dump. Without it, that goes by the commit.
printf '%s %s %s\n' "$(date -u +%Y%m%dT%H%M%SZ)" "${old:--}" "$new" >>"$PUBLISH_LOG" ||
  warn "could not record this publish in ${PUBLISH_LOG#"$ROOT"/}, so a rollback will go by the commit's time"

current="$(git symbolic-ref --quiet --short HEAD || true)"
[[ "$current" == main ]] || warn "HEAD is on ${current:-a detached commit}: main was published, not this checkout"
