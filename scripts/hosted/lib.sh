#!/usr/bin/env bash
# The way to reach hosted production. Source it; do not execute it. Bash 3.2, because macOS ships it.
#
# scripts/lib/common.sh stays hard-wired to kind, so the 50 or so scripts that source it cannot name this cluster. This file
# sources it, then overrides KUBECONFIG, KUBE_CONTEXT, LOCAL_DIR and kc, and refuses to go on unless:
#   TARGET=plane-prod is set,
#   the kubeconfig holds one context, named plane-prod, on the tunnel's address,
#   and the live kube-system UID and node name match infrastructure/hosted/plane-prod/target.yaml.
# Mutating scripts also call hosted_require_confirm, which wants CONFIRM=plane-prod. CONFIRM=yes is what the local scripts
# take, and it does not count here, so a habit cannot reach production.
#
# A script that must run with no cluster to compare with sets HOSTED_NO_CLUSTER=yes before sourcing this: the tunnel, the
# kubeconfig fetch, and what works only on local files. `kube_system_uid: pending` admits nothing else. Only that script's own unexported
# assignment counts. From the environment it would switch the check off for every script that sources this, so that is refused.
#
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

[[ "${TARGET:-}" == plane-prod ]] || die "this reaches hosted production, so it needs TARGET=plane-prod. Through make: make remote-<verb> TARGET=plane-prod"
export TARGET

hosted_no_cluster_attributes="$(declare -p HOSTED_NO_CLUSTER 2>/dev/null || true)"
hosted_no_cluster_attributes="${hosted_no_cluster_attributes#declare -}"
hosted_no_cluster_attributes="${hosted_no_cluster_attributes%% *}"
[[ "$hosted_no_cluster_attributes" != *x* ]] || die "HOSTED_NO_CLUSTER is exported, which would switch off the check that this is the right cluster. Unset it: only a script's own assignment counts"
unset hosted_no_cluster_attributes

"$ROOT/scripts/install-tools.sh" yq kubectl >/dev/null

HOSTED_TARGET_FILE="$ROOT/infrastructure/hosted/plane-prod/target.yaml"
[[ -f "$HOSTED_TARGET_FILE" ]] || die "$HOSTED_TARGET_FILE is missing, so nothing says what plane-prod is"

hosted_field() { yq -r ".$1 // \"\"" "$HOSTED_TARGET_FILE"; }

[[ "$(hosted_field name)" == "$TARGET" ]] || die "$HOSTED_TARGET_FILE does not describe $TARGET"
HOSTED_NAME="$TARGET"
HOSTED_HOST="$(hosted_field host)"
# shellcheck disable=SC2034  # read by the scripts that source this
HOSTED_HOST6="$(hosted_field host6)"
HOSTED_DOMAIN="$(hosted_field domain)"
HOSTED_GRAFANA_DOMAIN="$(hosted_field grafana_domain)"
HOSTED_INFISICAL_DOMAIN="$(hosted_field infisical_domain)"
HOSTED_SSH_USER="$(hosted_field ssh_user)"
HOSTED_SSH_KEY="$(hosted_field ssh_key)"
HOSTED_SSH_KEY="${HOSTED_SSH_KEY/#\~/$HOME}"
HOSTED_NODE="$(hosted_field node_name)"
HOSTED_UID="$(hosted_field kube_system_uid)"
HOSTED_TUNNEL_PORT="$(hosted_field tunnel_port)"
for hosted_required in HOSTED_HOST HOSTED_DOMAIN HOSTED_GRAFANA_DOMAIN HOSTED_INFISICAL_DOMAIN HOSTED_SSH_USER HOSTED_SSH_KEY HOSTED_NODE HOSTED_UID HOSTED_TUNNEL_PORT; do
  [[ -n "${!hosted_required}" ]] || die "$HOSTED_TARGET_FILE leaves $hosted_required empty"
done
unset hosted_required
export HOSTED_NAME HOSTED_HOST HOSTED_DOMAIN HOSTED_GRAFANA_DOMAIN HOSTED_INFISICAL_DOMAIN HOSTED_NODE

# Re-rooted, so nothing this does can read or write the local platform's state.
export LOCAL_DIR="$ROOT/.local/hosted/plane-prod"
export KUBECONFIG="$LOCAL_DIR/kubeconfig"
export KUBE_CONTEXT="plane-prod"
# Evidence is published by make publish-evidence, which reads one folder, so it stays in that one.
export HOSTED_EVIDENCE_DIR="$ROOT/.local/evidence-raw"
export HOSTED_REPO_URL="ssh://git@ssh.github.com:443/BereketAbera/plane-platform.git"
export HOSTED_GITHUB_REPO="BereketAbera/plane-platform"
HOSTED_KNOWN_HOSTS="$ROOT/.local/hosted/known_hosts"
# shellcheck disable=SC2034  # read by the scripts that source this
HOSTED_BACKUP_ROOT="/srv/wayline/backups"
# Those two names mean the kind cluster, and a script that reaches for one here has lost its way.
unset CLUSTER_NAME NODE_CONTAINER

