#!/usr/bin/env bash
# Undo the most recent promotion of an environment with `git revert`, then publish, so Git stays
# the source of truth and auto-sync stays on. Run it again to step back one promotion further.
#
#   scripts/rollback.sh dev
#   scripts/rollback.sh prod-sim CONFIRM=yes
#
# This rolls back images, not the database: migrations are forward-only, and old code starts
# against the newer schema with no warning. The dump taken before a prod-sim promotion is the
# way back for data, through make restore.
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

usage() { die "usage: $0 dev|prod-sim [CONFIRM=yes]"; }

for arg in "$@"; do
  case "$arg" in
    dev | prod-sim) ENV="$arg" ;;
    ENV=* | CONFIRM=* | SKIP_BACKUP=*) export "${arg?}" ;;
    *) usage ;;
  esac
done
ENV="${ENV:-}"
[[ "$ENV" == dev || "$ENV" == prod-sim ]] || usage

guard_disk 1
cd "$ROOT"

OVERLAY="helm/plane/overlays/$ENV"
RENDERED="gitops/environments/$ENV/manifests.yaml"

[[ "$(git symbolic-ref --quiet --short HEAD || true)" == main ]] || die "roll back from main: gitops-publish pushes main"
[[ -z "$(git status --porcelain -- "$OVERLAY" "$RENDERED")" ]] || die "$OVERLAY or $RENDERED has uncommitted changes"

# A squash merge on GitHub may drop the trailer but keeps the subject, so match either.
promotions="$(git log -E --format=%H \
  --grep="^Promote-Env: $ENV\$" --grep="^promote\\($ENV\\):" -- "$OVERLAY")"
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

if ! git revert --no-edit "$target" >/dev/null; then
  git revert --abort || true
  die "the revert conflicts with a later change to $OVERLAY. Nothing changed. Resolve it by hand."
fi

# A later commit may have changed what the overlay renders to, so the reverted file can be stale.
"$ROOT/scripts/render.sh"
if ! git diff --quiet -- "$RENDERED"; then
  git add -- "$RENDERED"
  git commit --quiet --amend --no-edit -- "$RENDERED"
fi
ok "committed $(git rev-parse --short HEAD): $(git log -1 --format=%s)"

"$ROOT/scripts/gitops-publish.sh"
