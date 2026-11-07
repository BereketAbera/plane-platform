#!/usr/bin/env bash
# What this machine makes for Frameflow, once, before its first bootstrap: the owner's access key and its sha256, and Hatchet's three
# keysets. Each goes to .local/hosted/plane-prod/frameflow at mode 0600, and scripts/infisical-seed.sh copies the sha256 and the keysets
# from there into Infisical project frameflow-prod. The key itself goes nowhere: Frameflow holds only its sha256.
#
#   TARGET=plane-prod scripts/hosted/frameflow-inputs.sh
#
# Nothing here is ever replaced. Hatchet encrypts its database under the master keyset and signs every client token with the JWT keysets,
# so a new set would lose both, and a new key would not match the sha256 Frameflow checks. So a file that exists stays, and a set found
# in part is refused, for a person to put back from a copy: the recovery bundle holds one. To change the owner's key on purpose, remove
# both its files, run this again, and replace OWNER_TOKEN_SHA256 in Infisical by hand, because the seed never overwrites a value.
#
# The keysets come from hatchet-admin, pinned by digest, run once in a container with no network, as this machine's own user. So Docker
# must be running the first time. The image is public, so the pull needs no login: where Docker's credential helper hangs, run this with
# DOCKER_CONFIG naming a folder whose config.json is {"auths":{}}. This reaches no cluster.
#
# No value reaches an argv or stdout: openssl writes the key to a file, its sha256 is read from that file, and the container writes the
# keysets into a folder here. Only names are printed.
HOSTED_NO_CLUSTER=yes
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

DIR="$LOCAL_DIR/frameflow"
KEY_FILE="$DIR/owner-access-key"
SHA_FILE="$DIR/OWNER_TOKEN_SHA256"
# The files hatchet-admin writes, each to the name the seed reads, in the order the seed keeps.
KEYSET_FILES="master.key:HATCHET_MASTER_KEYSET private_ec256.key:HATCHET_JWT_PRIVATE_KEYSET public_ec256.key:HATCHET_JWT_PUBLIC_KEYSET"
# The release Frameflow's hatchet-lite runs. Only this machine runs it, so policy/hosted-images.txt does not list it.
HATCHET_ADMIN_IMAGE="ghcr.io/hatchet-dev/hatchet/hatchet-admin:v0.114.2@sha256:e5d8fd721d196d51cb631871d11d120b06fd3a4f29fa063c06955d8ec8930873"

mkdir -p "$DIR"
chmod 700 "$DIR"
WORK=""
cleanup() { if [[ -n "$WORK" ]]; then rm -rf "$WORK"; fi; }
trap cleanup EXIT

write_file() { # write_file <file>: stdin to it at 0600, all at once
  local tmp
  tmp="$(mktemp "$DIR/.inputs.XXXXXX")"
  cat >"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$1"
}

# Each value is one line with no blank in it, and no newline at its end: the seed refuses anything else, because Hatchet and Frameflow
# would read it as part of the value.
require_one_line() { # require_one_line <file>
  [[ -s "$1" ]] || die "${1#"$ROOT"/} is empty"
  [[ "$(tr -d '[:space:]' <"$1" | wc -c)" == "$(wc -c <"$1")" ]] || die "${1#"$ROOT"/} holds a line break or a blank, which would become part of the value"
}

owner_key() {
  if [[ -s "$SHA_FILE" ]]; then
    require_one_line "$SHA_FILE"
    grep -Eqx '[0-9a-f]{64}' "$SHA_FILE" || die "${SHA_FILE#"$ROOT"/} is not a sha256 in 64 lower-case hex characters, which is all Frameflow takes"
    if [[ -s "$KEY_FILE" ]]; then
      [[ "$(hosted_sha256 <"$KEY_FILE")" == "$(cat "$SHA_FILE")" ]] ||
        die "${KEY_FILE#"$ROOT"/} is not the key ${SHA_FILE#"$ROOT"/} is the sha256 of, and nothing here says which one Frameflow has. Nothing was changed"
      ok "the owner's access key and its sha256 are here already, and match"
    else
      ok "OWNER_TOKEN_SHA256 is here already, and the key it is the sha256 of is not: if that key is in your password manager, it is where it belongs"
    fi
    return 0
  fi
  if [[ ! -s "$KEY_FILE" ]]; then
    openssl rand -base64 32 | tr -d '\n' | write_file "$KEY_FILE"
    ok "made the owner's access key"
  fi
  require_one_line "$KEY_FILE"
  hosted_sha256 <"$KEY_FILE" | tr -d '\n' | write_file "$SHA_FILE"
  ok "wrote OWNER_TOKEN_SHA256, the sha256 of the owner's access key"
}

