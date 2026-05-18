#!/usr/bin/env bash
# Copyright (c) 2026 Bereket Abera
# SPDX-License-Identifier: AGPL-3.0-only
#
# Runs each frontend image by digest from .build/digests.tsv under the UID, memory limit, CPU limit and
# security settings of helm/plane/components/hardening, and checks what the chart and the ingress
# rely on. Needs no cluster, and removes its containers. The backend has its own in-image check, which
# this calls last. Exits non-zero if any check fails.
#
#   apps/wayline/checks/smoke-images.sh [digests.tsv]
# shellcheck source=../scripts/lib.sh
source "$(dirname "$0")/../scripts/lib.sh"

DIGESTS="${1:-$BUILD_DIR/digests.tsv}"
[[ -s "$DIGESTS" ]] || die "no digests at $DIGESTS, run scripts/ci/build-images.sh first"

failures=0
containers=()
cleanup() { [[ ${#containers[@]} -eq 0 ]] || docker rm -f "${containers[@]}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

pass() { printf 'PASS %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; failures=$((failures + 1)); }
check() { # check <label> <actual> <expected>
  if [[ "$2" == "$3" ]]; then pass "$1: $2"; else fail "$1: got '$2', expected '$3'"; fi
}
ref_of() { awk -F'\t' -v n="$1" '$1 == n { print $2 "@" $3 }' "$DIGESTS"; }

# start <name> <uid> <memory> <cpus> [docker args...]: sets $base to http://127.0.0.1:<published port>.
start() {
  local name="$1" uid="$2" memory="$3" cpus="$4" ref port
  shift 4
  ref="$(ref_of "$name")"
  [[ -n "$ref" ]] || die "$name is not in $DIGESTS"
  container="wayline-smoke-$name-$$"
  containers+=("$container")
  docker run -d --name "$container" --user "$uid:$uid" --memory "$memory" --cpus "$cpus" \
    --cap-drop ALL --security-opt no-new-privileges --publish 127.0.0.1::3000 "$@" "$ref" >/dev/null
  port="$(docker port "$container" 3000/tcp | head -1 | sed 's/.*://')"
  base="http://127.0.0.1:$port"
  printf '\n== %s: %s\n' "$name" "$ref"
  printf 'run as uid %s, memory %s, cpus %s, cap-drop ALL, no-new-privileges\n' "$uid" "$memory" "$cpus"
}

wait_http() { # wait_http <path> <seconds>
  local i=0
  until [[ "$(curl -s -o /dev/null -m 3 -w '%{http_code}' "$base$1")" == 200 ]]; do
    i=$((i + 1))
    if [[ $i -ge $2 ]]; then
      fail "$1 did not answer 200 within $2 s"
      docker logs "$container" 2>&1 | tail -20
      return 1
    fi
    sleep 1
  done
  pass "$1 answers 200 after about $i s"
}

code() { curl -s -o /dev/null -m 10 -w '%{http_code}' "$base$1"; }
ctype() { curl -s -o /dev/null -m 10 -w '%{content_type}' "$base$1"; }

# Follows the page's stylesheet, then one font of each family named in it.
check_assets() { # check_assets <page path> <asset prefix>
  local page="$1" prefix="$2" html css font
  html="$(curl -s -m 10 "$base$page")"
  css="$(printf '%s' "$html" | grep -oE "${prefix}[^\"']*globals[^\"']*\.css" | head -1)"
  [[ -n "$css" ]] || { fail "$page links no globals stylesheet under $prefix"; return; }
  check "stylesheet $css status" "$(code "$css")" 200
  # nginx sends text/css, and react-router-serve adds a charset.
  check "stylesheet content type" "$(ctype "$css" | sed 's/;.*//')" text/css
  for family in instrument-sans jetbrains-mono; do
    font="$(curl -s -m 10 "$base$css" | grep -oE "url\([^)]*${family}[^)]*\.woff2[^)]*\)" | head -1 | sed -E 's/^url\(//; s/\)$//; s/"//g')"
    [[ -n "$font" ]] || { fail "$css declares no $family font"; continue; }
    [[ "$font" == "$prefix"* ]] || fail "$font is not under $prefix"
    check "font $font status" "$(code "$font")" 200
    check "font content type" "$(ctype "$font")" font/woff2
  done
}

check_brand_html() { # check_brand_html <path>
  local html
  html="$(curl -s -m 15 "$base$1")"
  if printf '%s' "$html" | grep -q '<title>[^<]*Wayline'; then pass "$1 title names Wayline"; else fail "$1 title: $(printf '%s' "$html" | grep -o '<title>[^<]*' | head -1)"; fi
  if printf '%s' "$html" | grep -qE 'Plane|plane\.so|makeplane'; then
    if printf '%s' "$html" | grep -oE '.{0,20}(Plane|plane\.so|makeplane).{0,20}' | grep -vqE 'Built on Plane Community Edition'; then
      fail "$1 carries the upstream brand"
    else
      pass "$1 has only the permitted credit"
    fi
  else
    pass "$1 has no upstream brand"
  fi
}

report_process() {
  docker exec "$container" sh -c 'printf "uid in container: "; id -u'
  docker stats --no-stream --format 'memory after these requests: {{.MemUsage}}' "$container"
  if docker logs "$container" 2>&1 | grep -E 'Permission denied|\[(emerg|crit|alert)\]'; then
    fail "$1 logged permission or fatal errors"
  else
    pass "$1 logs show no permission or fatal errors"
  fi
}

# The chart's emptyDirs, as tmpfs. An emptyDir is world-writable, and Docker's tmpfs takes the mode of the
# directory it covers unless told otherwise.
# shellcheck disable=SC2054  # the commas are tmpfs options
NGINX_TMPFS=(--tmpfs /var/cache/nginx:size=32m,mode=1777 --tmpfs /run:size=1m,mode=1777 --tmpfs /tmp:size=8m,mode=1777)

# ---- web --------------------------------------------------------------------------------------
if [[ -n "$(ref_of web)" ]]; then
  start web 101 64m 0.1 "${NGINX_TMPFS[@]}"
  wait_http / 60 || true
  check_brand_html /
  check_assets / /assets/
  check "SPA route /some-workspace/projects/ status" "$(code /some-workspace/projects/)" 200
  index_sum="$(curl -s "$base/" | shasum -a 256)"
  spa_sum="$(curl -s "$base/some-workspace/projects/" | shasum -a 256)"
  check "SPA route serves index.html" "$spa_sum" "$index_sum"
  source_status="$(curl -s -o /dev/null -m 5 -w '%{http_code} %{redirect_url}' "$base/source")"
  printf '/source -> %s\n' "$source_status"
  case "$source_status" in
    "302 https://github.com/"*"/tree/"*) pass "/source is a 302 to the repository at a commit" ;;
    *) fail "/source: $source_status" ;;
  esac
  [[ -z "${WAYLINE_EXPECT_REF:-}" ]] || case "$source_status" in
    *"/tree/$WAYLINE_EXPECT_REF") pass "/source names commit $WAYLINE_EXPECT_REF" ;;
    *) fail "/source does not name $WAYLINE_EXPECT_REF" ;;
  esac
  check "manifest status" "$(code /site.webmanifest.json)" 200
  if curl -s "$base/site.webmanifest.json" | grep -q Wayline; then pass "manifest names Wayline"; else fail "manifest does not name Wayline"; fi
  check "X-Frame-Options" "$(curl -sI "$base/" | tr -d '\r' | awk -F': ' 'tolower($1) == "x-frame-options" { print $2 }')" DENY
  report_process web
  docker rm -f "$container" >/dev/null

  start web 101 64m 0.1
  if wait_http / 60; then pass "web also runs without the chart's emptyDirs"; fi
  docker rm -f "$container" >/dev/null
