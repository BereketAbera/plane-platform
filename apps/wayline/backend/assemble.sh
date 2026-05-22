#!/usr/bin/env bash
# Copyright (c) 2026 Bereket Abera
# SPDX-License-Identifier: AGPL-3.0-only
#
# Adds this directory to the backend Docker context for runtime/Dockerfile.backend.
#
#   apps/wayline/backend/assemble.sh <plane-src> <context-dir>
#
# <plane-src> is accepted for the build.sh hook's signature and not read: everything needed from upstream
# is already in the base image. The context then holds templates/emails and wayline/. Licence texts are
# added by build.sh, as they are for every image.
set -euo pipefail
[[ $# -eq 2 ]] || { echo "usage: assemble.sh <plane-src> <context-dir>" >&2; exit 2; }
here="$(cd "$(dirname "$0")" && pwd)"
context="$2"

mkdir -p "$context/templates" "$context/wayline"
cp -R "$here/templates/emails" "$context/templates/"
cp "$here/edit_strings.py" "$here/check_image.py" "$here/assets/Logo.png" "$context/wayline/"
