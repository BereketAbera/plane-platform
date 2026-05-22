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

# The vendored email.py must still be the bytes its pin names. check_image.py compares the image's copy too.
want="$(sed -n 's/^sha256=//p' "$here/vendor/email.py.pin")"
got="$(shasum -a 256 "$here/vendor/email.py")"
[[ -n "$want" && "${got%% *}" == "$want" ]] \
  || { echo "assemble.sh: vendor/email.py is ${got%% *}, and vendor/email.py.pin says ${want:-nothing}" >&2; exit 1; }

mkdir -p "$context/templates" "$context/wayline"
cp -R "$here/templates/emails" "$context/templates/"
cp "$here/edit_strings.py" "$here/check_image.py" "$here/check_db.py" "$here/assets/Logo.png" "$here/pyjwt-requirements.txt" "$context/wayline/"
# In its own directory: beside those scripts, it would shadow the standard library's email package when they run.
cp -R "$here/vendor" "$context/wayline/vendor"
