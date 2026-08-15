#!/usr/bin/env bash
# Render alertmanager.yaml from infrastructure/hosted/plane-prod/alertmanager.yaml.tmpl and what .local/hosted/plane-prod/alert-*
# holds, and create Secret monitoring/alertmanager-wayline from it, through stdin. Prints COMPLETE or INCOMPLETE.
#
#   TARGET=plane-prod CONFIRM=plane-prod scripts/hosted/alerts.sh         render and apply
#   TARGET=plane-prod scripts/hosted/alerts.sh state                      say what would be rendered, from the files alone.
#                                                                         Exit 0 COMPLETE, 2 INCOMPLETE. Touches no cluster
#
# The files come from scripts/hosted/owner-inputs.sh, and each is optional:
#   alert-telegram-bot-token, alert-telegram-chat-id    the primary receiver. Otherwise the sink, and nobody is paged.
#   alert-healthchecks-url                              Watchdog's pings. Otherwise the sink, and nobody is told the server died.
#
# No value reaches an argv or stdout: Python reads the files by name, and its output goes down a pipe into a Secret.
HOSTED_NO_CLUSTER=yes
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

TEMPLATE="$ROOT/infrastructure/hosted/plane-prod/alertmanager.yaml.tmpl"
SECRET=alertmanager-wayline
SINK_URL="http://alert-sink.monitoring.svc.cluster.local:8080/alerts"

have() { [[ -s "$LOCAL_DIR/$1" ]]; }

primary_state() {
  if have alert-telegram-bot-token && have alert-telegram-chat-id; then printf 'telegram'; else printf 'sink'; fi
}
deadman_state() {
  if have alert-healthchecks-url; then printf 'healthchecks'; else printf 'sink'; fi
}

# Prints COMPLETE or INCOMPLETE and what is missing. Exit 0 or 2.
state() {
  local primary deadman
  primary="$(primary_state)"
  deadman="$(deadman_state)"
  if [[ "$primary" == telegram && "$deadman" == healthchecks ]]; then
    printf 'alert delivery COMPLETE: alerts go to Telegram, and Watchdog pings Healthchecks\n'
    return 0
  fi
  printf 'alert delivery INCOMPLETE:'
  if [[ "$primary" == sink ]]; then printf ' alerts reach only the sink, so nobody is paged (scripts/hosted/owner-inputs.sh telegram).'; fi
  if [[ "$deadman" == sink ]]; then printf ' Watchdog reaches only the sink, so nobody is told if the server dies (scripts/hosted/owner-inputs.sh healthchecks).'; fi
  printf '\n'
  return 2
}

render() {
  TEMPLATE="$TEMPLATE" DIR="$LOCAL_DIR" SINK_URL="$SINK_URL" python3 -I -c '
import json, os, re, sys

directory = os.environ["DIR"]

def value(name):
    path = os.path.join(directory, name)
    if not os.path.isfile(path) or os.path.getsize(path) == 0:
        return None
    with open(path) as handle:
        return handle.read().strip()

def refuse(what):
    # Names the file and never its content.
    sys.exit("fail " + what + ". Nothing was applied. Run scripts/hosted/owner-inputs.sh again.")

def webhook(url, resolved):
    lines = ["    webhook_configs:", "      - url: " + json.dumps(url), "        send_resolved: " + resolved]
    return "\n".join(lines)

token, chat = value("alert-telegram-bot-token"), value("alert-telegram-chat-id")
if token and chat:
    if not re.fullmatch(r"[0-9]+:[A-Za-z0-9_-]+", token):
        refuse("alert-telegram-bot-token does not look like a bot token")
    if not re.fullmatch(r"-?[0-9]+", chat):
        refuse("alert-telegram-chat-id is not a whole number")
    primary = "\n".join(["    telegram_configs:", "      - bot_token: " + json.dumps(token), "        chat_id: " + chat,
                         "        send_resolved: true"])
else:
    primary = webhook(os.environ["SINK_URL"], "true")

ping = value("alert-healthchecks-url")
if ping:
    if not ping.startswith("https://"):
        refuse("alert-healthchecks-url does not start with https://")
    # Resolved says nothing to Healthchecks, and a stop in pings is the whole signal.
    deadman = webhook(ping, "false")
else:
    deadman = webhook(os.environ["SINK_URL"], "true")

with open(os.environ["TEMPLATE"]) as handle:
    text = handle.read()
if text.count("@@PRIMARY@@") != 1 or text.count("@@DEADMAN@@") != 1:
    sys.exit("fail the template must hold each marker once. Nothing was applied.")
sys.stdout.write(text.replace("@@PRIMARY@@", primary).replace("@@DEADMAN@@", deadman))
'
}

apply() {
  hosted_verify
  hosted_require_confirm "this replaces the alert configuration"
  kc get namespace monitoring >/dev/null 2>&1 || die "namespace monitoring does not exist yet. Terraform creates it."
  local rendered
  # In memory, so a render that fails or a config that does not parse never reaches the pipeline below.
  rendered="$(render)" || die "could not render $TEMPLATE"
  [[ "$(printf '%s\n' "$rendered" | yq -r '.receivers | length')" == 3 ]] || die "the rendered config does not parse, or does not have its three receivers"
  printf '%s\n' "$rendered" |
    kc -n monitoring create secret generic "$SECRET" --from-file=alertmanager.yaml=/dev/stdin --dry-run=client -o yaml |
    kc apply --server-side --field-manager=hosted-alerts --force-conflicts -f - >/dev/null
  rendered=""
  ok "Secret monitoring/$SECRET applied: primary is $(primary_state), Watchdog goes to $(deadman_state)"
}

case "${1:-apply}" in
  apply)
    apply
    state || true
    ;;
  state) state ;;
  *) die "usage: $0 [state]" ;;
esac
