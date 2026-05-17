#!/usr/bin/env bash
# Copyright (c) 2026 Bereket Abera
# SPDX-License-Identifier: AGPL-3.0-only
#
# build.sh's hook for the backend Docker context. The work lives with the backend's other files.
exec "$(dirname "$0")/../backend/assemble.sh" "$@"
