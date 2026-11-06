#!/usr/bin/env bash
# The recovery bundle: what cannot be recreated and is not in the cluster or in Git, encrypted with age to a public recipient.
# With the bundle, the private identity and this repository, a person can bring production back on a new machine.
#
#   scripts/hosted/bundle.sh init      make the owner's identity once, and write its public half beside this file, for Git
#   TARGET=plane-prod scripts/hosted/bundle.sh          write a new bundle, decrypt it again and compare it, file by file
#   TARGET=plane-prod scripts/hosted/bundle.sh verify   decrypt the newest bundle again and compare it with what is here now
#
# Exit 0 written and verified, 1 failed, 2 written but INCOMPLETE: something required was not there yet, or the identity was not
# at hand to prove it decrypts.
#
# Holds: secret zero, every Terraform state under .local/hosted/plane-prod/terraform, the deploy key, the restic password, the
# read-only pull key, the alert credentials, the GHCR token, the off-site credentials and the SSH known hosts. It does not hold
# the kubeconfig, which SSH brings back, or any backup, which restic seals by itself.
#
# Written to .local/hosted/plane-prod/recovery-bundle. Copy it off this machine, into storage that is not the VPS: this script
# never sends it anywhere, and it must never go there. Run it again after every bootstrap, token mint or Terraform apply.
HOSTED_NO_CLUSTER=yes
export TARGET="${TARGET:-}"
if [[ "${1:-}" == init ]]; then TARGET=plane-prod; fi # init reads no target, and is the one verb safe with none named
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
"$ROOT/scripts/install-tools.sh" age age-keygen >/dev/null

RECIPIENT_FILE="$ROOT/scripts/hosted/recovery-recipient.txt"
IDENTITY="${WAYLINE_RECOVERY_IDENTITY:-$HOME/.wayline/recovery-identity.txt}"
OUT_DIR="$LOCAL_DIR/recovery-bundle"
KEEP=5
WORK=""

cleanup() { if [[ -n "$WORK" ]]; then rm -rf "$WORK"; fi; }
trap cleanup EXIT

init() {
  local recipient
  if [[ -s "$RECIPIENT_FILE" ]]; then
    ok "${RECIPIENT_FILE#"$ROOT"/} already names the recipient: $(grep -v '^#' "$RECIPIENT_FILE")"
    return 0
  fi
  if [[ ! -s "$IDENTITY" ]]; then
    mkdir -p "$(dirname "$IDENTITY")"
    chmod 700 "$(dirname "$IDENTITY")"
    age-keygen -o "$IDENTITY" 2>/dev/null
    chmod 600 "$IDENTITY"
    ok "made the identity at $IDENTITY"
  fi
  recipient="$(age-keygen -y "$IDENTITY")"
  {
    printf '# The public half of the recovery identity. Not a secret: scripts/hosted/bundle.sh encrypts to this.\n'
    printf '%s\n' "$recipient"
  } >"$RECIPIENT_FILE"
  chmod 644 "$RECIPIENT_FILE"
  ok "wrote ${RECIPIENT_FILE#"$ROOT"/}. Commit it."
  log "Copy $IDENTITY into your password manager, as well as paper if you like, and keep it nowhere near the bundle. Without it no bundle can ever be read. Once it is copied you may delete the file: this script then asks for it at a hidden prompt."
}

recipient_or_die() {
  [[ -s "$RECIPIENT_FILE" ]] || die "${RECIPIENT_FILE#"$ROOT"/} is missing, so there is nothing to encrypt to. Run: scripts/hosted/bundle.sh init"
  grep -Eq '^age1[0-9a-z]+$' "$RECIPIENT_FILE" || die "${RECIPIENT_FILE#"$ROOT"/} does not hold an age recipient"
}

# copy <path under LOCAL_DIR>: into the staging tree, keeping its path, if it exists.
stage() {
  local path="$1"
  [[ -e "$LOCAL_DIR/$path" ]] || return 0
  mkdir -p "$WORK/stage/$(dirname "$path")"
  cp -pR "$LOCAL_DIR/$path" "$WORK/stage/$path"
}

MISSING=""
need() { # a file under LOCAL_DIR that the bundle is no use without
  [[ -s "$LOCAL_DIR/$1" ]] || MISSING="$MISSING $1"
}

collect() {
  local file relative
  mkdir -p "$WORK/stage"
  stage secret-zero
  find "$WORK/stage" -name '.tmp.*' -prune -exec rm -rf {} + 2>/dev/null || true
  for file in argocd-deploy-key argocd-deploy-key.pub wayline-pull_ed25519 wayline-pull_ed25519.pub restic-password ghcr-pull-token; do
    stage "$file"
  done
  for file in "$LOCAL_DIR"/alert-* "$LOCAL_DIR"/offsite-s3-*; do
    if [[ -f "$file" ]]; then stage "${file##*/}"; fi
  done
  # State alone. Provider plugins are large, and Terraform fetches them again.
  if [[ -d "$LOCAL_DIR/terraform" ]]; then
    while read -r file; do
      relative="${file#"$LOCAL_DIR"/}"
      stage "$relative"
    done < <(find "$LOCAL_DIR/terraform" -type f -name '*.tfstate*' -not -path '*/.terraform/*')
  fi
  if [[ -f "$HOSTED_KNOWN_HOSTS" ]]; then cp -p "$HOSTED_KNOWN_HOSTS" "$WORK/stage/known_hosts"; fi

  need secret-zero/ENCRYPTION_KEY
  need secret-zero/AUTH_SECRET
  need secret-zero/DB_PASSWORD
  need secret-zero/REDIS_PASSWORD
  need argocd-deploy-key
  need restic-password
  [[ -n "$(find "$LOCAL_DIR/terraform" -type f -name 'terraform.tfstate' -not -path '*/.terraform/*' 2>/dev/null | head -1)" ]] || MISSING="$MISSING terraform-state"

  [[ -n "$(find "$WORK/stage" -type f | head -1)" ]] || die "there is nothing under ${LOCAL_DIR#"$ROOT"/} to bundle yet. Run: scripts/hosted/bootstrap.sh"
  (cd "$WORK/stage" && find . -type f ! -name MANIFEST.sha256 -print0 | sort -z | xargs -0 shasum -a 256 >"$WORK/MANIFEST.sha256")
  mv "$WORK/MANIFEST.sha256" "$WORK/stage/MANIFEST.sha256"
}

