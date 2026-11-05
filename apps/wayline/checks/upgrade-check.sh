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

log "What the backend image replaces in upstream"
if grep -q 'LicenseRef-Plane-Commercial' "$SRC/apps/api/plane/utils/email.py"; then
  ok "this tag's email.py still has the commercial header, so backend/vendor/email.py is still needed"
else
  warn "this tag's email.py has no commercial header. Drop backend/vendor/ and its COPY in runtime/Dockerfile.backend, revisit D12, and see whether the image still needs flattening"
  status=1
fi
# The only thing any caller at v1.4.3 takes from it. check_image.py proves it again in the image.
others="$(grep -rhE '^[[:space:]]*(from plane\.utils\.email import|import plane\.utils\.email)' "$SRC/apps/api/plane" --include='*.py' | LC_ALL=C sort -u | grep -vxF 'from plane.utils.email import generate_plain_text_from_html' || true)"
[[ -z "$others" ]] || { warn "callers of email.py now take something else, so check it against backend/vendor/email.py: $others"; status=1; }
grep -qx 'PyJWT==2.13.0' "$SRC/apps/api/requirements/base.txt" \
  || { warn "upstream moved its PyJWT pin. Read backend/pyjwt-requirements.txt and the edit in backend/edit_strings.py"; status=1; }

log "What nginx may keep for a year"
for app in web admin; do
  if [[ -e "$SRC/apps/$app/public/assets" ]]; then
    warn "apps/$app/public/assets exists, so unhashed files land under assets/. Read the rule in runtime/nginx-$app.conf and checks/cache-names.sh"
    status=1
  else
    ok "apps/$app/public has no assets directory, so everything under assets/ is the bundler's"
  fi
done

if [[ "$status" -eq 0 ]]; then
  ok "upgrade check clean. Now build, then run scripts/ci/build-images.sh and checks/smoke-images.sh, and look at the app"
else
  warn "upgrade check found something to read above"
fi
exit "$status"
