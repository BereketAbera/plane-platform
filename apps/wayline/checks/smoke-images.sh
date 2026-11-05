#!/usr/bin/env bash
# Copyright (c) 2026 Bereket Abera
# SPDX-License-Identifier: AGPL-3.0-only
#
# Runs each frontend image by digest from .build/digests.tsv under the UID, memory limit, CPU limit and
# security settings of helm/plane/components/hardening, and checks what the chart and the ingress
# rely on, including what a browser may keep and for how long. Needs no cluster, and removes its containers. The
# backend has its own in-image check, which this calls last, then flatten-config.py. Exits non-zero if any check fails.
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

# ---- what a browser may keep -------------------------------------------------------------------
SECURITY_HEADERS=(
  "X-Frame-Options: DENY"
  "X-Content-Type-Options: nosniff"
  "Strict-Transport-Security: max-age=31536000; includeSubDomains"
  "X-XSS-Protection: 1; mode=block"
)
NO_CACHE="no-cache"
IMMUTABLE="public, max-age=31536000, immutable"

# check_response <label> <status> <Cache-Control> <path> [curl arguments...]: one request, and all it must carry.
check_response() {
  local label="$1" status="$2" cache="$3" path="$4" headers expected
  shift 4
  headers="$(curl -s -D - -o /dev/null -m 15 "$@" "$base$path" | tr -d '\r')"
  check "$label: status" "$(printf '%s\n' "$headers" | sed -n '1s/^HTTP[^ ]* \([0-9]*\).*/\1/p')" "$status"
  check "$label: Cache-Control" "$(printf '%s\n' "$headers" | grep -i '^cache-control:' | sed 's/^[^:]*: *//' | paste -sd'|' -)" "$cache"
  for expected in "${SECURITY_HEADERS[@]}"; do
    check "$label: ${expected%%:*}" "$(printf '%s\n' "$headers" | grep -ciFx "$expected" || true)" 1
  done
}
etag_of() { curl -sI -m 15 "$base$1" | tr -d '\r' | awk -F': ' 'tolower($1) == "etag" { print $2 }'; }

# nginx's own redirect for a directory asked for without its slash. An absolute one names port 3000 inside the container,
# which the ingress does not serve, so a Host the ingress would send must not change it.
check_redirect() { # check_redirect <path> <Location>
  local headers
  headers="$(curl -s -D - -o /dev/null -m 15 -H 'Host: plane.dev.localhost' "$base$1" | tr -d '\r')"
  check "$1 with Host plane.dev.localhost: status" "$(printf '%s\n' "$headers" | sed -n '1s/^HTTP[^ ]* \([0-9]*\).*/\1/p')" 301
  check "$1 with Host plane.dev.localhost: Location" "$(printf '%s\n' "$headers" | grep -i '^location:' | sed 's/^[^:]*: *//')" "$2"
}