# Runs age -d on $1 with the identity from the file or from a hidden prompt, writing the tar to stdout. Non-zero if neither.
decrypt() {
  local pasted
  if [[ -s "$IDENTITY" ]]; then
    age -d -i "$IDENTITY" "$1"
    return
  fi
  [[ -t 0 ]] || return 3
  read -r -s -p "Recovery identity, the line starting AGE-SECRET-KEY- (hidden, Enter to skip): " pasted
  printf '\n' >&2
  [[ -n "$pasted" ]] || return 3
  printf '%s\n' "$pasted" | age -d -i - "$1"
}

# Decrypts $1 and compares it with the tree at $2. 0 same, 1 different or unreadable, 3 no identity at hand.
prove() {
  local bundle="$1" against="$2" rc=0
  mkdir -p "$WORK/check"
  decrypt "$bundle" >"$WORK/check.tar" || rc=$?
  if [[ "$rc" -eq 3 ]]; then return 3; fi
  [[ "$rc" -eq 0 ]] || return 1
  tar -xf "$WORK/check.tar" -C "$WORK/check" || return 1
  rm -f "$WORK/check.tar"
  (cd "$WORK/check" && shasum -a 256 -c MANIFEST.sha256 >/dev/null) || return 1
  diff -r "$against" "$WORK/check" >/dev/null || return 1
}

write_bundle() {
  local stamp bundle rc=0 listed
  recipient_or_die
  WORK="$(mktemp -d "$LOCAL_DIR/.bundle.XXXXXX")"
  collect
  mkdir -p "$OUT_DIR"
  chmod 700 "$OUT_DIR"
  stamp="$(hosted_stamp)"
  bundle="$OUT_DIR/wayline-recovery-$stamp.tar.age"
  COPYFILE_DISABLE=1 tar -C "$WORK/stage" -cf - . | age -R "$RECIPIENT_FILE" -o "$bundle"
  chmod 600 "$bundle"
  hosted_sha256 "$bundle" >"$bundle.sha256"
  listed="$(grep -c '' "$WORK/stage/MANIFEST.sha256" | tr -d ' ')"
  prove "$bundle" "$WORK/stage" || rc=$?
  case "$rc" in
    0) ok "decrypted it again: all $listed files match what is here" ;;
    3) warn "the identity is not at hand ($IDENTITY), so this bundle has not been proved to decrypt" ;;
    *)
      rm -f "$bundle" "$bundle.sha256"
      die "the bundle did not decrypt back to what went in, so it was removed. Is ${RECIPIENT_FILE#"$ROOT"/} the public half of the identity you hold?"
      ;;
  esac
  # Older copies hold older secrets, so only a few stay here. The owner's off-machine copies are the owner's to keep.
  find "$OUT_DIR" -maxdepth 1 -type f -name 'wayline-recovery-*.tar.age' | sort -r | tail -n +"$((KEEP + 1))" | while read -r old; do
    rm -f "$old" "$old.sha256"
  done
  ok "wrote ${bundle#"$ROOT"/}, $listed files, sha256 beside it. Copy it off this machine, and never onto the VPS."
  if [[ -n "$MISSING" ]]; then
    warn "recovery bundle INCOMPLETE: it does not hold:$MISSING. Run this again once they exist."
    return 2
  fi
  if [[ "$rc" -eq 3 ]]; then
    warn "recovery bundle INCOMPLETE: not proved to decrypt. Run with the identity at $IDENTITY, or on a terminal to paste it."
    return 2
  fi
  ok "recovery bundle COMPLETE"
}

verify_bundle() {
  local bundle rc=0
  bundle="$(find "$OUT_DIR" -maxdepth 1 -type f -name 'wayline-recovery-*.tar.age' 2>/dev/null | sort -r | head -1)"
  [[ -n "$bundle" ]] || die "no bundle in ${OUT_DIR#"$ROOT"/}. Run: scripts/hosted/bundle.sh"
  [[ "$(hosted_sha256 "$bundle")" == "$(cat "$bundle.sha256")" ]] || die "$bundle does not match the sha256 beside it"
  WORK="$(mktemp -d "$LOCAL_DIR/.bundle.XXXXXX")"
  collect
  prove "$bundle" "$WORK/stage" || rc=$?
  case "$rc" in
    0) ok "${bundle##*/} decrypts, and it holds exactly what is here now" ;;
    3) warn "the identity is not at hand, so nothing was proved"; return 2 ;;
    *) die "${bundle##*/} is not what is here now, or does not decrypt. A newer secret or Terraform state makes it stale: run scripts/hosted/bundle.sh" ;;
  esac
}

case "${1:-write}" in
  init) init ;;
  write) write_bundle ;;
  verify) verify_bundle ;;
  *) die "usage: $0 [init|verify]" ;;
esac
