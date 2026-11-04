#!/usr/bin/env bash
# Copyright (c) 2026 Bereket Abera
# SPDX-License-Identifier: AGPL-3.0-only
#
# Upstream's isometric empty states are JSX, so no image check can see them. Their drawings all read
# --illustration-stroke-* tokens from JS, and the overlay's registry reads none, so one hit in a bundle means an
# upstream illustration is back: propel's registry was restored, or something imports a stack directly.
# Skeleton loaders use only the --illustration-fill-* tokens, so they do not trip this.
#
#   apps/wayline/checks/bundle-art.sh web|admin|space
# shellcheck source=../scripts/lib.sh
source "$(dirname "$0")/../scripts/lib.sh"

app="${1:?usage: bundle-art.sh web|admin|space}"
dir="$SRC/apps/$app/build"
[[ -d "$dir" ]] || die "nothing to scan at $dir, build it first"
hits="$(grep -rl --include='*.js' -e 'var(--illustration-stroke-' "$dir" || true)"
if [[ -n "$hits" ]]; then
  printf '%s\n' "$hits" | sed "s|^$SRC/||" >&2
  die "$app ships upstream's empty-state illustrations"
fi
ok "$app ships none of upstream's empty-state illustrations"
