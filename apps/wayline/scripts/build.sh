#!/usr/bin/env bash
# Copyright (c) 2026 Bereket Abera
# SPDX-License-Identifier: AGPL-3.0-only
#
# Native build of the frontends, assembled into .build/wayline-dist/{web,admin,space,backend}, which
# are the Docker contexts. Never run upstream's Dockerfiles here: they cost about 5 GiB in the VM.
#
#   apps/wayline/scripts/build.sh
#   WAYLINE_APPS="web admin" apps/wayline/scripts/build.sh     subset; leak-scan covers that subset
#
# WAYLINE_TURBO_CONCURRENCY (4) and WAYLINE_HEAP_MB (3072) suit the laptop. images.yml sets both lower for its runner.
#
# Steps: apply, token-diff, contrast, source-links, pnpm install, one turbo build per app, leak-scan,
# bundle checks, assemble. Each context ends up with its licence texts, and $DIST/SOURCE.<app> records the
# commit that built it, which scripts/ci/build-images.sh turns into the image's /source link.
#
# Every tool runs under env -i, because each vite.config.ts embeds every VITE_* it can see into the
# bundle, so a stray variable in a developer's shell would ship. Per-app values match upstream's
# Dockerfiles, except that VITE_WEBSITE_URL and VITE_SUPPORT_EMAIL carry no invented addresses.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

APPS="${WAYLINE_APPS:-web admin space backend}"
# Exact version, shared with .github/workflows/images.yml through this file.
NODE_VERSION="$(cat "$WAYLINE/.node-version")"
NODE_MAJOR="${NODE_VERSION%%.*}"
TURBO_CONCURRENCY="${WAYLINE_TURBO_CONCURRENCY:-4}"
HEAP_MB="${WAYLINE_HEAP_MB:-3072}"

guard_disk
acquire_build_lock

# ---- toolchain ----------------------------------------------------------------------------------
if [[ "$(node -v 2>/dev/null | sed 's/^v\([0-9]*\).*/\1/')" != "$NODE_MAJOR" ]]; then
  if [[ -s "$HOME/.nvm/nvm.sh" ]]; then
    set +eu
    # shellcheck disable=SC1091
    source "$HOME/.nvm/nvm.sh" >/dev/null
    nvm use "$NODE_MAJOR" >/dev/null
    set -eu
  fi
fi
node_version="$(node -v 2>/dev/null || echo none)"
[[ "$node_version" == "v$NODE_MAJOR."* ]] \
  || die "Node $NODE_MAJOR is required (upstream engines and Dockerfiles), found $node_version. Install it with: nvm install $NODE_MAJOR"
[[ "$node_version" == "v$NODE_VERSION" ]] || warn "CI builds with Node $NODE_VERSION and this is $node_version, so bundles may differ"
NODE_BIN="$(dirname "$(command -v node)")"
command -v corepack >/dev/null || die "corepack not found next to node in $NODE_BIN"
log "Node $node_version"

mkdir -p "$BUILD_DIR/home" "$BUILD_DIR/corepack" "$BUILD_DIR/pnpm-store" "$BUILD_DIR/turbo-cache" "$BUILD_DIR/bin"
# Turbo looks for a pnpm binary on PATH. These shims go to .build/bin, not next to the user's node.
corepack enable --install-directory "$BUILD_DIR/bin" pnpm

# clean_env [KEY=VALUE...] -- command: run with nothing inherited from the caller's environment.
clean_env() {
  local vars=(
    "PATH=$BUILD_DIR/bin:$NODE_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
    "HOME=$BUILD_DIR/home"
    "XDG_CACHE_HOME=$BUILD_DIR/home/.cache"
    "XDG_DATA_HOME=$BUILD_DIR/home/.local/share"
    "XDG_STATE_HOME=$BUILD_DIR/home/.local/state"
    "XDG_CONFIG_HOME=$BUILD_DIR/home/.config"
    "LANG=en_US.UTF-8"
    "TERM=dumb"
    "CI=1"
    "COREPACK_HOME=$BUILD_DIR/corepack"
    "COREPACK_ENABLE_DOWNLOAD_PROMPT=0"
    "PNPM_HOME=$BUILD_DIR/home/.pnpm-home"
    "NODE_OPTIONS=--max-old-space-size=$HEAP_MB"
    "TURBO_TELEMETRY_DISABLED=1"
    "DO_NOT_TRACK=1"
    "NEXT_TELEMETRY_DISABLED=1"
    "HUSKY=0"
    "TURBO_CACHE_DIR=$BUILD_DIR/turbo-cache"
  )
  while [[ "${1:-}" != "--" ]]; do vars+=("$1"); shift; done
  shift
  env -i "${vars[@]}" "$@"
}

# ---- source -------------------------------------------------------------------------------------
"$WAYLINE/scripts/apply.sh"

