#!/usr/bin/env bash
# Copyright (c) 2026 Bereket Abera
# SPDX-License-Identifier: AGPL-3.0-only
#
# runtime/nginx-<app>.conf marks a file under assets/ as immutable from its name alone, and a browser then keeps that
# file for a year without asking. So the name has to mean what the rule says. Vite names what it bundles, and copies
# public/ as it stands, so a file in public/assets/ would land under assets/ with a name nobody hashed, and a name like
# foo-bar-baz1.png would pass the rule. This stops the build on that, and lists any name the rule does not cover, which
# is safe: it gets no-cache. checks/smoke-images.sh tests what the running image answers.
#
#   apps/wayline/checks/cache-names.sh <web|admin>
# shellcheck source=../scripts/lib.sh
source "$(dirname "$0")/../scripts/lib.sh"

app="${1:?usage: cache-names.sh <web|admin>}"
client="$SRC/apps/$app/build/client"
conf="$WAYLINE/runtime/nginx-$app.conf"
[[ -d "$client/assets" ]] || die "nothing to read at $client/assets, build it first"

# The rule's file name part, read from the config, so this cannot disagree with it.
rule="$(perl -ne 'print $1 if m{^\s*"~\^\([0-9|]+\):(?:/god-mode)?/assets/(.*?)\$"}' "$conf")"
[[ -n "$rule" ]] || die "found no rule for assets/ in $conf"

[[ ! -e "$SRC/apps/$app/public/assets" ]] \
  || die "apps/$app/public/assets exists, so unhashed files land under assets/, and the rule in $conf could keep them for a year"

status=0
total="$(find "$client/assets" -type f | wc -l | tr -d ' ')"
nested="$(find "$client/assets" -mindepth 2 -type f | wc -l | tr -d ' ')"
hashed="$(find "$client/assets" -maxdepth 1 -type f -exec basename {} \; | grep -cE "^$rule\$" || true)"
outside="$(find "$client/assets" -maxdepth 1 -type f -exec basename {} \; | grep -vE "^$rule\$" || true)"
log "$app: $total files under assets/, $hashed named as the rule says, $nested in a subdirectory, which the rule does not cover"
[[ -z "$outside" ]] || printf 'not covered, so served no-cache: %s\n' "$outside"
# A random 8 characters is rarely all lower-case letters, and a word often is. Worth a look, not a failure.
worded="$(find "$client/assets" -maxdepth 1 -type f -exec basename {} \; | grep -E -- '-[a-z]{8}[0-9]*\.[A-Za-z0-9]+$' || true)"
[[ -z "$worded" ]] || printf 'a suffix of lower-case letters only, so read it: %s\n' "$worded"
[[ "$hashed" -gt 0 ]] || { warn "no file under assets/ matches the rule, so the rule is wrong or the build changed"; status=1; }
exit "$status"