umask 077
mkdir -p "$LOCAL_DIR" "$HOSTED_EVIDENCE_DIR"
chmod 700 "$LOCAL_DIR"

# The bare path and not `command`: bash 3.2 execs `command <path>` in place inside a backgrounded function, and the subshell is gone.
kc() { "$ROOT/.tools/bin/kubectl" --kubeconfig "$KUBECONFIG" --context "$KUBE_CONTEXT" "$@"; }

cluster_exists() { die "cluster_exists asks about kind, and this script is working on $HOSTED_NAME"; }

# ------ SSH -----------------------------------------------------------------------------------------------------------

HOSTED_SSH_OPTS=(-o BatchMode=yes -o IdentitiesOnly=yes -i "$HOSTED_SSH_KEY" -o "UserKnownHostsFile=$HOSTED_KNOWN_HOSTS"
  -o StrictHostKeyChecking=yes -o ConnectTimeout=10)

hosted_require_ssh() {
  [[ -f "$HOSTED_SSH_KEY" ]] || die "no SSH key at $HOSTED_SSH_KEY"
  [[ -f "$HOSTED_KNOWN_HOSTS" ]] || die "$HOSTED_KNOWN_HOSTS is missing. Record the host key first, as scripts/hosted/provision-node.sh says"
}

node_ssh() { # A command on the node, as the admin user. Stdin is passed on, so a caller with none uses node_ssh_quiet.
  hosted_require_ssh
  ssh "${HOSTED_SSH_OPTS[@]}" "$HOSTED_SSH_USER@$HOSTED_HOST" "$@"
}

node_ssh_quiet() { # The same, with stdin closed, so it cannot swallow what a surrounding loop is reading.
  hosted_require_ssh
  ssh -n "${HOSTED_SSH_OPTS[@]}" "$HOSTED_SSH_USER@$HOSTED_HOST" "$@"
}

node_root() { node_ssh 'sudo -n bash -s'; } # A root shell, with its script on stdin.

node_script() { # A script given as text, as root, with this process's stdin as its own. The text must hold no secret.
  local encoded
  encoded="$(printf '%s' "$1" | base64 | tr -d '\n')"
  node_ssh "sudo -n bash -c \"\$(printf %s $encoded | base64 -d)\""
}

# ------ Is this the right cluster? ------------------------------------------------------------------------------------

hosted_tunnel_up() { "$ROOT/scripts/hosted/tunnel.sh" start >/dev/null; }

# Prints why this is not plane-prod, or nothing if it is. For a caller that has to report it and go on.
hosted_problem() {
  local contexts server live_uid live_nodes
  if [[ "$HOSTED_UID" == pending ]]; then
    printf 'target.yaml says kube_system_uid: pending, which admits only provisioning. Run scripts/hosted/kubeconfig.sh and record the UID it prints\n'
    return 0
  fi
  if [[ ! -s "$KUBECONFIG" ]]; then
    printf '%s is missing. Run: make remote-kubeconfig TARGET=plane-prod\n' "$KUBECONFIG"
    return 0
  fi
  contexts="$(kc config get-contexts -o name 2>/dev/null | tr '\n' ' ')"
  if [[ "$contexts" != "plane-prod " ]]; then
    printf 'the kubeconfig must hold only the context plane-prod, and holds: %s\n' "$contexts"
    return 0
  fi
  server="$(kc config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
  if [[ "$server" != "https://127.0.0.1:$HOSTED_TUNNEL_PORT" ]]; then
    printf 'the kubeconfig names the server %s, and this cluster is reached only through https://127.0.0.1:%s\n' "$server" "$HOSTED_TUNNEL_PORT"
    return 0
  fi
  if ! hosted_tunnel_up; then
    printf 'the SSH tunnel to %s will not start\n' "$HOSTED_HOST"
    return 0
  fi
  if ! live_uid="$(kc --request-timeout=20s get namespace kube-system -o jsonpath='{.metadata.uid}' 2>/dev/null)"; then
    printf 'the API server does not answer through the tunnel\n'
    return 0
  fi
  if [[ "$live_uid" != "$HOSTED_UID" ]]; then
    printf 'the live kube-system UID is %s and target.yaml records %s, so this is not the cluster it describes\n' "$live_uid" "$HOSTED_UID"
    return 0
  fi
  live_nodes="$(kc --request-timeout=20s get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
  if [[ "$live_nodes" != "$HOSTED_NODE" ]]; then
    printf 'the live nodes are "%s" and target.yaml records "%s"\n' "$live_nodes" "$HOSTED_NODE"
    return 0
  fi
}

