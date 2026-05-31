#!/usr/bin/env bash
# Copyright (c) 2026 Bereket Abera
# SPDX-License-Identifier: AGPL-3.0-only
#
# May images go to this registry prefix? Exits 0 if so, and otherwise says why and exits 1. Called by
# scripts/ci/build-images.sh before any push, and by the publish job in .github/workflows/images.yml, which then fails.
#
#   apps/wayline/scripts/publish-gate.sh <registry-prefix>
#
# The local registry reaches nobody, so it is always allowed. Any other prefix depends on
# backend/email-py-decision.txt, which is D12 in MODIFICATIONS.md, and only the owner's GHCR namespace is on the list. The
# decision this knows about is that the backend image replaces upstream's commercially headed email.py and is flattened, so
# no layer holds the original. checks/layer-check.py proves that on each image after it is pushed. A pending or unknown
# decision publishes nowhere.
set -euo pipefail

prefix="${1:?usage: publish-gate.sh <registry-prefix>}"
prefix="${prefix%/}"
decision_file="$(cd "$(dirname "$0")/../backend" && pwd)/email-py-decision.txt"
decision="$(cat "$decision_file")"
owner_prefix="ghcr.io/bereketabera/wayline"

case "$prefix" in
  localhost:* | 127.0.0.1:*) exit 0 ;;
esac

if [[ "$decision" != replace-with-upstream-agpl-flattened ]]; then
  echo "publish-gate: $decision_file says '$decision', which does not allow $prefix. See D12 in apps/wayline/MODIFICATIONS.md" >&2
  exit 1
fi
if [[ "$prefix" != "$owner_prefix" ]]; then
  echo "publish-gate: images go only to the local registry or to $owner_prefix, and not to $prefix" >&2
  exit 1
fi
