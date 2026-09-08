#!/usr/bin/env bash
# A controlled restart of everything Plane runs on hosted production, and proof that what it holds came through.
#
#   TARGET=plane-prod CONFIRM=plane-prod scripts/hosted/restart-check.sh
#
# It deletes Plane's pods one at a time, data first and then the app, so each comes back through its controller, on its own volume. No
# spec changes, so Argo CD has nothing to put back. It compares what Postgres holds before and after, and says how long the public site
# was down, because one replica of each means a restart is an outage, and this is the place to learn how long.
#
# Row counts and hashes of ids and names, never the values. A person adding a work item while this runs reads as a difference, so run it
# when nobody is working. Plane's own hard-delete task can also remove rows that were soft-deleted, which reads the same.
#
# Objects are not read here, because Silo's image has no shell and no client. Run this next, which reads every object through rclone and
# checks that every uploaded row has one: make remote-backup TARGET=plane-prod CONFIRM=plane-prod ONLY=plane-prod
#
# Exit 0 the same after as before, 1 not, or something did not come back.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
hosted_require_confirm "this restarts Plane, so the public site is down for a minute or two"
hosted_verify
for tool in curl jq; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool not found. Run: make setup"
done

NS=plane-prod
STAMP="$(hosted_stamp)"
EVIDENCE="$HOSTED_EVIDENCE_DIR/restart-check-$STAMP.txt"
WORK="$(mktemp -d)"
PROBER=""
stop_prober() { if [[ -n "$PROBER" ]]; then kill "$PROBER" 2>/dev/null || true; wait "$PROBER" 2>/dev/null || true; PROBER=""; fi; }
trap 'stop_prober; rm -rf "$WORK"' EXIT
exec > >(tee "$EVIDENCE") 2>&1

read_state() {
  # shellcheck disable=SC2016 # those two are the pod's own, for its shell to expand
  kc -n "$NS" exec -i plane-pgdb-wl-0 -c plane-pgdb -- sh -c 'exec psql -XAt -F " " -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' <<'SQL'
SELECT 'instances', count(*), md5(coalesce(string_agg(id::text || ':' || is_setup_done::text, ',' ORDER BY id), '')) FROM instances
UNION ALL SELECT 'users', count(*), md5(coalesce(string_agg(id::text, ',' ORDER BY id), '')) FROM users
UNION ALL SELECT 'workspaces', count(*), md5(coalesce(string_agg(id::text || ':' || slug || ':' || name, ',' ORDER BY id), '')) FROM workspaces
UNION ALL SELECT 'projects', count(*), md5(coalesce(string_agg(id::text || ':' || name, ',' ORDER BY id), '')) FROM projects
UNION ALL SELECT 'issues', count(*), md5(coalesce(string_agg(id::text || ':' || coalesce(name, ''), ',' ORDER BY id), '')) FROM issues
UNION ALL SELECT 'pages', count(*), md5(coalesce(string_agg(id::text, ',' ORDER BY id), '')) FROM pages
UNION ALL SELECT 'file_assets', count(*), md5(coalesce(string_agg(id::text || ':' || coalesce(asset, ''), ',' ORDER BY id), '')) FROM file_assets;
SQL
}

# One line a sample: seconds since start, and the status the public API gave. Reads the database through the whole path.
probe_public() {
  local start=$SECONDS code
  while :; do
    code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "https://$HOSTED_DOMAIN/api/instances/" 2>/dev/null || true)"
    printf '%s %s\n' "$((SECONDS - start))" "${code:-000}" >>"$WORK/samples"
    sleep 2
  done
}

new_pod_ready() { # pod old-uid: it exists, it is not the old one, and it is Ready
  kc -n "$NS" get pod "$1" -o json 2>/dev/null |
    jq -e --arg old "$2" '.metadata.uid != $old and any(.status.conditions[]?; .type == "Ready" and .status == "True")' >/dev/null
}

restart_statefulset() { # name
  local pod="$1-0" uid
  uid="$(kc -n "$NS" get pod "$pod" -o jsonpath='{.metadata.uid}')"
  [[ -n "$uid" ]] || die "$pod does not exist"
  kc -n "$NS" delete pod "$pod" --timeout=180s >/dev/null
  wait_for 300 "$pod Ready again. Read: make remote-status TARGET=plane-prod" new_pod_ready "$pod" "$uid"
  ok "$pod is back"
}

