#!/usr/bin/env bash
# Copyright (c) 2026 Bereket Abera
# SPDX-License-Identifier: AGPL-3.0-only
#
# Proves from build output that brand fonts resolve under the app's base path: every brand font URL in
# the built CSS carries the right prefix and names a file that exists, and brand colours are present.
#
#   apps/wayline/checks/font-urls.sh web|admin|space
# shellcheck source=../scripts/lib.sh
source "$(dirname "$0")/../scripts/lib.sh"

app="${1:?usage: font-urls.sh web|admin|space}"
case "$app" in
  web) prefix="/assets/" ;;
  admin) prefix="/god-mode/assets/" ;;
  space) prefix="/spaces/assets/" ;;
  *) die "unknown app: $app" ;;
esac
client="$SRC/apps/$app/build/client"
[[ -d "$client/assets" ]] || die "$client/assets not found, build $app first"

css_files=()
while IFS= read -r f; do css_files+=("$f"); done < <(grep -l "Instrument Sans Variable" -r "$client/assets" --include='*.css')
[[ ${#css_files[@]} -gt 0 ]] || die "$app: no built CSS declares Instrument Sans Variable"

urls="$(cat "${css_files[@]}" | grep -oE 'url\([^)]*(instrument-sans|jetbrains-mono)[^)]*\.woff2[^)]*\)' | sed -E 's/^url\(//; s/\)$//; s/^"//; s/"$//' | LC_ALL=C sort -u)"
count="$(printf '%s\n' "$urls" | grep -c . || true)"
[[ "$count" -eq 5 ]] || die "$app: expected 5 brand font URLs, found $count: $urls"
while read -r url; do
  [[ "$url" == "$prefix"* ]] || die "$app: font URL $url does not start with $prefix"
  file="$client/assets/${url#"$prefix"}"
  [[ -s "$file" ]] || die "$app: font URL $url has no file at $file"
done <<<"$urls"

for value in '#9f1265' '#e65aa6' '#f4f2ea' '#0b1320'; do
  cat "${css_files[@]}" | grep -qi "$value" || die "$app: brand value $value missing from built CSS"
done
ok "$app: $count font URLs under $prefix, all files present, brand values present"