# The stale page in docs/evidence/branding/live-dev/README.md. Without Cache-Control a browser reuses HTML without asking,
# for about a tenth of the file's age, so a promotion or a rollback goes unseen. Everything without a hash of its content
# in its name must be asked about every time. Only what the bundler named may be kept, and never HTML under such a name.
check_caching() { # check_caching <URL prefix of the app> <page> <SPA route> <its directory in the image>
  local prefix="$1" page="$2" route="$3" dir="$4" assets file sample index_sum missing etag path name mode range
  assets="$(docker exec "$container" find "$dir/assets" -maxdepth 1 -type f)"
  printf '%s files under %sassets/\n' "$(printf '%s\n' "$assets" | wc -l | tr -d ' ')" "$prefix"

  check_response "HTML $page" 200 "$NO_CACHE" "$page"
  check_response "HTML ${prefix}index.html" 200 "$NO_CACHE" "${prefix}index.html"
  check_response "SPA fallback $route" 200 "$NO_CACHE" "$route"

  # One real file of each type, and any whose name has the bundler's counter after the hash, and its manifest.
  sample="$(printf '%s\n' "$assets" | awk -F. '!seen[$NF]++'; printf '%s\n' "$assets" | grep -E -- '-[A-Za-z0-9_-]{8}[0-9]+\.[A-Za-z0-9]+$' | head -1 || true; printf '%s\n' "$assets" | grep '/manifest-' | head -1 || true)"
  for file in $sample; do
    check_response "hashed ${file##*/}" 200 "$IMMUTABLE" "${prefix}assets/${file##*/}"
  done

  # try_files sends these to index.html, so they must read as HTML reads, not as the hashed name they asked for.
  index_sum="$(curl -s "$base$page" | shasum -a 256)"
  for name in missing-AbCd1234.js missing-AbCd12342.js missing-AbCd1234.css missing-AbCd1234.woff2; do
    check_response "missing hashed $name" 200 "$NO_CACHE" "${prefix}assets/$name"
    check "missing hashed $name is the index.html fallback" "$(curl -s "$base${prefix}assets/$name" | shasum -a 256)" "$index_sum"
  done

  # A file under assets/ that no bundler named. There is none today: cache-names.sh stops the build on where one would
  # come from. This writes two into this throwaway container, so the rule is what gets tested.
  for name in unhashed.js logo-dark.png; do
    docker exec -u 0 "$container" sh -c "echo unhashed >'$dir/assets/$name'"
    check_response "unhashed $name under assets/" 200 "$NO_CACHE" "${prefix}assets/$name"
    docker exec -u 0 "$container" rm -f "$dir/assets/$name"
  done
  check_response "the directory ${prefix}assets/" 403 "$NO_CACHE" "${prefix}assets/"

  # An error for a real hashed name. The name still promises the file, so a rule that reads only the name stamps the error
  # with the year, and a browser keeps a 403 after the server recovers: docs/evidence/branding/cache-errors.txt.
  file="$(printf '%s\n' "$assets" | head -1)"
  name="${file##*/}"
  mode="$(docker exec "$container" stat -c %a "$file")"
  denied_on_purpose="$file"
  docker exec -u 0 "$container" chmod 000 "$file"
  check_response "$name unreadable" 403 "$NO_CACHE" "${prefix}assets/$name"
  docker exec -u 0 "$container" chmod "$mode" "$file"
  check_response "$name readable again" 200 "$IMMUTABLE" "${prefix}assets/$name"
  check_response "POST to $name" 405 "$NO_CACHE" "${prefix}assets/$name" -X POST
  check_response "$name with If-Match another ETag" 412 "$NO_CACHE" "${prefix}assets/$name" -H 'If-Match: "6aebbfcf-from-another-image"'
  # A range past the end is what nginx would answer 416, with this header and the rest twice. Byte ranges are off, so a
  # Range header changes nothing: the whole file, as the name promises, once.
  for range in bytes=999999999- bytes=0-0 bytes=0-0,1-1; do
    check_response "$name with Range $range" 200 "$IMMUTABLE" "${prefix}assets/$name" -H "Range: $range"
    check "$name with Range $range is the whole file" "$(curl -s -m 15 -H "Range: $range" "$base${prefix}assets/$name" | shasum -a 256)" "$(curl -s -m 15 "$base${prefix}assets/$name" | shasum -a 256)"
  done
  check "$name offers no ranges" "$(curl -sI -m 15 "$base${prefix}assets/$name" | tr -d '\r' | grep -ic '^accept-ranges:' || true)" 0

  # Everything else in the image's web root.
  while read -r path; do
    [[ -z "$path" ]] || check_response "not hashed ${path#"$dir"/}" 200 "$NO_CACHE" "$prefix${path#"$dir"/}"
  done < <(docker exec "$container" find "$dir" -type f -not -path "$dir/assets/*" -not -name index.html)

  # ETag still saves the bytes, on the responses that say to ask, and on the ones that do not need to.
  etag="$(etag_of "$page")"
  if [[ -z "$etag" ]]; then fail "$page sends no ETag"; fi
  check_response "$page with its ETag" 304 "$NO_CACHE" "$page" -H "If-None-Match: $etag"
  check_response "$page with an ETag from another image" 200 "$NO_CACHE" "$page" -H 'If-None-Match: "6aebbfcf-from-another-image"'
  file="${prefix}assets/$(printf '%s\n' "$assets" | head -1 | sed 's#.*/##')"
  etag="$(etag_of "$file")"
  if [[ -z "$etag" ]]; then fail "$file sends no ETag"; fi
  check_response "$file with its ETag" 304 "$IMMUTABLE" "$file" -H "If-None-Match: $etag"
}

