#!/usr/bin/env bash
# Install the pinned CLIs from tools.lock into .tools/bin, verifying every sha256.
# Nothing is installed globally. Re-running only fetches what is missing or wrong.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.tools/bin"
LOCK="$ROOT/tools.lock"
mkdir -p "$BIN"

case "$(uname -s)_$(uname -m)" in
  Darwin_arm64)                 PLATFORM=darwin_arm64 ;;
  Linux_x86_64)                 PLATFORM=linux_amd64 ;;
  Linux_aarch64|Linux_arm64)    PLATFORM=linux_arm64 ;;
  *) echo "unsupported platform: $(uname -s) $(uname -m)" >&2; exit 1 ;;
esac

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

ONLY=" ${*:-} "
installed=0; current=0
while IFS=$'\t' read -r name version platform url want member; do
  [[ "$name" == \#* || -z "$name" || "$platform" != "$PLATFORM" ]] && continue
  [[ "$ONLY" != "  " && "$ONLY" != *" $name "* ]] && continue
  stamp="$BIN/.$name.version"
  if [[ -x "$BIN/$name" && -f "$stamp" && "$(cat "$stamp")" == "$version:$want" ]]; then
    current=$((current + 1)); continue
  fi
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  file="$tmp/download"
  echo "fetching $name $version"
  # A gateway error can outlast a few seconds: run 42044273346 lost a job to four 504s in 6 s, before any check ran.
  curl -fsSL --retry 5 --retry-delay 5 --retry-connrefused -o "$file" "$url"
  got="$(sha256 "$file")"
  if [[ "$got" != "$want" ]]; then
    echo "CHECKSUM MISMATCH for $name $version: want $want got $got" >&2; exit 1
  fi
  case "$url" in
    *.tar.gz|*.tgz) tar -xzf "$file" -C "$tmp"; src="$tmp/$member"; [[ -f "$src" ]] || src="$(find "$tmp" -type f -name "$(basename "$member")" -not -name download | head -1)" ;;
    *.tar.xz)       tar -xJf "$file" -C "$tmp"; src="$tmp/$member" ;;
    *.zip)          unzip -qo "$file" -d "$tmp"; src="$tmp/$member"; [[ -f "$src" ]] || src="$(find "$tmp" -type f -name "$(basename "$member")" -not -name download | head -1)" ;;
    *)              src="$file" ;;
  esac
  [[ -f "${src:-}" ]] || { echo "could not locate $member in archive for $name" >&2; exit 1; }
  install -m 0755 "$src" "$BIN/$name"
  printf '%s' "$version:$want" > "$stamp"
  rm -rf "$tmp"; trap - EXIT
  installed=$((installed + 1))
done < "$LOCK"
echo "tools: $installed installed, $current already current, in $BIN"
