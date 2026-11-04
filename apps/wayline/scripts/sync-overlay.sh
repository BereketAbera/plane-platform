#!/usr/bin/env bash
# Copyright (c) 2026 Bereket Abera
# SPDX-License-Identifier: AGPL-3.0-only
#
# Pushes overlay changes into the patchwork so patch authors see them. It only copies files and takes
# no git lock, so it is safe to run while other authors work. A file removed from the overlay stays
# in the patchwork until `patchwork.sh --reset`.
#
# Overlay paths are not patched (save-patch.sh refuses them), so copying over them cannot disturb a
# patch and the baseline needs no new commit.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

[[ -d "$PATCHWORK/.git" ]] || die "no patchwork yet, run apps/wayline/scripts/patchwork.sh"
rsync -a --exclude .DS_Store --itemize-changes "$OVERLAY/" "$PATCHWORK/" | grep -v '^\.d' || true
ok "overlay synced into $PATCHWORK"
