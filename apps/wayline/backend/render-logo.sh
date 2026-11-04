#!/usr/bin/env bash
# Copyright (c) 2026 Bereket Abera
# SPDX-License-Identifier: AGPL-3.0-only
#
# Renders assets/Logo.png from the mark master. Run by hand after the mark changes; the PNG is committed,
# so image builds need no rasterizer. Requires rsvg-convert (brew install librsvg).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
rsvg-convert --width 368 --height 368 --keep-aspect-ratio \
  --output "$here/assets/Logo.png" "$here/../assets/masters/mark.svg"