hosted_verify() {
  local problem
  problem="$(hosted_problem)"
  [[ -z "$problem" ]] || die "refusing, because $problem"
}

hosted_require_confirm() { # what this is about to do
  [[ "${CONFIRM:-}" == plane-prod ]] || die "$1 on hosted production, so it needs CONFIRM=plane-prod. CONFIRM=yes does not count here."
}

# ------ Small shared helpers ------------------------------------------------------------------------------------------

hosted_stamp() { date -u +%Y%m%dT%H%M%SZ; }

hosted_sha256() { # stdin, or a file
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@" | cut -d' ' -f1; else shasum -a 256 "$@" | cut -d' ' -f1; fi
}

# restic, from scripts/hosted/restic.lock, into .tools/bin. A no-op once it is there at that version.
hosted_need_restic() {
  local platform version url want stamp="$ROOT/.tools/bin/.restic.version" tmp
  case "$(uname -s)_$(uname -m)" in
    Darwin_arm64) platform=darwin_arm64 ;;
    Linux_x86_64) platform=linux_amd64 ;;
    Linux_aarch64 | Linux_arm64) platform=linux_arm64 ;;
    *) die "no pinned restic for $(uname -s) $(uname -m)" ;;
  esac
  read -r version url want <<<"$(awk -F '\t' -v p="$platform" '$1 == "restic" && $3 == p { print $2, $4, $5 }' "$ROOT/scripts/hosted/restic.lock")"
  [[ -n "$want" ]] || die "scripts/hosted/restic.lock has no row for $platform"
  if [[ -x "$ROOT/.tools/bin/restic" && -f "$stamp" && "$(cat "$stamp")" == "$version:$want" ]]; then return 0; fi
  tmp="$(mktemp -d)"
  log "Fetching restic $version"
  if ! curl -fsSL --retry 8 --retry-connrefused -o "$tmp/restic.bz2" "$url"; then
    rm -rf "$tmp"
    die "could not download restic from $url"
  fi
  if [[ "$(hosted_sha256 "$tmp/restic.bz2")" != "$want" ]]; then
    rm -rf "$tmp"
    die "CHECKSUM MISMATCH for restic $version"
  fi
  bunzip2 -c "$tmp/restic.bz2" >"$tmp/restic"
  install -m 0755 "$tmp/restic" "$ROOT/.tools/bin/restic"
  printf '%s' "$version:$want" >"$stamp"
  rm -rf "$tmp"
}

# Waits for a Job and says how it ended: ok, failed or running, the last if it is still going at the deadline.
hosted_wait_job() { # namespace job seconds
  local deadline=$((SECONDS + $3)) state
  while :; do
    state="$(kc -n "$1" get job "$2" -o json | jq -r '
      (.status.conditions // []) as $c
      | if any($c[]; .type == "Complete" and .status == "True") then "ok"
        elif any($c[]; .type == "Failed" and .status == "True") then "failed"
        else "running" end')"
    if [[ "$state" != running || $SECONDS -ge $deadline ]]; then
      printf '%s' "$state"
      return 0
    fi
    sleep 5
  done
}

# A local port with nothing on it, from this one up.
hosted_free_port() {
  local port="$1"
  while nc -z 127.0.0.1 "$port" >/dev/null 2>&1; do port=$((port + 1)); done
  printf '%s' "$port"
}

# A port-forward that stays up for this script, and ends with it. The caller's trap calls hosted_forward_stop.
HOSTED_FORWARD_PIDS=""
hosted_forward_start() { # namespace target local-port remote-port
  local deadline=$((SECONDS + 30)) pid
  # The binary and not kc, so $! is the process that holds the port: killing a function's subshell would leave it behind.
  "$ROOT/.tools/bin/kubectl" --kubeconfig "$KUBECONFIG" --context "$KUBE_CONTEXT" -n "$1" port-forward "$2" "$3:$4" --address 127.0.0.1 >/dev/null 2>&1 &
  pid=$!
  HOSTED_FORWARD_PIDS="$HOSTED_FORWARD_PIDS $pid"
  until nc -z 127.0.0.1 "$3" >/dev/null 2>&1; do
    kill -0 "$pid" 2>/dev/null || return 1
    [[ $SECONDS -lt $deadline ]] || return 1
    sleep 1
  done
}

hosted_forward_stop() {
  local pid
  for pid in $HOSTED_FORWARD_PIDS; do kill "$pid" 2>/dev/null || true; done
  HOSTED_FORWARD_PIDS=""
}

if [[ "${HOSTED_NO_CLUSTER:-}" != yes ]]; then
  hosted_verify
fi
