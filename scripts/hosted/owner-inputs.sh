#!/usr/bin/env bash
# Collect what only the owner can create, for hosted production. Each secret is typed at a hidden prompt and stored under
# .local/hosted/plane-prod/ at mode 0600. Nothing reaches a command line, the shell's history or Git.
#
#   scripts/hosted/owner-inputs.sh            every step, skipping what is already saved
#   scripts/hosted/owner-inputs.sh ghcr       one step: github | ghcr | telegram | healthchecks | offsite
#
# Press Enter at an optional prompt to skip it. Run this again to add it later, or to replace a value.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DIR="$ROOT/.local/hosted/plane-prod"
GHCR_REPO="bereketabera/wayline/web"
umask 077
mkdir -p "$DIR"
chmod 700 "$DIR"

ONLY="${1:-all}"
want() { [[ "$ONLY" == all || "$ONLY" == "$1" ]]; }
have() { [[ -s "$DIR/$1" ]]; }
line() { printf '\n== %s\n' "$*"; }

save() { # save <file>: stdin to a file at 0600, with no trailing newline
  local tmp
  tmp="$(mktemp "$DIR/.tmp.XXXXXX")"
  tr -d '\r\n' >"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$DIR/$1"
}

# 1. Reading private images from this Mac, to validate them in local dev.
if want github; then
  line "1 of 5. GitHub: let this Mac read your private images (required)"
  if gh auth status 2>&1 | grep -q 'read:packages'; then
    echo "Already granted."
  else
    echo "GitHub shows a one-time code here and opens a page in your browser. This adds one read-only permission."
    gh auth refresh -h github.com -s read:packages
  fi
fi

# 2. Pulling private images from the server. It holds this token, so it can read packages and do nothing else.
if want ghcr; then
  line "2 of 5. GitHub: a token for the server to pull images (required)"
  if have ghcr-pull-token && [[ "$ONLY" == all ]]; then
    echo "Already saved."
  else
    cat <<'TEXT'
Open: https://github.com/settings/tokens/new?scopes=read:packages&description=wayline-vps-ghcr-pull
It is a classic token, because GitHub's container registry takes no fine-grained token.
Tick only read:packages, set an expiry you are happy to rotate (a year is fine), click Generate, and copy it.
TEXT
    read -r -s -p "Token (hidden): " token
    echo
    if [[ -z "$token" ]]; then
      echo "Empty, so nothing was saved. This one is required."
    else
      # The token goes through curl's config on stdin, so it never appears in a process list.
      status="$(printf 'user = "%s:%s"\n' "BereketAbera" "$token" |
        curl -sS -K - -o /dev/null -w '%{http_code}' -m 20 "https://ghcr.io/token?service=ghcr.io&scope=repository:$GHCR_REPO:pull" || true)"
      if [[ "$status" == 200 ]]; then
        printf '%s' "$token" | save ghcr-pull-token
        echo "Saved. GitHub's registry accepted it."
      else
        echo "GitHub's registry answered $status, so nothing was saved. Check the token and run: scripts/hosted/owner-inputs.sh ghcr"
      fi
    fi
    unset token
  fi
fi

# 3. Where alerts go.
if want telegram; then
  line "3 of 5. Telegram: where alerts go (recommended, press Enter to skip)"
  if have alert-telegram-bot-token && have alert-telegram-chat-id && [[ "$ONLY" == all ]]; then
    echo "Already saved."
  else
    cat <<'TEXT'
In Telegram, message @BotFather, send /newbot, choose any name, and copy the token it gives you.
TEXT
    read -r -s -p "Bot token (hidden, Enter to skip): " bot
    echo
    if [[ -n "$bot" ]]; then
      echo "Now open your new bot in Telegram and send it any message, such as hello."
      read -r -p "Press Enter once you have sent it. " _
      chat="$(printf 'url = "https://api.telegram.org/bot%s/getUpdates"\n' "$bot" | curl -sS -K - -m 20 |
        python3 -I -c "
import json,sys
d=json.load(sys.stdin)
ids=[u['message']['chat']['id'] for u in d.get('result',[]) if 'message' in u]
print(ids[-1] if ids else '')" 2>/dev/null || true)"
      if [[ -z "$chat" ]]; then
        echo "The bot has received no message, so nothing was saved. Send it one, then run: scripts/hosted/owner-inputs.sh telegram"
      else
        code="$(printf 'url = "https://api.telegram.org/bot%s/sendMessage"\ndata = "chat_id=%s"\ndata = "text=Wayline alerts are connected."\n' "$bot" "$chat" |
          curl -sS -K - -o /dev/null -w '%{http_code}' -m 20 || true)"
        if [[ "$code" == 200 ]]; then
          printf '%s' "$bot" | save alert-telegram-bot-token
          printf '%s' "$chat" | save alert-telegram-chat-id
          echo "Saved. You should see a test message from the bot."
        else
          echo "Telegram answered $code, so nothing was saved."
        fi
      fi
    else
      echo "Skipped. Alerts will reach nobody until this is set."
    fi
    unset bot
  fi
fi

# 4. Being told when the whole server is down, which nothing on the server can do.
if want healthchecks; then
  line "4 of 5. Healthchecks.io: tells you when the server itself dies (optional, press Enter to skip)"
  if have alert-healthchecks-url && [[ "$ONLY" == all ]]; then
    echo "Already saved."
  else
    cat <<'TEXT'
At https://healthchecks.io make a free account, add a check named wayline-watchdog, period 5 minutes, grace 10 minutes,
add your Telegram or e-mail under Integrations, and copy the check's ping URL.
TEXT
    read -r -s -p "Ping URL (hidden, Enter to skip): " url
    echo
    if [[ -n "$url" ]]; then
      printf '%s' "$url" | save alert-healthchecks-url
      echo "Saved."
    else
      echo "Skipped. Nobody is told if the server dies."
    fi
    unset url
  fi
fi

# 5. A copy of the backups somewhere other than the server and this Mac.
if want offsite; then
  line "5 of 5. Off-site backups in S3-compatible storage (optional, press Enter to skip)"
  if have offsite-s3-key-secret && [[ "$ONLY" == all ]]; then
    echo "Already saved."
  else
    cat <<'TEXT'
Without this, encrypted backups stay on the server, and this Mac pulls a copy when it is on.
Backblaze B2 has a free 10 GB tier with no card. Create a private bucket and an application key limited to that bucket.
TEXT
    read -r -p "S3 endpoint, such as s3.eu-central-003.backblazeb2.com (Enter to skip): " endpoint
    if [[ -n "$endpoint" ]]; then
      read -r -p "Bucket name: " bucket
      read -r -p "Key ID: " keyid
      read -r -s -p "Application key (hidden): " keysecret
      echo
      printf '%s' "$endpoint" | save offsite-s3-endpoint
      printf '%s' "$bucket" | save offsite-s3-bucket
      printf '%s' "$keyid" | save offsite-s3-key-id
      printf '%s' "$keysecret" | save offsite-s3-key-secret
      echo "Saved."
      unset keysecret
    else
      echo "Skipped."
    fi
  fi
fi

line "Summary, with no values shown"
for f in ghcr-pull-token alert-telegram-bot-token alert-telegram-chat-id alert-healthchecks-url offsite-s3-key-secret; do
  if have "$f"; then echo "  saved    $f"; else echo "  not set  $f"; fi
done
if gh auth status 2>&1 | grep -q 'read:packages'; then echo "  saved    this Mac can read packages"; else echo "  not set  this Mac can read packages"; fi
echo "You can close this tab and tell Claude it is done."