deployment_replaced() { # selector space-separated-old-pods
  local selector="$1" old="$2" pods
  pods="$(kc -n "$NS" get pods -l "$selector" -o json)" || return 1
  jq -e --arg old " $old " '
    (.items | length) > 0
    and all(.items[]; . as $p | ($old | contains(" " + $p.metadata.name + " ")) | not)
    and all(.items[]; any(.status.conditions[]?; .type == "Ready" and .status == "True"))' <<<"$pods" >/dev/null
}

restart_deployment() { # name
  local selector old
  selector="$(kc -n "$NS" get deployment "$1" -o json | jq -r '.spec.selector.matchLabels | to_entries | map(.key + "=" + .value) | join(",")')"
  [[ -n "$selector" ]] || die "deployment $1 has no selector"
  old="$(kc -n "$NS" get pods -l "$selector" -o jsonpath='{.items[*].metadata.name}')"
  kc -n "$NS" delete pod -l "$selector" --timeout=180s >/dev/null
  wait_for 300 "$1 replaced and Ready. Read: make remote-status TARGET=plane-prod" deployment_replaced "$selector" "$old"
  ok "$1 is back"
}

log "Reading what Postgres holds"
read_state >"$WORK/before" || die "could not read Postgres, so nothing was restarted"
sed 's/^/  /' "$WORK/before"

probe_public &
PROBER=$!

# Data first, so the app restarted after it holds no connection to a server that has since gone.
log "Restarting the data services, one at a time"
for name in $(kc -n "$NS" get statefulsets -o json | jq -r '.items[].metadata.name' | sort -r); do
  restart_statefulset "$name"
done

log "Restarting the app"
for name in $(kc -n "$NS" get deployments -o json | jq -r '.items[].metadata.name | select(test("^plane-.*-wl$"))' | sort); do
  restart_deployment "$name"
done

failed=0
log "Waiting for the public API to answer again"
public_answers() { [[ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' "https://$HOSTED_DOMAIN/api/instances/" 2>/dev/null || true)" == 200 ]]; }
# Not a reason to stop: what Postgres holds is still worth comparing. On the first run this failed because this machine's own connection
# dropped for five minutes, while Traefik's log and Prometheus's probes showed the site answering, so read those before believing it.
deadline=$((SECONDS + 180))
until public_answers; do
  if [[ $SECONDS -ge $deadline ]]; then
    warn "https://$HOSTED_DOMAIN/api/instances/ gave this machine no 200 in 180 s. Check this machine's own connection, then Prometheus's probe_success"
    failed=1
    break
  fi
  sleep 3
done
sleep 4
stop_prober

log "Comparing"
read_state >"$WORK/after" || die "could not read Postgres after the restart"
if diff "$WORK/before" "$WORK/after" >"$WORK/diff"; then
  ok "Postgres holds the same rows after as before, by count and by hash, in $(wc -l <"$WORK/before" | tr -d ' ') tables"
else
  warn "Postgres differs after the restart, in these tables. Only hashes and counts are shown:"
  sed 's/^/  /' "$WORK/diff"
  failed=1
fi

awk '
  { total++ }
  $2 != "200" { down++; if (gap == 0) from = $1; gap = 1; last = $1 }
  $2 == "200" { if (gap) { len = last - from + 2; if (len > longest) longest = len } gap = 0 }
  END {
    if (gap) { len = last - from + 2; if (len > longest) longest = len }
    printf " ok public API: %d of %d samples failed, longest outage about %d s\n", down, total, longest
  }' "$WORK/samples"

crashed="$(kc -n "$NS" get pods -o json | jq -r '.items[] | .metadata.name as $p | .status.containerStatuses[]? | select(.restartCount > 0) | "\($p)/\(.name) restarted \(.restartCount) times"')"
if [[ -n "$crashed" ]]; then
  warn "a container crashed and came back, which a clean restart should not do:"
  printf '  %s\n' "$crashed"
  failed=1
else
  ok "no container in $NS restarted by itself"
fi

argo="$(kc -n argocd get application plane-prod -o json | jq -r '.status.sync.status + " " + .status.health.status')"
if [[ "$argo" == "Synced Healthy" ]]; then
  ok "Argo CD reads plane-prod $argo, so nothing here drifted from Git"
else
  warn "Argo CD reads plane-prod $argo, which may only mean it has not caught up. Read: make remote-status TARGET=plane-prod"
  failed=1
fi

log "Evidence: ${EVIDENCE#"$ROOT"/}"
log "Next, every object: make remote-backup TARGET=plane-prod CONFIRM=plane-prod ONLY=plane-prod"
[[ "$failed" == 0 ]] || die "the restart check found a difference"
ok "everything came back, with what it held"