keysets() {
  local pair present="" absent=""
  for pair in $KEYSET_FILES; do
    if [[ -s "$DIR/${pair#*:}" ]]; then present="$present ${pair#*:}"; else absent="$absent ${pair#*:}"; fi
  done
  if [[ -z "$absent" ]]; then
    for pair in $KEYSET_FILES; do require_one_line "$DIR/${pair#*:}"; done
    ok "Hatchet's three keysets are here already"
    return 0
  fi
  [[ -z "$present" ]] ||
    die "of Hatchet's three keysets,$present are here and$absent not. They are one set, and a new one could not read what the old one wrote: put the missing ones back from the recovery bundle, and nothing was changed"

  command -v docker >/dev/null 2>&1 || die "docker not found, and Hatchet's keysets come from its hatchet-admin image. Install Docker, start it, and run this again"
  docker info >/dev/null 2>&1 || die "Docker is not running. Start it, and run this again"
  log "Pulling hatchet-admin v0.114.2, by digest. If this hangs, it is Docker's credential helper: see DOCKER_CONFIG at the top of scripts/hosted/frameflow-inputs.sh"
  docker pull "$HATCHET_ADMIN_IMAGE" >/dev/null
  WORK="$(mktemp -d "$DIR/.keysets.XXXXXX")"
  # Its standard output is dropped, because with no --key-dir that is where the keys go. Its errors still show.
  if ! docker run --rm --pull never --network none --read-only --user "$(id -u):$(id -g)" --cap-drop ALL \
    --security-opt no-new-privileges -v "$WORK:/keys" "$HATCHET_ADMIN_IMAGE" \
    /hatchet/hatchet-admin keyset create-local-keys --key-dir /keys >/dev/null; then
    die "hatchet-admin could not make the keysets, as it says above, so nothing was kept"
  fi
  # Not needed by the server, and an unencrypted key has no reason to stay.
  rm -f "$WORK/public_handle_unencrypted_ec256.key"
  for pair in $KEYSET_FILES; do
    [[ -s "$WORK/${pair%%:*}" ]] || die "hatchet-admin wrote no ${pair%%:*}, so nothing was kept"
    tr -d '\r\n' <"$WORK/${pair%%:*}" >"$WORK/${pair#*:}"
    require_one_line "$WORK/${pair#*:}"
  done
  # All three are checked before the first is kept, so a set that fails leaves none of it here.
  for pair in $KEYSET_FILES; do
    write_file "$DIR/${pair#*:}" <"$WORK/${pair#*:}"
  done
  rm -rf "$WORK"
  WORK=""
  ok "made Hatchet's three keysets"
}

owner_key
keysets

log "In ${DIR#"$ROOT"/}, each at mode 0600:"
for name in owner-access-key OWNER_TOKEN_SHA256 HATCHET_MASTER_KEYSET HATCHET_JWT_PRIVATE_KEYSET HATCHET_JWT_PUBLIC_KEYSET; do
  if [[ -s "$DIR/$name" ]]; then printf '  %s\n' "$name"; else printf '  %s: not here\n' "$name"; fi
done
if [[ -s "$KEY_FILE" ]]; then
  log "${KEY_FILE#"$ROOT"/} signs in to Frameflow as its owner, from anywhere. It belongs in your password manager. Once it is there you may delete the file: Frameflow and Infisical hold only its sha256, which stays here."
fi
log "The keysets are what Hatchet's database is read with, and Infisical holds the copy Hatchet runs with. Keep one off this machine too: make remote-bundle TARGET=plane-prod holds them."
ok "Frameflow's inputs are ready. The seed copies them into Infisical at the next make remote-bootstrap TARGET=plane-prod CONFIRM=plane-prod"