fi

# ---- admin ------------------------------------------------------------------------------------
if [[ -n "$(ref_of admin)" ]]; then
  start admin 101 64m 0.1 "${NGINX_TMPFS[@]}"
  wait_http /god-mode/ 60 || true
  check_brand_html /god-mode/
  check_assets /god-mode/ /god-mode/assets/
  check "SPA route /god-mode/general/ status" "$(code /god-mode/general/)" 200
  index_sum="$(curl -s "$base/god-mode/" | shasum -a 256)"
  spa_sum="$(curl -s "$base/god-mode/general/" | shasum -a 256)"
  check "SPA route serves god-mode index.html" "$spa_sum" "$index_sum"
  report_process admin
  docker rm -f "$container" >/dev/null
fi

# ---- space ------------------------------------------------------------------------------------
if [[ -n "$(ref_of space)" ]]; then
  start space 1000 256m 0.25
  wait_http /spaces/ 120 || true
  check_brand_html /spaces/
  check_assets /spaces/ /spaces/assets/
  report_process space
  docker rm -f "$container" >/dev/null
fi

printf '\n%s failure(s) in the frontend images\n' "$failures"

# ---- backend ----------------------------------------------------------------------------------
if [[ -n "$(ref_of backend)" ]]; then
  ref="$(ref_of backend)"
  printf '\n== backend: %s\n' "$ref"
  if docker pull --quiet "$ref" >/dev/null && "$WAYLINE/backend/check-image.sh" "$ref"; then
    pass "backend check-image.sh exit 0"
  else
    fail "backend check-image.sh"
  fi
fi

printf '\nsmoke-images: %s failure(s)\n' "$failures"
[[ "$failures" -eq 0 ]]