log "Token diff and contrast"
node "$WAYLINE/checks/token-diff.mjs" "$SRC"
node "$WAYLINE/checks/contrast.mjs" "$SRC/packages/tailwind-config/variables.css"
node "$WAYLINE/checks/source-links.mjs" "$SRC"

cd "$SRC"
pnpm_version="$(clean_env -- pnpm --version)"
log "pnpm $pnpm_version"

log "pnpm install"
clean_env -- pnpm install --frozen-lockfile --prefer-offline \
  --store-dir "$BUILD_DIR/pnpm-store" \
  --filter . --filter 'web...' --filter 'admin...' --filter 'space...'

# Values from apps/{web,admin,space}/Dockerfile.*.
COMMON_VITE=(
  VITE_API_BASE_URL= VITE_ADMIN_BASE_URL= VITE_ADMIN_BASE_PATH=/god-mode
  VITE_LIVE_BASE_URL= VITE_LIVE_BASE_PATH=/live VITE_SPACE_BASE_URL= VITE_SPACE_BASE_PATH=/spaces
  VITE_WEB_BASE_URL=
)
# /source is served by the web image and reachable from all three base paths. No support address is
# invented: the empty value hits the "contact your administrator" branch upstream already has.
ADMIN_SPACE_VITE=(
  NODE_ENV=production VITE_API_BASE_PATH=/api VITE_WEB_BASE_PATH= VITE_WEBSITE_URL=/source VITE_SUPPORT_EMAIL=
)

build_app() {
  local app="$1"; shift
  log "turbo build $app"
  clean_env "${COMMON_VITE[@]}" "$@" -- pnpm turbo run build --filter="$app" \
    --concurrency="$TURBO_CONCURRENCY" --output-logs=errors-only
}

wants() { [[ " $APPS " == *" $1 "* ]]; }
wants web && build_app web
wants admin && build_app admin "${ADMIN_SPACE_VITE[@]}"
wants space && build_app space "${ADMIN_SPACE_VITE[@]}"

# ---- checks -------------------------------------------------------------------------------------
"$WAYLINE/checks/leak-scan.sh" $APPS
for app in web admin space; do
  wants "$app" && "$WAYLINE/checks/font-urls.sh" "$app"
  wants "$app" && "$WAYLINE/checks/bundle-art.sh" "$app"
done
for app in web admin; do
  wants "$app" && "$WAYLINE/checks/cache-names.sh" "$app"
done

# ---- assemble -----------------------------------------------------------------------------------
log "Assemble $DIST"
mkdir -p "$DIST"
# AGPL section 4 and OFL 1.1: the licences travel with each copy of the program and the fonts.
# Names end in .txt so nginx serves them as text.
licences() {
  mkdir -p "$1/licenses"
  cp "$ROOT/LICENSE" "$1/licenses/LICENSE.txt"
  cp "$ROOT/COPYRIGHT.txt" "$1/licenses/COPYRIGHT.txt"
  cp "$ROOT/NOTICE.md" "$1/licenses/NOTICE.txt"
  cp "$WAYLINE/MODIFICATIONS.md" "$1/licenses/MODIFICATIONS.txt"
  cp "$OVERLAY/packages/tailwind-config/fonts/OFL-InstrumentSans.txt" "$OVERLAY/packages/tailwind-config/fonts/OFL-JetBrainsMono.txt" "$1/licenses/"
}
if wants web; then
  rm -rf "${DIST:?}/web"; mkdir -p "$DIST/web"
  cp -R "$SRC/apps/web/build/client" "$DIST/web/client"
  cp "$WAYLINE/runtime/nginx-web.conf" "$DIST/web/nginx.conf"
fi
if wants admin; then
  rm -rf "${DIST:?}/admin"; mkdir -p "$DIST/admin"
  cp -R "$SRC/apps/admin/build/client" "$DIST/admin/client"
  cp "$WAYLINE/runtime/nginx-admin.conf" "$DIST/admin/nginx.conf"
fi
if wants space; then
  rm -rf "${DIST:?}/space"; mkdir -p "$DIST/space/wayline"
  cp -R "$SRC/apps/space/build" "$DIST/space/build"
  cp "$WAYLINE/runtime/space-deps.mjs" "$DIST/space/wayline/"
fi
if wants backend; then
  rm -rf "${DIST:?}/backend"; mkdir -p "$DIST/backend"
  # Upstream's templates are already in the base image, so the context holds only what leak-scan has read.
  "$WAYLINE/scripts/assemble-backend.sh" "$SRC" "$DIST/backend"
fi
for app in $APPS; do
  licences "$DIST/$app"
  write_source_stamp "$DIST/SOURCE.$app"
  log "$app built from $(paste -sd' ' "$DIST/SOURCE.$app")"
done
du -sh "$DIST"/* 2>/dev/null || true
ok "Build complete for: $APPS"