LICENCE_FILES="LICENSE.txt COPYRIGHT.txt NOTICE.txt MODIFICATIONS.txt OFL-InstrumentSans.txt OFL-JetBrainsMono.txt"
report_process() {
  docker exec "$container" sh -c 'printf "uid in container: "; id -u'
  # shellcheck disable=SC2016  # expanded in the container
  if docker exec "$container" sh -c 'cd /usr/share/licenses/wayline && for f in '"$LICENCE_FILES"'; do test -s "$f" || { echo "missing $f"; exit 1; }; done'; then
    pass "$1 carries the licence texts in /usr/share/licenses/wayline"
  else
    fail "$1 licence texts"
  fi
  docker stats --no-stream --format 'memory after these requests: {{.MemUsage}}' "$container"
  # check_caching makes one file unreadable, and nginx logs that.
  if docker logs "$container" 2>&1 | grep -E 'Permission denied|\[(emerg|crit|alert)\]' | grep -vF "${denied_on_purpose:-no file was made unreadable}"; then
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
  # The offer only counts if it lands somewhere, logged out. The repository being private is known and stated in
  # NOTICE.md, so this is reported rather than failed until WAYLINE_REQUIRE_PUBLIC_SOURCE=yes, which is what
  # the checklist in docs/agpl-compliance.md asks for before anyone else uses an instance.
  source_target="$(curl -s -o /dev/null -m 15 -w '%{http_code}' "${source_status#* }" || echo unreachable)"
  if [[ "${WAYLINE_REQUIRE_PUBLIC_SOURCE:-no}" == yes ]]; then
    check "/source target, followed logged out" "$source_target" 200
  else
    printf 'NOTE /source target, followed logged out, answers %s. 404 is expected while the repository is private or the commit is unpushed\n' "$source_target"
  fi
  check "/licenses/LICENSE.txt status" "$(code /licenses/LICENSE.txt)" 200
  check "/licenses/LICENSE.txt content type" "$(ctype /licenses/LICENSE.txt | sed 's/;.*//')" text/plain
  check "/licenses/OFL-InstrumentSans.txt status" "$(code /licenses/OFL-InstrumentSans.txt)" 200
  check "/licenses/OFL-JetBrainsMono.txt status" "$(code /licenses/OFL-JetBrainsMono.txt)" 200
  check "manifest status" "$(code /site.webmanifest.json)" 200
  if curl -s "$base/site.webmanifest.json" | grep -q Wayline; then pass "manifest names Wayline"; else fail "manifest does not name Wayline"; fi
  check "X-Frame-Options" "$(curl -sI "$base/" | tr -d '\r' | awk -F': ' 'tolower($1) == "x-frame-options" { print $2 }')" DENY
  check_caching / / /some-workspace/projects/ /usr/share/nginx/html
  check_response "/source" 302 "$NO_CACHE" /source
  check_response "/licenses/ listing" 200 "$NO_CACHE" /licenses/
  check_response "a missing licence" 404 "$NO_CACHE" /licenses/nothing
  check_redirect /licenses /licenses/
  check_redirect /assets /assets/
  # patches/20-auth.patch, where the onboarding form defines its default: false minifies to !1, and upstream's true to !0.
  # check_db.py cannot see this. Its consent line reads a model default, which is false on upstream's image too.
  check "onboarding form's marketing consent default" \
    "$(docker exec "$container" sh -c "grep -rhoE 'confirm_password:void 0,has_marketing_email_consent:![01]' /usr/share/nginx/html/assets" | sort -u | paste -sd'|' -)" \
    'confirm_password:void 0,has_marketing_email_consent:!1'
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
  check_caching /god-mode/ /god-mode/ /god-mode/general/ /usr/share/nginx/html/god-mode
  check_redirect /god-mode /god-mode/
  check_redirect /god-mode/assets /god-mode/assets/
  report_process admin
  docker rm -f "$container" >/dev/null
fi

# ---- space ------------------------------------------------------------------------------------
if [[ -n "$(ref_of space)" ]]; then
  start space 1000 256m 0.25
  wait_http /spaces/ 120 || true
  check_brand_html /spaces/
  check_assets /spaces/ /spaces/assets/
  # morgan reads req.ip on every page request, so proxy-addr handles this header each time.
  for forwarded in '203.0.113.9, 198.51.100.7' '::ffff:203.0.113.9' 'not-an-ip, <script>' ''; do
    check "/spaces/ with X-Forwarded-For '$forwarded'" "$(curl -s -o /dev/null -m 15 -w '%{http_code}' -H "X-Forwarded-For: $forwarded" "$base/spaces/")" 200
  done
  check "server still running after those" "$(docker inspect -f '{{.State.Running}}' "$container")" true
  # A Node server, with no nginx to change. Its HTML has no lifetime and no validator, so a browser has nothing to reuse,
  # and its hashed files are upstream's serve command's rule. docs/evidence/branding/space-cache.txt shows a browser asking
  # every time. These fail if that moves, because the fix in nginx would then be needed here.
  headers="$(curl -s -D - -o /dev/null -m 15 "$base/spaces/" | tr -d '\r')"
  for name in cache-control expires etag last-modified; do
    check "/spaces/ HTML has no $name" "$(printf '%s\n' "$headers" | grep -ic "^$name:" || true)" 0
  done
  css="$(curl -s -m 15 "$base/spaces/" | grep -oE '/spaces/assets/[^"'"'"']*globals[^"'"'"']*\.css' | head -1)"
  check "hashed $css Cache-Control" "$(curl -sI -m 15 "$base$css" | tr -d '\r' | awk -F': ' 'tolower($1) == "cache-control" { print $2 }')" "$IMMUTABLE"
  check "a missing hashed file under /spaces/assets/ has no Cache-Control" "$(curl -sI -m 15 "$base/spaces/assets/missing-AbCd1234.js" | tr -d '\r' | grep -ic '^cache-control:' || true)" 0
  check "$css with its ETag" "$(curl -s -o /dev/null -m 15 -w '%{http_code}' -H "If-None-Match: $(etag_of "$css")" "$base$css")" 304
  report_process space
  docker rm -f "$container" >/dev/null
  # Separately, with no network and no CPU limit, because it walks the whole of node_modules.
  if docker run --rm --network none --user 1000:1000 --entrypoint node "$(ref_of space)" \
    --experimental-vm-modules --disable-warning=ExperimentalWarning /opt/wayline/space-deps.mjs check; then
    pass "space-deps.mjs check exit 0"
  else
    fail "space-deps.mjs check"
  fi
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
  # shellcheck disable=SC2016  # expanded in the container
  if docker run --rm --network none --entrypoint sh "$ref" -c 'cd /usr/share/licenses/wayline && for f in '"$LICENCE_FILES"'; do test -s "$f" || { echo "missing $f"; exit 1; }; done'; then
    pass "backend carries the licence texts in /usr/share/licenses/wayline"
  else
    fail "backend licence texts"
  fi
  if python3 -B "$WAYLINE/checks/flatten-config.py" "$ref"; then
    pass "backend flatten-config.py exit 0"
  else
    fail "backend flatten-config.py"
  fi
fi

printf '\nsmoke-images: %s failure(s)\n' "$failures"
[[ "$failures" -eq 0 ]]
