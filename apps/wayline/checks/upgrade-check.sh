#!/usr/bin/env bash
# Copyright (c) 2026 Bereket Abera
# SPDX-License-Identifier: AGPL-3.0-only
#
# `make wayline-upgrade-check`: what needs reading after UPSTREAM moves, with no build. Applies overlay and patches
# (which runs the overlay lock and image checks), then token-diff and contrast, then compares what this
# directory derived from upstream's Dockerfiles and nginx configs against the new versions. Image checks are
# separate because they need built images: scripts/ci/build-images.sh, then checks/smoke-images.sh.
#
#   apps/wayline/checks/upgrade-check.sh
# shellcheck source=../scripts/lib.sh
source "$(dirname "$0")/../scripts/lib.sh"

require_tools git rsync node
status=0
WAYLINE_SKIP_CODEMOD=yes "$WAYLINE/scripts/apply.sh" || status=1
node "$WAYLINE/checks/token-diff.mjs" "$SRC" || status=1
node "$WAYLINE/checks/contrast.mjs" "$SRC/packages/tailwind-config/variables.css" || status=1

log "Files ours were derived from"
while IFS=$'\t' read -r kind blob path; do
  [[ "$kind" == origin ]] || continue
  now="$(wgit -C "$UPSTREAM_CACHE" rev-parse -q --verify "$UPSTREAM_COMMIT:$path" 2>/dev/null || true)"
  if [[ "${now:--}" == "$blob" ]]; then
    ok "$path unchanged"
  else
    warn "$path changed upstream ($blob to ${now:-gone}). Read it, carry anything needed into runtime/ or scripts/build.sh, then overlay-lock.sh --update"
    status=1
  fi
done <"$OVERLAY_LOCK"

log "VITE_* values in scripts/build.sh against upstream's Dockerfiles"
for spec in web:apps/web/Dockerfile.web admin:apps/admin/Dockerfile.admin space:apps/space/Dockerfile.space; do
  app="${spec%%:*}"; file="${spec#*:}"
  [[ -f "$SRC/$file" ]] || { warn "$file is gone upstream"; status=1; continue; }
  for var in $(sed -nE 's/^(ENV|ARG) +(VITE_[A-Z_]+).*/\2/p' "$SRC/$file" | LC_ALL=C sort -u); do
    grep -q "\b$var=" "$WAYLINE/scripts/build.sh" || { warn "$app: upstream sets $var and scripts/build.sh does not"; status=1; }
  done
done

if [[ "$status" -eq 0 ]]; then
  ok "upgrade check clean. Now build, then run scripts/ci/build-images.sh and checks/smoke-images.sh, and look at the app"
else
  warn "upgrade check found something to read above"
fi
exit "$status"
