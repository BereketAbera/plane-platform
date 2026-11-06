#!/usr/bin/env bash
# Store Contabo API credentials for cntb, read with hidden prompts, so they reach neither a command line nor the
# shell's history. Contabo shows them in its Control Panel: Account, then Security & Access
# (https://my.contabo.com/api/details). They differ from the Control Panel login. The API password is set there.
#
#   scripts/hosted/contabo-login.sh
#
# Writes ~/.cntb.yaml at mode 0600, the file cntb itself uses, then lists the account's instances with nothing secret.
# Run it again to replace the credentials. This changes nothing at Contabo.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CNTB="$ROOT/.tools/bin/cntb"
CONFIG="$HOME/.cntb.yaml"
[[ -x "$CNTB" ]] || "$ROOT/scripts/install-tools.sh" cntb >/dev/null

echo "Contabo API credentials, from https://my.contabo.com/api/details"
echo "Nothing typed at a hidden prompt is shown. Paste, then press Enter."
read -r -p "Client ID: " client_id
read -r -s -p "Client secret (hidden): " client_secret
echo
read -r -p "API user (an e-mail address): " api_user
read -r -s -p "API password (hidden): " api_password
echo
[[ -n "$client_id" && -n "$client_secret" && -n "$api_user" && -n "$api_password" ]] || {
  echo "One of the four was empty, so nothing was saved." >&2
  exit 1
}

umask 077
# Through the environment, because a command line can be read by other processes. JSON strings are valid YAML.
CID="$client_id" CSECRET="$client_secret" AUSER="$api_user" APASS="$api_password" OUT="$CONFIG" python3 -I - <<'PY'
import json, os
keys = {"oauth2-clientid": "CID", "oauth2-client-secret": "CSECRET", "oauth2-user": "AUSER", "oauth2-password": "APASS"}
with open(os.environ["OUT"], "w", encoding="utf-8") as f:
    for key, var in keys.items():
        f.write(f"{key}: {json.dumps(os.environ[var])}\n")
PY
chmod 600 "$CONFIG"
unset client_id client_secret api_user api_password
echo "Saved to $CONFIG, mode $(stat -f %Lp "$CONFIG" 2>/dev/null || stat -c %a "$CONFIG")."

echo "Reading your instances:"
if ! "$CNTB" get instances -o json >"$ROOT/.local/contabo-instances.json" 2>"$ROOT/.local/contabo-instances.err"; then
  echo "Contabo refused or could not be reached:" >&2
  sed -E 's/(secret|password|token)[^ ]*/\1=<hidden>/Ig' "$ROOT/.local/contabo-instances.err" | head -5 >&2
  echo "Check the four values at https://my.contabo.com/api/details and run this again." >&2
  exit 1
fi
rm -f "$ROOT/.local/contabo-instances.err"
python3 -I - "$ROOT/.local/contabo-instances.json" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1]))
rows = rows if isinstance(rows, list) else rows.get("data", [])
for r in rows:
    ip = (r.get("ipConfig") or {}).get("v4", {}).get("ip", "?")
    print(f"  {r.get('instanceId')}  {r.get('name')}  {ip}  {r.get('status')}  {r.get('productId')}  {r.get('region')}")
print(f"{len(rows)} instance(s). You can close this tab and tell Claude it is done.")
PY
