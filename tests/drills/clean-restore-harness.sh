#!/usr/bin/env bash
# Scenario tests for make restore-clean, make restore, make backup, make destroy and the clean-restore drill.
#
#   make drill-clean-restore-harness             all of it
#   make drill-clean-restore-harness ONLY="S1 S20"
#   HARNESS_SOURCE=<another checkout> tests/drills/clean-restore-harness.sh
#                                                the same scenarios against other code, to see them fail
# S and a number is a scenario of the first review of the clean restore or from before it. R and a number is finding
# that number of the second review, in clean-restore-harness/scenarios-second-review.sh.
#
# macOS, as the platform is: it wants /bin/bash 3.2, BSD stat and perl. It takes about half an hour, in the background.
#
# WHAT IT DOES. Each scenario copies the real scripts into a throwaway tree under $TMPDIR and runs them there:
# restore.sh, backup.sh, destroy.sh, up.sh, cluster-up.sh, secret-zero.sh, infisical-bootstrap.sh,
# infisical-seed.sh, the drill, and every library they source. Real: bash 3.2, jq, yq, shasum, openssl, git, the recovery
# sets and every other file on disk, and, as written and on real folders, the lines of the Plane backup Job for its
# retention and for what it records about uploaded rows. Stubbed, in tests/drills/clean-restore-harness/: kubectl, kind,
# docker, df, sleep, rclone, Terraform, tests/e2e/smoke.py, gitops-publish.sh, status.sh, build-images.sh, the Infisical
# API, and curl, which refuses anything but that API. Nothing here can reach the cluster, the registry or Docker on
# this machine.
#
# WHAT ITS ORDER CHECKS COVER. The calls the scripts make are real, and so is their order, but a check sees only the
# calls it names. S1 names the steps of a whole clean restore, and others name a few each. So a line nothing names can
# go, and every scenario still pass. tests/drills/clean-restore-mutants.sh removes such lines one at a time, and says
# which the scenarios catch and which they do not. Passing here says nothing about a call that list does not catch.
#
# WHAT IT PROVES. The logic of these scripts, against a model of the platform that keeps state: which step runs when,
# what each refusal refuses and says, what is left on disk, what a resume does, and that a stub's state is read back.
# Deployments have replicas, pods go when they reach zero, an Application reads Synced and Healthy only while what it
# owns matches Git, self-heal reverts a scale unless auto-sync is paused, the API refuses an unknown or expired token,
# a backup and a restore carry the API's database, and a token minted after a dump is not in that dump. A fresh server
# answers only after its migrations, and an API on a restored database only after the migrator. A Job left running has
# not done its work yet. Each thing that must not happen, such as starting what a running restore Job writes under,
# is logged as a line starting ERROR, and any scenario can look for those.
#
# WHAT IT DOES NOT PROVE. Anything about the platform itself. No Pod, Job, Argo CD, Postgres, Infisical, Traefik or disk is
# real here. A stub answers as the real thing was seen to answer, so a change in the real thing passes here and fails in
# the cluster. A wrong Job, a wrong SQL statement or a wrong API path can pass, and the Jobs' contents do not run. The
# proof of those is the real runs in infisical/README.md, and make drill-clean-restore CONFIRM=yes. A passing run of this
# says the scripts do what they were written to do, and nothing about whether a restore would work.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SOURCE="${HARNESS_SOURCE:-$REPO}"
STUBS="$REPO/tests/drills/clean-restore-harness"
H="$(mktemp -d "${TMPDIR:-/tmp}/clean-restore-harness.XXXXXX")"
BASE_PATH="$PATH"
PASSES=0
FAILS=0
API_PID=""
OUT="$H/out.txt"
RC=0
RUN_LIMIT_SECONDS="${RUN_LIMIT_SECONDS:-240}"

pass() { printf 'PASS  %s\n' "$*"; PASSES=$((PASSES + 1)); }
fail() { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }
scenario() { printf '\n=== %s\n' "$*"; }
log_has() { grep -E -- "$1" "$H/state/calls.log" >/dev/null 2>&1; }
no_log() { ! log_has "$1"; }
out_has() { grep -F -- "$1" "$OUT" >/dev/null; }
no_out() { ! out_has "$1"; }
no_clean_complete() { ! grep -E 'clean restore from Infisical backup [^ ]+ complete' "$OUT" >/dev/null; }
check() { # description command...
  local d="$1"
  shift
  if "$@" >/dev/null; then pass "$d"; else fail "$d"; fi
}
order() { # pattern... each after the previous in calls.log
  local line=0 p n
  for p in "$@"; do
    n="$(awk -v s="$line" -v p="$p" 'NR > s && $0 ~ p { print NR; exit }' "$H/state/calls.log")"
    if [[ -z "$n" ]]; then
      echo "  no '$p' after line $line" >&2
      return 1
    fi
    line=$n
  done
}
stop_api() {
  if [[ -n "$API_PID" ]]; then
    kill "$API_PID" 2>/dev/null
    wait "$API_PID" 2>/dev/null
    API_PID=""
  fi
}
trap 'stop_api; rm -rf "$H"' EXIT

jwt() { # exp. A token of the shape the server issues, for the instance admin identity.
  printf 'x.%s.y' "$(printf '{"exp":%s,"identityId":"adm","identityName":"Instance Admin Identity","orgId":"org-old"}' "$1" | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '=')"
}

start_api() {
  python3 -I "$STUBS/fakeapi.py" "$PORT" &
  API_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    /usr/bin/curl -s -o /dev/null -m 1 "$INFISICAL_URL/fake/registry" && break
    /bin/sleep 0.1
  done
}

reset() {
  stop_api
  rm -rf "$H"
  mkdir -p "$H"/{scripts/lib,scripts/ci,monitoring/ops,infisical/lib,infisical/terraform,infisical/manifests,tests/drills,tests/e2e,gitops/environments/dev,gitops/environments/prod-sim,gitops/applications,helm/values,infrastructure/kind,.tools/bin,state,.local/secret-zero,.local/terraform/infisical,.local/terraform/local,.local/evidence-raw}
  cp "$SOURCE"/scripts/{restore,backup,destroy,up,cluster-up,infisical-bootstrap,infisical-seed,secret-zero}.sh "$H/scripts/"
  cp "$SOURCE"/scripts/lib/*.sh "$H/scripts/lib/"
  cp "$SOURCE"/monitoring/ops/lib.sh "$H/monitoring/ops/"
  cp "$SOURCE"/infisical/lib/*.sh "$H/infisical/lib/"
  cp "$SOURCE"/infisical/manifests/postgres.yaml "$H/infisical/manifests/"
  cp "$SOURCE"/tests/drills/{clean-restore.sh,lib.sh} "$H/tests/drills/"
  cp "$REPO"/gitops/environments/dev/manifests.yaml "$H/gitops/environments/dev/"
  cp "$REPO"/gitops/environments/prod-sim/manifests.yaml "$H/gitops/environments/prod-sim/"
  cp "$REPO"/gitops/applications/*.yaml "$H/gitops/applications/"
  cp "$REPO"/helm/values/infisical.yaml "$H/helm/values/"
  cp "$REPO"/infrastructure/kind/cluster.yaml.tmpl "$H/infrastructure/kind/"
  cp "$REPO"/.gitignore "$H/"
  printf 'monitoring\n' > "$H/monitoring/README.md"
  cp "$STUBS"/gitops-publish.sh "$STUBS"/status.sh "$H/scripts/"
  cp "$STUBS"/build-images.sh "$H/scripts/ci/"
  cp "$STUBS"/smoke.py "$H/tests/e2e/smoke.py"
  cp "$STUBS"/{kubectl,kind,docker,terraform,df,sleep,curl} "$H/.tools/bin/"
  ln -s "$REPO/.tools/bin/yq" "$H/.tools/bin/yq"
  ln -s /bin/bash "$H/.tools/bin/bash"
  (
    cd "$H" && git init -q && git add -A . &&
      git -c user.name=harness -c user.email=harness@invalid -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -qm base
  ) >/dev/null 2>&1

  export H_ROOT="$H" H_STATE="$H/state" H_STUBS="$STUBS" PATH="$H/.tools/bin:$BASE_PATH"
  export UP_WAIT_TRAEFIK_SECONDS=15 UP_WAIT_ROUTE_SECONDS=15 UP_WAIT_INFISICAL_SECONDS=15 UP_WAIT_APPS_SECONDS=15 INFISICAL_WAIT_SECONDS=15 CLEAN_WAIT_APPS_SECONDS=3
  unset ENV BACKUP KEEP CONFIRM SKIP_BACKUP PLAN_ONLY SKIP_E2E ENVS BACKUP_DEV BACKUP_PROD_SIM PURGE LOSE_CLUSTER RESTORE_MODE
  unset ALLOW_LOW_DISK ALLOW_NO_SENTINEL ALLOW_NEWER_INFISICAL_BACKUP ALLOW_NO_ADMIN_TOKEN ALLOW_STALE_PLANE_SECRETS ALLOW_SECRET_KEY_MISMATCH
  unset ALLOW_RESUME_OVERWRITE ALLOW_BACKUP_DURING_RESTORE RESTORE_RESUME OVERRIDE_DEV_CHECK
  unset MIN_FREE_DISK_GIB RENEW_ADMIN_TOKEN INFISICAL_RESTORED UP_STOP_AFTER BACKUP_RETENTION_DAYS
  PORT=$((20000 + RANDOM % 10000))
  export INFISICAL_URL="http://127.0.0.1:$PORT"
  : > "$H/state/calls.log"

  local z="$H/.local/secret-zero" token
  chmod 700 "$z"
  printf 'k%.0s' 1 2 3 4 > "$z/ENCRYPTION_KEY"
  printf 'a%.0s' 1 2 3 > "$z/AUTH_SECRET"
  printf 'dbpw' > "$z/DB_PASSWORD"
  printf 'rdpw' > "$z/REDIS_PASSWORD"
  printf 'uipw' > "$z/infisical-admin-password"
  token="$(jwt $(($(date +%s) + 86400 * 60)))"
  jq -n --arg t "$token" '{email:"admin@wayline.localhost",token:$t,organization:{id:"org-old",name:"wayline",slug:"w"},identity:{id:"adm",name:"Instance Admin Identity"}}' > "$z/infisical-admin.json"
  jq -n '{organization:{id:"org-old",name:"wayline",slug:"w"},environment_slug:"prod",project_ids:{dev:"p-dev","prod-sim":"p-prod"},project_slugs:{dev:"plane-dev","prod-sim":"plane-prod-sim"},identity_ids:{dev:"i-dev","prod-sim":"i-prod"}}' > "$z/infisical-machine.json"
  chmod 600 "$z"/*
  jq -n '{serial:12,lineage:"L",resources:[1,2,3,4,5],outputs:{environment_slug:{value:"prod"},project_ids:{value:{dev:"p-dev","prod-sim":"p-prod"}},project_slugs:{value:{dev:"plane-dev","prod-sim":"plane-prod-sim"}},identity_ids:{value:{dev:"i-dev","prod-sim":"i-prod"}}}}' > "$H/.local/terraform/infisical/terraform.tfstate"
  jq -n '{generation:1}' > "$H/.local/terraform/local/terraform.tfstate"
  TOKEN="$token" Z="$z" H_STATE="$H/state" python3 -I - <<'PY'
import json, os, secrets
z, s, tok = os.environ["Z"], os.environ["H_STATE"], os.environ["TOKEN"]
keys = ["PG_USER", "PG_PASSWORD", "PG_DB", "RABBITMQ_USER", "RABBITMQ_PASSWORD", "SILO_ACCESS_KEY", "SILO_SECRET_KEY", "SECRET_KEY", "LIVE_SERVER_SECRET_KEY"]
def env():
    return {k: ("plane" if k in ("PG_USER", "PG_DB", "RABBITMQ_USER") else secrets.token_hex(24)) for k in keys}
proj = lambda e, tag: {k: {"value": v, "version": 1, "id": f"{tag}-{k}"} for k, v in e.items()}
read = lambda n: open(f"{z}/{n}").read()
json.dump({"initialized": True, "tokens": [tok], "password": read("infisical-admin-password"), "org": "org-old", "admin_identity": "adm",
           "project_ids": {"dev": "p-dev", "prod-sim": "p-prod"}, "identity_ids": {"dev": "i-dev", "prod-sim": "i-prod"},
           "projects": {"p-dev": proj(env(), "d"), "p-prod": proj(env(), "p")}}, open(f"{s}/api.json", "w"))
apps = ["plane-api-wl", "plane-worker-wl", "plane-beat-worker-wl", "plane-live-wl"]
workloads = {"infisical/infisical": 1}
workloads.update({f"{ns}/{d}": 1 for ns in ("plane-dev", "plane-prod-sim") for d in apps})
json.dump({"exists": True, "generation": 1, "namespaces": True, "plane_pvcs": True, "infisical_pvc": True,
           "zero": {"infisical-secrets": {"ENCRYPTION_KEY": read("ENCRYPTION_KEY"), "AUTH_SECRET": read("AUTH_SECRET")},
                    "infisical-db": {"POSTGRES_PASSWORD": read("DB_PASSWORD")}, "infisical-redis": {"REDIS_PASSWORD": read("REDIS_PASSWORD")}},
           "identities": {"plane-dev": "i-dev", "plane-prod-sim": "i-prod"}, "workloads": workloads,
           "users": {"plane-dev": 23, "plane-prod-sim": 23, "infisical": 1}, "objects": {"plane-dev": 1, "plane-prod-sim": 1}}, open(f"{s}/cluster.json", "w"))
json.dump({}, open(f"{s}/jobs.json", "w"))
PY
  printf 'update' > "$H/state/tf-scenario"
  printf 'PLANE_DEV_ADMIN_EMAIL=a@b\nPLANE_DEV_ADMIN_PASSWORD=devpw\nPLANE_DEV_API_TOKEN=devtok\nPLANE_PROD_SIM_ADMIN_EMAIL=c@d\nPLANE_PROD_SIM_ADMIN_PASSWORD=prodpw\nPLANE_PROD_SIM_API_TOKEN=prodtok\n' > "$H/.local/test-accounts.env"
  for e in dev prod-sim; do
    jq -n --arg e "$e" '{environment:$e,slug:"s",project_id:"p",work_item_id:"w",name:"n",asset_id:"a",sha256:"h",created_at:"c"}' > "$H/.local/test-sentinel-$e.json"
  done
  chmod 600 "$H/.local/test-accounts.env" "$H"/.local/test-sentinel-*.json
  start_api
  OUT="$H/state/out.txt"
}

# Runs in the tree and keeps output and exit code. A limit, because a script that waits on a state nothing can reach
# should fail its scenario and not hold up the run.
run() { # command...
  OUT="$H/state/out.txt"
  ( cd "$H" && exec perl -e 'alarm shift; exec @ARGV' "$RUN_LIMIT_SECONDS" "$@" ) > "$OUT" 2>&1
  RC=$?
}
show_tail() { if [[ "$RC" -ne "${1:-0}" ]]; then tail -"${2:-12}" "$OUT" | sed 's/^/    | /'; fi; }

take_backups() {
  ( cd "$H" && scripts/backup.sh all ) > "$H/state/backup.out" 2>&1 || {
    cat "$H/state/backup.out"
    fail "fixture: backup.sh all failed"
    return 1
  }
  /bin/sleep 1 # Backup ids are UTC seconds.
}

# The disaster: the cluster is gone and nothing else happened. Everything on the host stays as it was, including what
# describes the old cluster, because no make destroy ran.
lose_cluster() {
  S="$H/state" python3 -I - <<'PY'
import json, os
s = os.environ["S"]
c = json.load(open(f"{s}/cluster.json"))
json.dump({"exists": False, "generation": c.get("generation", 1)}, open(f"{s}/cluster.json", "w"))
json.dump({}, open(f"{s}/jobs.json", "w"))
PY
}
sum_zero() { (cd "$H/.local/secret-zero" && shasum -a 256 ENCRYPTION_KEY AUTH_SECRET DB_PASSWORD REDIS_PASSWORD infisical-admin-password infisical-admin.json); }
newest_evidence() { ls -t "$H"/.local/evidence-raw/"$1"-*.json | head -1; }
set_token_exp() { # exp: replaces the token in the admin file and in the fake database, as if it had always been this one
  local token
  token="$(jwt "$1")"
  jq --arg t "$token" '.token = $t' "$H/.local/secret-zero/infisical-admin.json" > "$H/state/t" && cp "$H/state/t" "$H/.local/secret-zero/infisical-admin.json"
  jq --arg t "$token" '.tokens = [$t]' "$H/state/api.json" > "$H/state/t" && cp "$H/state/t" "$H/state/api.json"
}
expire_named_token() { # Time passes after a complete backup: the token it names has ended. Only the clock can do that,
  # so the file and every dump that holds it are rewritten together, and the checksums with them.
  local old new exp=$(($(date +%s) - 86400)) dir token
  old="$(shasum -a 256 "$H/.local/secret-zero/infisical-admin.json" | cut -d' ' -f1)"
  token="$(jwt "$exp")"
  jq --arg t "$token" '.token = $t' "$H/.local/secret-zero/infisical-admin.json" > "$H/state/t" && cp "$H/state/t" "$H/.local/secret-zero/infisical-admin.json"
  new="$(shasum -a 256 "$H/.local/secret-zero/infisical-admin.json" | cut -d' ' -f1)"
  for dir in "$H"/.local/backups/infisical/*; do
    jq --arg t "$token" '.tokens = [$t]' "$dir/fake-api-dump.json" > "$H/state/t" && cp "$H/state/t" "$dir/fake-api-dump.json"
    jq --arg o "$old" --arg n "$new" 'if .secret_zero.files["infisical-admin.json"].sha256 == $o then .secret_zero.files["infisical-admin.json"].sha256 = $n else . end' "$dir/recovery/set.json" > "$H/state/t" && cp "$H/state/t" "$dir/recovery/set.json"
    (cd "$dir" && grep -v ' ./recovery/set.json$' SHA256SUMS > S.t; shasum -a 256 ./recovery/set.json >> S.t; mv S.t SHA256SUMS)
  done
  jq --arg t "$token" '.tokens = [$t]' "$H/state/api.json" > "$H/state/t" && cp "$H/state/t" "$H/state/api.json"
}
reseal() { # backup-dir file: after a change to a file in a backup, its checksum again
  (cd "$1" && grep -v " ./$2\$" SHA256SUMS > S.t; shasum -a 256 "./$2" >> S.t; mv S.t SHA256SUMS)
}
set_disk() { printf '%s' "$(($1 * 1048576))" > "$H/state/free-kib"; }
dirty_tree() { printf 'changed\n' >> "$H/monitoring/README.md"; }
empty_cluster() { # A cluster that holds nothing, as make up UP_STOP_AFTER=cluster leaves it.
  edit_cluster 'c["plane_pvcs"] = False; c["infisical_pvc"] = False; c["zero"] = {}; c["workloads"] = {"infisical/infisical": 1}; c["identities"] = {}; c["users"] = {}; c["objects"] = {}'
}
leave_paused() { # app...: auto-sync off, as a killed run leaves it
  local app
  for app in "$@"; do
    A="$app" S="$H/state" python3 -I -c '
import json, os
s = os.environ["S"]; c = json.load(open(f"{s}/cluster.json"))
c.setdefault("paused", {})[os.environ["A"]] = True
json.dump(c, open(f"{s}/cluster.json", "w"))'
  done
}
leave_scaled() { # replicas namespace/name...: as a killed run leaves them
  local n="$1" key
  shift
  for key in "$@"; do
    N="$n" K="$key" S="$H/state" python3 -I -c '
import json, os
s = os.environ["S"]; c = json.load(open(f"{s}/cluster.json"))
c.setdefault("workloads", {})[os.environ["K"]] = int(os.environ["N"])
json.dump(c, open(f"{s}/cluster.json", "w"))'
  done
}
edit_cluster() { # Python statements on c, what the fake cluster holds.
  C="$1" S="$H/state" python3 -I -c '
import json, os
s = os.environ["S"]; c = json.load(open(f"{s}/cluster.json"))
exec(os.environ["C"])
json.dump(c, open(f"{s}/cluster.json", "w"))'
}
cluster_holds() { # namespace users objects: what that namespace holds right now
  edit_cluster "c.setdefault('users', {})['$1'] = $2; c.setdefault('objects', {})['$1'] = $3"
}
cluster_value() { jq -r "$1" "$H/state/cluster.json"; }
plane_counts() { # users: what the next Plane backups count
  printf '{"users":%s,"workspaces":16,"projects":31,"issues":132,"file_assets":34}' "$1" > "$H/state/plane-counts.json"
}
fail_line_has() { grep '^FAIL' "$OUT" | grep -F -- "$1" >/dev/null; }
step_status_is() { # evidence-file step status
  jq -e --arg s "$2" --arg st "$3" 'any(.steps[]; .step == $s and .status == $st)' "$1"
}
# In a session of its own, so a signal can reach all of it, as Ctrl-C does. A shell starts a background job with SIGINT
# ignored, and a script cannot trap what it was started ignoring, so this puts that back as a terminal would have it.
# Sets DETACHED and OUT.
start_detached() { # command...
  OUT="$H/state/detached.txt"
  ( cd "$H" && exec python3 -I -c 'import os,signal,sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' "$@" ) > "$OUT" 2>&1 &
  DETACHED=$!
}
wait_for_log() { # pattern
  local waited=0
  until log_has "$1" || [[ "$waited" -gt 900 ]]; do
    /bin/sleep 0.2
    waited=$((waited + 1))
  done
  log_has "$1"
}
stop_detached() { # signal. Sets RC to how it ended.
  kill "-$1" -- "-$DETACHED" 2>/dev/null
  wait "$DETACHED" 2>/dev/null
  RC=$?
}
write_marker() { # Under way, as a run that got this far leaves it.
  local iid dev prod
  iid="$(ls "$H/.local/backups/infisical" | tail -1)"
  dev="$(ls "$H/.local/backups/dev" | tail -1)"
  prod="$(ls "$H/.local/backups/prod-sim" | tail -1)"
  printf 'infisical=%s\nenvs=dev prod-sim\ndev=%s\nprod-sim=%s\n' "$iid" "$dev" "$prod" > "$H/.local/restore-clean.state"
  local step
  for step in "$@"; do printf 'done %s\n' "$step" >> "$H/.local/restore-clean.state"; done
}

# ------------------------------------------------------------------------------------------------

S0() {
  scenario "S0. What the fixture itself can see, so a pass below means something"
  reset
  local token
  token="$(jq -r .token "$H/.local/secret-zero/infisical-admin.json")"
  check "no token: the API refuses a secret read" test "$(/usr/bin/curl -s -o /dev/null -w '%{http_code}' "$INFISICAL_URL/api/v4/secrets?projectId=p-dev&environment=prod")" = 401
  check "a made-up token: refused" test "$(/usr/bin/curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer nope' "$INFISICAL_URL/api/v4/secrets?projectId=p-dev&environment=prod")" = 401
  check "the real token: accepted" test "$(/usr/bin/curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $token" "$INFISICAL_URL/api/v4/secrets?projectId=p-dev&environment=prod")" = 200
  check "a Plane app's pods are there" test -n "$(cd "$H" && .tools/bin/kubectl -n plane-dev get pods -l 'app.kubernetes.io/component in (api,worker,beat,live)' -o name)"
  ( cd "$H" && .tools/bin/kubectl -n infisical scale deployment/infisical --replicas=0 )
  check "self-heal reverts a scale while auto-sync is on" log_has 'self-heal reverted'
  check "so the server still answers" test "$(/usr/bin/curl -s -o /dev/null -w '%{http_code}' "$INFISICAL_URL/api/status")" = 200
  leave_paused infisical
  ( cd "$H" && .tools/bin/kubectl -n infisical scale deployment/infisical --replicas=0 )
  check "paused, the scale stands, and nothing answers" test "$(/usr/bin/curl -s -o /dev/null -w '%{http_code}' "$INFISICAL_URL/api/status")" = 503
  check "and the Application is not Synced and Healthy" test "$(cd "$H" && .tools/bin/kubectl -n argocd get application infisical -o jsonpath='{.status.sync.status}/{.status.health.status}')" = OutOfSync/Progressing
  check "the curl on the path refuses a real host" test "$(cd "$H" && .tools/bin/curl -s -o /dev/null -w '%{http_code}' https://example.com 2>/dev/null; echo "$?")" = 7
  reset
  lose_cluster
  check "a lost cluster leaves its local state, as a real loss does" test -f "$H/.local/terraform/local/terraform.tfstate"
}

S1() {
  scenario "S1. The happy path: nothing left but the host's files"
  reset
  take_backups
  local before
  before="$(sum_zero)"
  : > "$H/state/calls.log"
  lose_cluster
  run scripts/restore.sh clean latest
  check "exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "order: up to Traefik, stop the server, restore job, flush, start, full up in restored mode, then each environment" order \
    'kind create cluster' \
    'tf local apply' \
    'kc patch application infisical pause' \
    'kc scale deployment/infisical --replicas=0 ns=infisical' \
    'kc apply Job plane-restore ns=infisical' \
    'kc exec redis FLUSHALL ns=infisical' \
    'kc scale deployment/infisical --replicas=1 ns=infisical' \
    'kc patch application infisical resume' \
    'tf plan' 'tf apply saved-plan' \
    'kc publish identity ns=plane-dev id=i-dev' 'kc publish identity ns=plane-prod-sim id=i-prod' \
    'kc apply Job plane-restore-guard ns=plane-dev' 'kc apply Job plane-restore-guard-objects ns=plane-dev' \
    'kc patch application root pause' 'kc patch application plane-dev pause' \
    'kc scale deployment/plane-api-wl --replicas=0 ns=plane-dev' 'kc scale deployment/plane-live-wl --replicas=0 ns=plane-dev' \
    'kc apply Job plane-restore ns=plane-dev' \
    'kc exec valkey FLUSHALL ns=plane-dev' 'kc exec rabbitmq purge ns=plane-dev' 'kc apply Job plane-restore-migrate ns=plane-dev' \
    'kc scale deployment/plane-api-wl --replicas=1 ns=plane-dev' 'kc scale deployment/plane-live-wl --replicas=1 ns=plane-dev' \
    'kc exec proof-decrypt ns=plane-dev' 'smoke --env dev --mode verify proof' \
    'kc patch application plane-dev resume' 'kc patch application root resume' \
    'kc apply Job plane-restore-guard ns=plane-prod-sim' 'kc apply Job plane-restore-guard-objects ns=plane-prod-sim' \
    'kc patch application root pause' 'kc patch application plane-prod-sim pause' \
    'kc scale deployment/plane-api-wl --replicas=0 ns=plane-prod-sim' \
    'kc apply Job plane-restore ns=plane-prod-sim' \
    'kc exec valkey FLUSHALL ns=plane-prod-sim' 'kc exec rabbitmq purge ns=plane-prod-sim' 'kc apply Job plane-restore-migrate ns=plane-prod-sim' \
    'kc scale deployment/plane-api-wl --replicas=1 ns=plane-prod-sim' \
    'kc exec proof-decrypt ns=plane-prod-sim' 'smoke --env prod-sim --mode verify proof' \
    'smoke --env dev --mode verify$' 'smoke --env prod-sim --mode verify$'
  check "no database or cache was replaced under a running server" no_log '^ERROR'
  check "root was never paused for Infisical" order 'kc patch application infisical resume' 'kc publish identity' 'kc patch application root pause'
  check "no admin bootstrap call" no_log 'api POST bootstrap'
  check "no secret written" no_log 'api POST secrets/batch'
  check "no password login: the token this backup names still works" no_log 'api POST login'
  check "terraform never ran with -auto-approve" no_log 'tf apply auto-approve'
  check "marker removed" test ! -e "$H/.local/restore-clean.state"
  check "secret zero unchanged" test "$before" = "$(sum_zero)"
  check "no archive made" test -z "$(find "$H/.local/secret-zero" -maxdepth 1 -name 'archive-*')"
  check "evidence says PASS" jq -e '.result == "PASS"' "$(newest_evidence restore-clean)"
  check "every clean step PASS" jq -e 'all(.steps[]; .status == "PASS")' "$(newest_evidence restore-clean)"
  check "the plan named row and object counts" out_has "23 users, 16 workspaces, 31 projects, 132 work items, 34 file rows, 1 objects"
  check "and for Infisical" out_has "1 users, 6 projects, 18 secrets"
}

S2() {
  scenario "S2. A cluster with data: refuse, change nothing, and say which backup and how to keep it the newest"
  reset
  take_backups
  local iid
  iid="$(ls "$H/.local/backups/infisical" | tail -1)"
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "non-zero exit" test "$RC" -ne 0
  check "says why" out_has "already holds Plane volumes"
  check "the advice skips a backup, which would take over BACKUP=latest (finding 10)" out_has "make destroy CONFIRM=yes SKIP_BACKUP=yes"
  check "and names the backup to come back to" out_has "make restore-clean BACKUP=$iid"
  check "marker not written" test ! -e "$H/.local/restore-clean.state"
  check "nothing ran" no_log 'kind create|kc apply|kc scale'
}

S3() {
  scenario "S3. No Infisical backup at all, Plane backups exist"
  reset
  take_backups
  rm -rf "$H/.local/backups/infisical"
  lose_cluster
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "non-zero exit" test "$RC" -ne 0
  check "says Infisical is the source of truth" out_has "no Infisical backup with a complete recovery set"
  check "nothing ran" no_log 'kind create|kc apply|kc scale'
}

S4() {
  scenario "S4. Plane backup taken with another SECRET_KEY"
  reset
  take_backups
  local f d
  for f in "$H"/.local/backups/dev/*/manifest.json; do
    jq '.secret_key_fp = "0000000000000000"' "$f" > "$f.t" && mv "$f.t" "$f"
    d="${f%/manifest.json}"
    reseal "$d" manifest.json
  done
  lose_cluster
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "non-zero exit" test "$RC" -ne 0
  check "names the mismatch" out_has "no backup of dev matches Infisical backup"
  check "tells what to do" out_has "ENVS="
  check "nothing ran" no_log 'kind create|kc apply|kc scale'
  run scripts/restore.sh clean latest ENVS=prod-sim PLAN_ONLY=yes
  check "leaving dev out passes the plan" test "$RC" -eq 0
}

S5() {
  scenario "S5. A tampered dump"
  reset
  take_backups
  printf 'tampered' >> "$(ls -d "$H"/.local/backups/prod-sim/*/ | tail -1)postgres/plane.dump"
  lose_cluster
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "non-zero exit" test "$RC" -ne 0
  check "says which" out_has "does not match its SHA256SUMS"
  check "nothing ran" no_log 'kind create|kc apply|kc scale'
}

S6() {
  scenario "S6. A key gone: a clear refusal, and only the hint that applies (finding 2)"
  reset
  take_backups
  rm "$H/.local/secret-zero/ENCRYPTION_KEY"
  lose_cluster
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "ENCRYPTION_KEY: non-zero exit" test "$RC" -ne 0
  check "ENCRYPTION_KEY: no shell error in the output" no_out "syntax error"
  check "ENCRYPTION_KEY: no shell source in the output" no_out "printf"
  check "ENCRYPTION_KEY: says the dump is unreadable" out_has "the dump is unreadable"
  check "ENCRYPTION_KEY: and not the AUTH_SECRET hint" no_out "nothing this instance signed"
  check "ENCRYPTION_KEY: nothing ran" no_log 'kind create|kc apply|kc scale'
  reset
  take_backups
  rm "$H/.local/secret-zero/AUTH_SECRET"
  lose_cluster
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "AUTH_SECRET: non-zero exit" test "$RC" -ne 0
  check "AUTH_SECRET: no shell error in the output" no_out "syntax error"
  check "AUTH_SECRET: no shell source in the output" no_out "printf"
  check "AUTH_SECRET: its own hint" out_has "nothing this instance signed"
  check "AUTH_SECRET: and not the ENCRYPTION_KEY hint" no_out "the dump is unreadable"
  check "AUTH_SECRET: nothing ran" no_log 'kind create|kc apply|kc scale'
  check "no script in the source has a case inside a command substitution" \
    python3 -I "$STUBS/scan-case-in-substitution.py" "$SOURCE"/scripts/*.sh "$SOURCE"/scripts/lib/*.sh "$SOURCE"/infisical/lib/*.sh "$SOURCE"/monitoring/ops/lib.sh "$SOURCE"/tests/drills/*.sh
}

S7() {
  scenario "S7. A plain make up came first, which archived the credentials. Restore finds them by checksum"
  reset
  take_backups
  local want
  want="$(sum_zero)"
  mkdir "$H/.local/secret-zero/archive-20260101T000000Z"
  mv "$H/.local/secret-zero/infisical-admin.json" "$H/.local/secret-zero/infisical-admin-password" "$H/.local/secret-zero/archive-20260101T000000Z/"
  printf '{"token":"x.e30.y","organization":{"id":"org-new"}}' > "$H/.local/secret-zero/infisical-admin.json"
  printf 'newpw' > "$H/.local/secret-zero/infisical-admin-password"
  mv "$H/.local/terraform/infisical/terraform.tfstate" "$H/.local/terraform/infisical/terraform.tfstate.stale-x"
  printf '{"serial":1,"lineage":"new","resources":[]}' > "$H/.local/terraform/infisical/terraform.tfstate"
  lose_cluster
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "credentials are the backup's again" test "$want" = "$(sum_zero)"
  check "what it replaced is kept" test -n "$(find "$H/.local/secret-zero" -maxdepth 2 -path '*archive-pre-restore-*' -name infisical-admin.json)"
  check "Terraform state is the backup's" jq -e '.lineage == "L" and .serial == 12' "$H/.local/terraform/infisical/terraform.tfstate"
  check "the state it replaced is kept" test -n "$(find "$H/.local/terraform/infisical" -name 'terraform.tfstate.pre-restore-*')"

  # The key itself in an archive, and another in its place. secret-zero.sh applies what is in place, and the dump can be
  # read only with the old one, so this is what putting them back is for: no token path brings it back.
  reset
  take_backups
  want="$(sum_zero)"
  mkdir "$H/.local/secret-zero/archive-20260101T000000Z"
  mv "$H/.local/secret-zero/ENCRYPTION_KEY" "$H/.local/secret-zero/archive-20260101T000000Z/"
  printf 'a-key-from-another-instance' > "$H/.local/secret-zero/ENCRYPTION_KEY"
  lose_cluster
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "the key this dump needs is in an archive: found by checksum, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "the key this dump needs is back in place" test "$want" = "$(sum_zero)"
  check "and the other is kept" grep -l 'a-key-from-another-instance' "$H"/.local/secret-zero/archive-pre-restore-*/ENCRYPTION_KEY
}

S8() {
  scenario "S8. Fails partway, then resumes"
  reset
  take_backups
  lose_cluster
  : > "$H/state/calls.log"
  printf '[["plane-restore-2","plane-dev"]]' > "$H/state/fail-jobs.json"
  run scripts/restore.sh clean latest
  check "first run fails at dev" test "$RC" -ne 0
  check "marker stays" test -f "$H/.local/restore-clean.state"
  check "Infisical marked done" grep -qx 'done infisical' "$H/.local/restore-clean.state"
  check "the wait for all Applications is marked done" grep -qx 'done up-all' "$H/.local/restore-clean.state"
  check "says to run it again" out_has "it resumes"
  rm -f "$H/state/fail-jobs.json"
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "second run exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "Infisical not restored twice" no_log 'kc apply Job plane-restore ns=infisical'
  check "dev restored this time" log_has 'kc apply Job plane-restore ns=plane-dev'
  check "marker removed" test ! -e "$H/.local/restore-clean.state"
  check "says it did not wait for everything again until the end" jq -e 'any(.steps[]; .step == "up-to-infisical" and .status == "PASS")' "$(newest_evidence restore-clean)"
}

S9() {
  scenario "S9. Under way, a plain make up on the fresh instance, and another backup id"
  reset
  take_backups
  local iid rc2
  iid="$(ls "$H/.local/backups/infisical" | tail -1)"
  lose_cluster
  : > "$H/state/calls.log"
  printf '[["plane-restore-2","infisical"]]' > "$H/state/fail-jobs.json"
  run scripts/restore.sh clean latest
  check "first run stops at the Infisical restore" test "$RC" -ne 0
  check "marker there" test -f "$H/.local/restore-clean.state"
  rm -f "$H/state/fail-jobs.json"
  : > "$H/state/calls.log"
  (cd "$H" && exec perl -e 'alarm shift; exec @ARGV' 120 scripts/up.sh) > "$H/state/o2.txt" 2>&1
  rc2=$?
  check "plain up refuses to bootstrap a fresh instance while a restore is under way" test "$rc2" -ne 0
  grep -F 'a clean restore is under way' "$H/state/o2.txt" >/dev/null
  check "and says so" test "$?" -eq 0
  check "no bootstrap call" no_log 'api POST bootstrap'
  run scripts/restore.sh clean 20200101T000000Z
  check "another backup id refused while one is under way" out_has "is under way"
  run scripts/restore.sh clean "$iid"
  check "the same id resumes, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
}

S10() {
  scenario "S10. Restored mode refuses instead of repairing"
  local sc
  for sc in create replace; do
    reset
    take_backups
    printf '%s' "$sc" > "$H/state/tf-scenario"
    : > "$H/state/calls.log"
    run env INFISICAL_RESTORED=yes scripts/infisical-bootstrap.sh
    check "$sc: non-zero" test "$RC" -ne 0
    check "$sc: names the resource" out_has "infisical_"
    check "$sc: nothing applied" no_log 'tf apply'
  done
  reset
  take_backups
  printf 'none' > "$H/state/tf-scenario"
  : > "$H/state/calls.log"
  run env INFISICAL_RESTORED=yes scripts/infisical-bootstrap.sh
  check "no changes: exit 0 (got $RC)" test "$RC" -eq 0
  check "no changes: says so" out_has "nothing to change"
  check "no changes: identities still published" log_has 'kc publish identity ns=plane-dev'
  check "no changes: no write" no_log 'api POST secrets'
  reset
  take_backups
  jq '.initialized = false' "$H/state/api.json" > "$H/state/t" && cp "$H/state/t" "$H/state/api.json"
  : > "$H/state/calls.log"
  run env INFISICAL_RESTORED=yes scripts/infisical-bootstrap.sh
  check "fresh instance: refuses" test "$RC" -ne 0
  check "fresh instance: says the restore did not take" out_has "the restore did not take"
  check "fresh instance: no bootstrap call" no_log 'api POST bootstrap'
  check "fresh instance: nothing archived" test -z "$(find "$H/.local/secret-zero" -maxdepth 1 -name 'archive-*')"
  reset
  take_backups
  jq '.tokens = ["someone-else"]' "$H/state/api.json" > "$H/state/t" && cp "$H/state/t" "$H/state/api.json"
  : > "$H/state/calls.log"
  run env INFISICAL_RESTORED=yes scripts/infisical-bootstrap.sh
  check "rejected token: refuses" test "$RC" -ne 0
  check "rejected token: says so" out_has "same set"
  check "rejected token: does not mint its way past it" no_log 'api POST mint'
  reset
  take_backups
  jq 'del(.projects["p-dev"].SECRET_KEY)' "$H/state/api.json" > "$H/state/t" && cp "$H/state/t" "$H/state/api.json"
  : > "$H/state/calls.log"
  run env INFISICAL_RESTORED=yes scripts/infisical-bootstrap.sh
  check "missing secret: refuses" test "$RC" -ne 0
  check "missing secret: names it, generates nothing" out_has "SECRET_KEY"
  check "missing secret: no write" no_log 'api POST secrets/batch'
  reset
  take_backups
  rm "$H/.local/terraform/infisical/terraform.tfstate"
  : > "$H/state/calls.log"
  run env INFISICAL_RESTORED=yes scripts/infisical-bootstrap.sh
  check "no state: refuses before planning" test "$RC" -ne 0
  check "no state: no plan" no_log 'tf plan'
}

S11() {
  scenario "S11. Plain make up on a fresh instance works as before, including over old state"
  reset
  jq '.initialized = false | .tokens = [] | .projects = {} | .password = ""' "$H/state/api.json" > "$H/state/t" && cp "$H/state/t" "$H/state/api.json"
  : > "$H/state/calls.log"
  run scripts/infisical-bootstrap.sh
  check "exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "bootstrap call" log_has 'api POST bootstrap'
  check "old credentials moved to an archive" test -n "$(find "$H/.local/secret-zero" -maxdepth 2 -path '*archive-*' -name infisical-admin.json)"
  check "old Terraform state moved aside" test -n "$(find "$H/.local/terraform/infisical" -name 'terraform.tfstate.stale-*')"
  check "terraform ran with -auto-approve" log_has 'tf apply auto-approve'
  check "secrets seeded in both projects" test "$(grep -c 'api POST secrets/batch n=9' "$H/state/calls.log")" -eq 2
  check "identity published" log_has 'kc publish identity ns=plane-dev'
}

S12() {
  scenario "S12. destroy.sh keeps what a restore needs"
  reset
  take_backups
  local before_state
  before_state="$(shasum -a 256 "$H/.local/terraform/infisical/terraform.tfstate")"
  : > "$H/state/calls.log"
  run env CONFIRM=yes SKIP_BACKUP=yes scripts/destroy.sh
  check "exit 0 (got $RC)" test "$RC" -eq 0
  check "cluster deleted" log_has 'kind delete cluster'
  check "local state removed" test ! -e "$H/.local/terraform/local"
  check "Infisical state kept, byte for byte" test "$before_state" = "$(shasum -a 256 "$H/.local/terraform/infisical/terraform.tfstate")"
  check "secret zero kept" test -s "$H/.local/secret-zero/ENCRYPTION_KEY"
  check "points at restore-clean" out_has "make restore-clean"
  reset
  run env CONFIRM=yes scripts/destroy.sh
  check "with its own backup: warns that latest now names it (finding 10)" out_has "BACKUP=latest now names the backup just taken"
  reset
  run env CONFIRM=yes SKIP_BACKUP=yes PURGE=yes scripts/destroy.sh
  check "PURGE=yes: says the registry held images (finding 5)" out_has "Git deploys images from the local registry"
}

S13() {
  scenario "S13. The drill, start to finish"
  reset
  run env PLAN_ONLY=yes tests/drills/clean-restore.sh
  check "PLAN_ONLY: exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "PLAN_ONLY: deleted nothing" no_log 'kind delete cluster'
  run tests/drills/clean-restore.sh
  check "no CONFIRM: refuses" test "$RC" -ne 0
  /bin/sleep 1
  run env CONFIRM=yes SKIP_E2E=yes tests/drills/clean-restore.sh
  check "drill exit 0 (got $RC)" test "$RC" -eq 0
  if [[ "$RC" -ne 0 ]]; then grep -E 'FAIL|RESULT|fail' "$OUT" | head -20 | sed 's/^/    | /'; fi
  check "drill deleted the cluster" log_has 'kind delete cluster'
  check "RESULT PASS" out_has "RESULT PASS"
  grep -E '^FAIL' "$OUT" | head -10 | sed 's/^/    | /'
  reset
  run env CONFIRM=yes SKIP_E2E=yes LOSE_CLUSTER=yes tests/drills/clean-restore.sh
  check "LOSE_CLUSTER=yes: the disaster path, exit 0 (got $RC)" test "$RC" -eq 0
  check "LOSE_CLUSTER=yes: the state stayed behind for the restore to deal with" out_has "was left behind, as a disaster leaves it"
  check "LOSE_CLUSTER=yes: and it moved it aside" out_has "moved aside, not applied over"
  check "LOSE_CLUSTER=yes: Terraform never applied over it" no_log 'tf local apply over stale state'
  check "LOSE_CLUSTER=yes: RESULT PASS" out_has "RESULT PASS"
}

S14() {
  scenario "S14. Rotation guard on an in-place restore"
  reset
  take_backups
  jq '.projects["p-dev"].PG_PASSWORD.value = "rotated-since-the-dump" | .projects["p-dev"].PG_PASSWORD.version = 2' "$H/state/api.json" > "$H/state/t" && cp "$H/state/t" "$H/state/api.json"
  : > "$H/state/calls.log"
  run scripts/restore.sh infisical latest CONFIRM=yes
  check "refuses" test "$RC" -ne 0
  check "says a rotation happened" out_has "a rotation or a manual change happened after it"
  check "names the keys" out_has "POSTGRES_PASSWORD"
  check "nothing stopped" no_log 'kc scale'
  : > "$H/state/calls.log"
  run scripts/restore.sh infisical latest CONFIRM=yes ALLOW_STALE_PLANE_SECRETS=yes
  check "the override goes on" log_has 'kc scale deployment/infisical --replicas=0 ns=infisical'
}

S15() {
  scenario "S15. A restore under way, and the cluster it was working on goes away"
  reset
  take_backups
  lose_cluster
  : > "$H/state/calls.log"
  printf '[["plane-restore-2","plane-dev"]]' > "$H/state/fail-jobs.json"
  run scripts/restore.sh clean latest
  check "fails at dev, Infisical marked done" grep -qx 'done infisical' "$H/.local/restore-clean.state"
  rm -f "$H/state/fail-jobs.json"
  lose_cluster
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "run again with the cluster gone: exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "Infisical restored again, because the new cluster has none" log_has 'kc apply Job plane-restore ns=infisical'
  reset
  take_backups
  lose_cluster
  printf '[["plane-restore-2","plane-dev"]]' > "$H/state/fail-jobs.json"
  run scripts/restore.sh clean latest
  check "fails at dev, marker there" test -f "$H/.local/restore-clean.state"
  run env CONFIRM=yes SKIP_BACKUP=yes scripts/destroy.sh
  check "destroy clears the marker" test ! -e "$H/.local/restore-clean.state"
}

S16() {
  scenario "S16. PLAN_ONLY changes nothing, on a live cluster or with a restore under way"
  reset
  take_backups
  sum_tree() { (cd "$H/.local" && find . -type f ! -path './evidence-raw/*' -exec shasum -a 256 {} + | LC_ALL=C sort | shasum -a 256); }
  local a
  a="$(sum_tree)"
  run scripts/restore.sh clean latest PLAN_ONLY=yes
  check "PLAN_ONLY exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "not one file under .local changed" test "$a" = "$(sum_tree)"
  check "the disk line is in the plan (finding 4)" out_has "kind volume 11.4 GiB"
  lose_cluster
  write_marker infisical
  a="$(sum_tree)"
  run scripts/restore.sh clean latest PLAN_ONLY=yes
  check "with a marker and no cluster: exit 0 (got $RC)" test "$RC" -eq 0
  check "with a marker and no cluster: not one file changed" test "$a" = "$(sum_tree)"
  check "with a marker and no cluster: still says done" grep -qx 'done infisical' "$H/.local/restore-clean.state"
  check "the plan says the stale state would move, and moves nothing (finding 6)" out_has "a real run moves it aside"
  check "the state is where it was" test -f "$H/.local/terraform/local/terraform.tfstate"
}

S17() {
  scenario "S17. Infisical cannot be read at backup time: the backup says so, and a clean restore passes over it"
  reset
  take_backups
  local good rc3 bad
  good="$(ls "$H/.local/backups/infisical" | tail -1)"
  /bin/sleep 1
  stop_api
  ( cd "$H" && scripts/backup.sh infisical ) > "$H/state/o3.txt" 2>&1
  rc3=$?
  check "backup exits non-zero (got $rc3)" test "$rc3" -ne 0
  grep -F 'its recovery set is not whole' "$H/state/o3.txt" >/dev/null
  check "and says why" test "$?" -eq 0
  bad="$(ls "$H/.local/backups/infisical" | tail -1)"
  check "the dump is kept" test -f "$H/.local/backups/infisical/$bad/postgres/infisical.dump"
  check "a newer backup exists" test "$bad" != "$good"
  start_api
  run scripts/restore.sh clean latest PLAN_ONLY=yes
  check "latest passes over it, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "and names it" out_has "$bad"
  check "and uses the good one" out_has "Infisical  $good"
  run scripts/restore.sh clean "$bad" PLAN_ONLY=yes
  check "naming it directly is refused" test "$RC" -ne 0
  check "with the reason" out_has "could not complete it"
}

S18() {
  scenario "S18. An older Infisical backup pairs with the Plane backups of its own run"
  reset
  take_backups
  local first_i first_d second_d second_i
  first_i="$(ls "$H/.local/backups/infisical" | tail -1)"
  first_d="$(ls "$H/.local/backups/dev" | tail -1)"
  take_backups
  second_i="$(ls "$H/.local/backups/infisical" | tail -1)"
  second_d="$(ls "$H/.local/backups/dev" | tail -1)"
  check "two distinct sets" test "$first_i" != "$second_i"
  run scripts/restore.sh clean "$first_i" PLAN_ONLY=yes
  check "older Infisical id takes the dev backup of its own run" out_has "dev        $first_d"
  run scripts/restore.sh clean latest PLAN_ONLY=yes
  check "latest takes the newest" out_has "dev        $second_d"
  run scripts/restore.sh clean "$first_i" PLAN_ONLY=yes BACKUP_DEV="$second_d"
  check "BACKUP_DEV overrides" out_has "dev        $second_d"
}

S19() {
  scenario "S19. Plane restore puts back the accounts and sentinel of its dump, and leaves the other environment's alone"
  reset
  take_backups
  printf 'PLANE_DEV_ADMIN_EMAIL=a@b\nPLANE_DEV_ADMIN_PASSWORD=devpw\nPLANE_DEV_API_TOKEN=NEWER\nPLANE_PROD_SIM_ADMIN_EMAIL=c@d\nPLANE_PROD_SIM_ADMIN_PASSWORD=prodpw\nPLANE_PROD_SIM_API_TOKEN=KEEPME\n' > "$H/.local/test-accounts.env"
  jq '.name = "newer"' "$H/.local/test-sentinel-dev.json" > "$H/state/t" && cp "$H/state/t" "$H/.local/test-sentinel-dev.json"
  : > "$H/state/calls.log"
  run scripts/restore.sh dev latest CONFIRM=yes
  check "exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  grep -qx 'PLANE_DEV_API_TOKEN=devtok' "$H/.local/test-accounts.env"
  check "dev token is the dump's" test "$?" -eq 0
  grep -qx 'PLANE_PROD_SIM_API_TOKEN=KEEPME' "$H/.local/test-accounts.env"
  check "prod-sim token untouched" test "$?" -eq 0
  check "file stays 0600" test "$(stat -f %Lp "$H/.local/test-accounts.env")" = 600
  check "sentinel is the dump's" jq -e '.name == "n"' "$H/.local/test-sentinel-dev.json"
}

S20() {
  scenario "S20. Finding 1: the token a backup names has expired, and the password is here. A password login mints another"
  reset
  take_backups
  local named set_sha
  expire_named_token
  named="$(shasum -a 256 "$H/.local/secret-zero/infisical-admin.json" | cut -d' ' -f1)"
  lose_cluster
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest PLAN_ONLY=yes
  check "the plan goes through, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "and warns" out_has "the admin token this backup names ends at"
  check "and says what happens" out_has "mints another and records it"
  run scripts/restore.sh clean latest
  check "the restore goes through, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "the login comes after the database is back, and before anything reads a value" order \
    'kc scale deployment/infisical --replicas=1 ns=infisical' 'api POST login' 'api POST mint' 'api GET secrets' 'kc publish identity ns=plane-dev'
  check "evidence says PASS" jq -e '.result == "PASS"' "$(newest_evidence restore-clean)"
  check "the Infisical restore records that it was replaced" jq -e 'any(.steps[]; .step == "admin-token" and (.detail | test("replaced")))' "$(newest_evidence restore-infisical)"
  check "the file now holds another token" test "$named" != "$(shasum -a 256 "$H/.local/secret-zero/infisical-admin.json" | cut -d' ' -f1)"
  check "and it has not expired" test "$(jq -r '.token | split(".")[1] | gsub("-"; "+") | gsub("_"; "/") | (. + ("=" * ((4 - (length % 4)) % 4))) | @base64d | fromjson | .exp' "$H/.local/secret-zero/infisical-admin.json")" -gt "$(date +%s)"
  check "the ledger links the old file to the new" jq -e --arg o "$named" 'select(.old_sha256 == $o) | .method == "password"' "$H/.local/secret-zero/infisical-admin-replaced.log"
  # The checksum still means what it did: the set names that file, and that file is still here to compare.
  set_sha="$(jq -r '.secret_zero.files["infisical-admin.json"].sha256' "$(ls -d "$H"/.local/backups/infisical/* | tail -1)/recovery/set.json")"
  check "the set still names the old file, and the archive still holds it" test -n "$(find "$H/.local/secret-zero" -path '*archive-token-*' -name infisical-admin.json -exec shasum -a 256 {} + | grep -F "$set_sha")"
  check "marker removed" test ! -e "$H/.local/restore-clean.state"
}

S21() {
  scenario "S21. Finding 1: infisical-admin.json is lost altogether, and the keys, password and dump are here"
  reset
  take_backups
  rm "$H/.local/secret-zero/infisical-admin.json"
  rm "$H/.local/secret-zero/infisical-machine.json"
  lose_cluster
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "no shell error" no_out "syntax error"
  check "minted after the database came back" order 'kc scale deployment/infisical --replicas=1 ns=infisical' 'api POST mint'
  check "the new file has the old shape, with its organization" jq -e '.organization.id == "org-old" and .identity.id == "adm" and .email == "admin@wayline.localhost"' "$H/.local/secret-zero/infisical-admin.json"
  check "the ledger has it, with no old file to name" jq -e 'select(.old_sha256 == "") | .method == "password"' "$H/.local/secret-zero/infisical-admin-replaced.log"
  check "and the machine file came back, from Terraform's own outputs" jq -e '.project_ids.dev == "p-dev" and .environment_slug == "prod"' "$H/.local/secret-zero/infisical-machine.json"
  check "marker removed" test ! -e "$H/.local/restore-clean.state"
}

S22() {
  scenario "S22. Finding 1: no token and no password: restore Infisical, stop with steps, resume with the replacement"
  reset
  take_backups
  local token
  expire_named_token
  rm "$H/.local/secret-zero/infisical-admin-password"
  lose_cluster
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest PLAN_ONLY=yes
  check "the plan goes through and warns, exit 0 (got $RC)" test "$RC" -eq 0
  check "the plan says it will stop for a sign-in" out_has "stops with sign-in steps"
  run scripts/restore.sh clean latest
  check "the run stops with exit 2 (got $RC)" test "$RC" -eq 2
  show_tail 2
  check "after restoring Infisical" log_has 'kc apply Job plane-restore ns=infisical'
  check "and no Plane restore began" no_log 'kc apply Job plane-restore ns=plane-'
  check "the steps name where a sign-in happens" out_has "sign in as admin@wayline.localhost"
  check "the steps name the file for the token" out_has ".local/secret-zero/infisical-admin-token.new"
  check "the steps name the file for a password" out_has ".local/secret-zero/infisical-admin-password"
  check "the steps name what to run next, with the backup id" out_has "make restore-clean BACKUP=$(ls "$H/.local/backups/infisical" | tail -1)"
  check "marker stays, with Infisical done" grep -qx 'done infisical' "$H/.local/restore-clean.state"
  check "evidence says BLOCKED" jq -e '.result == "BLOCKED"' "$(newest_evidence restore-clean)"

  : > "$H/state/calls.log"
  printf 'not-a-token' > "$H/.local/secret-zero/infisical-admin-token.new"
  run scripts/restore.sh clean latest
  check "something that is not a token: stops again, exit 2 (got $RC)" test "$RC" -eq 2
  check "and says so" out_has "infisical-admin-token.new does not hold a token this can read"
  : > "$H/state/calls.log"
  jwt $(($(date +%s) + 86400 * 90)) > "$H/.local/secret-zero/infisical-admin-token.new"
  run scripts/restore.sh clean latest
  check "a token the server does not know: stops again, exit 2 (got $RC)" test "$RC" -eq 2
  check "and says so" out_has "the server refused the token in infisical-admin-token.new"
  check "and it is not moved into place" test "$(jq -r .token "$H/.local/secret-zero/infisical-admin.json")" != "$(cat "$H/.local/secret-zero/infisical-admin-token.new")"
  check "and Infisical was not restored again" no_log 'kc apply Job plane-restore ns=infisical'

  : > "$H/state/calls.log"
  token="$(jwt $(($(date +%s) + 86400 * 90)))"
  jq --arg t "$token" '.tokens += [$t]' "$H/state/api.json" > "$H/state/t" && cp "$H/state/t" "$H/state/api.json"
  printf '%s\n' "$token" > "$H/.local/secret-zero/infisical-admin-token.new"
  run scripts/restore.sh clean latest
  check "with a real replacement, it resumes and finishes, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "Infisical was not restored again" no_log 'kc apply Job plane-restore ns=infisical'
  check "Plane was restored" log_has 'kc apply Job plane-restore ns=plane-prod-sim'
  check "the token file is the replacement" test "$(jq -r .token "$H/.local/secret-zero/infisical-admin.json")" = "$token"
  check "the file a person left is gone" test ! -e "$H/.local/secret-zero/infisical-admin-token.new"
  check "the ledger says a person did it" jq -e 'select(.method == "sign-in")' "$H/.local/secret-zero/infisical-admin-replaced.log"
  check "marker removed" test ! -e "$H/.local/restore-clean.state"

  reset
  take_backups
  rm "$H/.local/secret-zero/infisical-admin.json" "$H/.local/secret-zero/infisical-admin-password"
  lose_cluster
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "the file lost and no password: the same stop, exit 2 (got $RC)" test "$RC" -eq 2
  check "the file lost and no password: Infisical is back" log_has 'kc apply Job plane-restore ns=infisical'
  printf 'uipw' > "$H/.local/secret-zero/infisical-admin-password"
  chmod 600 "$H/.local/secret-zero/infisical-admin-password"
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "writing the password, as the steps say, lets it go on, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "it signed in by itself" log_has 'api POST mint'
}

S23() {
  scenario "S23. Finding 1: in place, what stops a restore comes before the server stops"
  reset
  take_backups
  expire_named_token
  rm "$H/.local/secret-zero/infisical-admin-password"
  : > "$H/state/calls.log"
  run scripts/restore.sh infisical latest CONFIRM=yes
  check "expired and no password: refuses" test "$RC" -ne 0
  check "before anything was stopped" no_log 'kc scale|kc patch application infisical pause'
  check "and before the database was touched" no_log 'kc apply Job plane-restore ns=infisical'
  check "says what to do while it can" out_has "Write the password of admin@wayline.localhost to .local/secret-zero/infisical-admin-password"
  check "and that a token made now would not help" out_has "this dump does not hold it"
  : > "$H/state/calls.log"
  run scripts/restore.sh infisical latest CONFIRM=yes ALLOW_NO_ADMIN_TOKEN=yes
  check "the override restores it, for an instance with nothing to sign in to" log_has 'kc apply Job plane-restore ns=infisical'
  check "the override then stops, with a blocked exit, not a pass (got $RC)" test "$RC" -eq 3
  check "the override: its evidence says BLOCKED" jq -e '.result == "BLOCKED"' "$(newest_evidence restore-infisical)"
  check "the override: with the steps" out_has "sign in as admin@wayline.localhost"

  reset
  take_backups
  expire_named_token
  : > "$H/state/calls.log"
  run scripts/restore.sh infisical latest CONFIRM=yes
  check "expired, password here: goes through and mints, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "expired, password here: order" order 'kc scale deployment/infisical --replicas=0' 'kc apply Job plane-restore ns=infisical' 'kc scale deployment/infisical --replicas=1' 'api POST mint' 'api GET secrets'
  check "expired, password here: proof-values PASS" jq -e 'any(.steps[]; .step == "proof-values" and .status == "PASS")' "$(newest_evidence restore-infisical)"

  # The reviewer's case: a token replaced after the dump. A real server refuses it, and now so does the fake.
  reset
  take_backups
  local token
  token="$(jwt $(($(date +%s) + 86400 * 80)))"
  jq --arg t "$token" '.tokens += [$t]' "$H/state/api.json" > "$H/state/t" && cp "$H/state/t" "$H/state/api.json"
  jq --arg t "$token" '.token = $t' "$H/.local/secret-zero/infisical-admin.json" > "$H/state/t" && cp "$H/state/t" "$H/.local/secret-zero/infisical-admin.json"
  : > "$H/state/calls.log"
  run scripts/restore.sh infisical latest CONFIRM=yes
  check "a token newer than the dump, the old file gone: mints, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "a token newer than the dump: the server was asked first" order 'kc scale deployment/infisical --replicas=1' 'api POST login' 'api POST mint'
  check "a token newer than the dump: proof-values PASS with the token the restored server takes" jq -e 'any(.steps[]; .step == "proof-values" and .status == "PASS")' "$(newest_evidence restore-infisical)"

  # Same, with the file this backup names still in an archive: that one is put back, and no login is needed.
  reset
  take_backups
  local want
  want="$(sum_zero)"
  mkdir "$H/.local/secret-zero/archive-token-20260101T000000Z"
  cp "$H/.local/secret-zero/infisical-admin.json" "$H/.local/secret-zero/archive-token-20260101T000000Z/"
  token="$(jwt $(($(date +%s) + 86400 * 80)))"
  jq --arg t "$token" '.tokens += [$t]' "$H/state/api.json" > "$H/state/t" && cp "$H/state/t" "$H/state/api.json"
  jq --arg t "$token" '.token = $t' "$H/.local/secret-zero/infisical-admin.json" > "$H/state/t" && cp "$H/state/t" "$H/.local/secret-zero/infisical-admin.json"
  : > "$H/state/calls.log"
  run scripts/restore.sh infisical latest CONFIRM=yes
  check "the named file in an archive: exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "the named file in an archive: no login" no_log 'api POST login'
  check "the named file in an archive: it is back in place" test "$want" = "$(sum_zero)"

  # A password changed since the dump: the dump holds the old hash, so the old password has to come back with it.
  reset
  take_backups
  want="$(sum_zero)"
  mkdir "$H/.local/secret-zero/archive-20260101T000000Z"
  mv "$H/.local/secret-zero/infisical-admin-password" "$H/.local/secret-zero/archive-20260101T000000Z/"
  printf 'changed-since' > "$H/.local/secret-zero/infisical-admin-password"
  jq '.password = "changed-since"' "$H/state/api.json" > "$H/state/t" && cp "$H/state/t" "$H/state/api.json"
  : > "$H/state/calls.log"
  run scripts/restore.sh infisical latest CONFIRM=yes
  check "a password newer than the dump: exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "a password newer than the dump: the one the dump goes with is back" test "$want" = "$(sum_zero)"
  check "a password newer than the dump: the newer one is kept" test -n "$(find "$H/.local/secret-zero" -path '*archive-pre-restore-*' -name infisical-admin-password)"
}

S24() {
  scenario "S24. Finding 1: a warning at backup and plan time when the token ends inside the retention period"
  reset
  set_token_exp $(($(date +%s) + 86400 * 10))
  ( cd "$H" && scripts/backup.sh infisical ) > "$H/state/o4.txt" 2>&1
  grep -F 'inside the 30 days a backup is expected to stay in use' "$H/state/o4.txt" >/dev/null
  check "10 days left: the backup warns" test "$?" -eq 0
  grep -F 'mints another, so keep that file' "$H/state/o4.txt" >/dev/null
  check "10 days left: and says the password is what is left" test "$?" -eq 0
  /bin/sleep 1
  ( cd "$H" && scripts/backup.sh dev && scripts/backup.sh prod-sim ) > /dev/null 2>&1
  run scripts/restore.sh clean latest PLAN_ONLY=yes
  check "10 days left: the plan warns" out_has "inside the 30 days a backup is expected to stay in use"
  /bin/sleep 1
  reset
  set_token_exp $(($(date +%s) + 86400 * 60))
  ( cd "$H" && scripts/backup.sh infisical ) > "$H/state/o4.txt" 2>&1
  grep -F 'inside the 30 days' "$H/state/o4.txt" >/dev/null
  check "60 days left: the backup does not" test "$?" -ne 0
  /bin/sleep 1
  reset
  set_token_exp $(($(date +%s) + 86400 * 10))
  rm "$H/.local/secret-zero/infisical-admin-password"
  ( cd "$H" && scripts/backup.sh infisical ) > "$H/state/o4.txt" 2>&1
  grep -F 'no password is on this machine' "$H/state/o4.txt" >/dev/null
  check "10 days left and no password: the warning says what that costs" test "$?" -eq 0
}

S25() {
  scenario "S25. Finding 1: a token that has ended does not stop backups, and the dump holds the one the set names"
  reset
  take_backups
  set_token_exp $(($(date +%s) - 86400))
  local before id
  before="$(shasum -a 256 "$H/.local/secret-zero/infisical-admin.json" | cut -d' ' -f1)"
  : > "$H/state/calls.log"
  run scripts/backup.sh infisical
  check "the backup succeeds, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "minted before the dump, so the dump holds it" order 'api POST mint' 'kc apply Job plane-backup ns=infisical'
  id="$(ls "$H/.local/backups/infisical" | tail -1)"
  check "the set is complete" jq -e '.complete == true' "$H/.local/backups/infisical/$id/recovery/set.json"
  check "the set names the new file" test "$(jq -r '.secret_zero.files["infisical-admin.json"].sha256' "$H/.local/backups/infisical/$id/recovery/set.json")" = "$(shasum -a 256 "$H/.local/secret-zero/infisical-admin.json" | cut -d' ' -f1)"
  check "the new file is not the old one" test "$before" != "$(shasum -a 256 "$H/.local/secret-zero/infisical-admin.json" | cut -d' ' -f1)"
  /bin/sleep 1
  ( cd "$H" && scripts/backup.sh dev && scripts/backup.sh prod-sim ) > /dev/null 2>&1
  lose_cluster
  : > "$H/state/calls.log"
  run scripts/restore.sh clean "$id"
  check "and a clean restore of it needs no login, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "no login" no_log 'api POST login'
  reset
  set_token_exp $(($(date +%s) - 86400))
  rm "$H/.local/secret-zero/infisical-admin-password"
  run scripts/backup.sh infisical
  check "no password either: the dump is kept and the set is not whole, exit non-zero" test "$RC" -ne 0
  check "no password either: says what to do" out_has "sign in as admin@wayline.localhost"
  check "no password either: says nothing was pruned" out_has "Retention did not run"
  reset
  run env RENEW_ADMIN_TOKEN=yes scripts/infisical-bootstrap.sh
  check "RENEW_ADMIN_TOKEN=yes replaces a token that still works (got $RC)" log_has 'api POST mint'
  run env scripts/infisical-bootstrap.sh
  check "and the next bootstrap accepts it (got $RC)" test "$RC" -eq 0
}

S26() {
  scenario "S26. Finding 1: writing a token over the file does not pass as the file the checksum names"
  reset
  take_backups
  local named token
  named="$(shasum -a 256 "$H/.local/secret-zero/infisical-admin.json" | cut -d' ' -f1)"
  # Made by hand after the dump, on the instance that is now gone, so the dump does not hold it.
  token="$(jwt $(($(date +%s) + 86400 * 80)))"
  jq --arg t "$token" '.token = $t' "$H/.local/secret-zero/infisical-admin.json" > "$H/state/t" && cp "$H/state/t" "$H/.local/secret-zero/infisical-admin.json"
  lose_cluster
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest PLAN_ONLY=yes
  check "the plan does not call it the file this backup names" out_has "the infisical-admin.json this backup names is not on this machine"
  run scripts/restore.sh clean latest
  check "the restored server refuses it, and a password login takes over, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "the server was asked" order 'kc scale deployment/infisical --replicas=1' 'api POST login' 'api POST mint'
  check "the ledger says why" jq -e 'select(.why | test("restored server answers HTTP 401"))' "$H/.local/secret-zero/infisical-admin-replaced.log"

  # Made by hand before the dump, so the dump does hold it, and the server accepts it with no login at all.
  reset
  token="$(jwt $(($(date +%s) + 86400 * 80)))"
  jq --arg t "$token" '.tokens += [$t]' "$H/state/api.json" > "$H/state/t" && cp "$H/state/t" "$H/state/api.json"
  take_backups
  named="$(shasum -a 256 "$H/.local/secret-zero/infisical-admin.json" | cut -d' ' -f1)"
  jq --arg t "$token" '.token = $t' "$H/.local/secret-zero/infisical-admin.json" > "$H/state/t" && cp "$H/state/t" "$H/.local/secret-zero/infisical-admin.json"
  rm "$H/.local/secret-zero/infisical-admin-password"
  lose_cluster
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "a token the restored server accepts goes through, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "with no login" no_log 'api POST login'
  check "and is on record, from the file this backup names to this one" jq -e --arg o "$named" 'select(.old_sha256 == $o) | .method == "accepted-in-place"' "$H/.local/secret-zero/infisical-admin-replaced.log"
}

S27() {
  scenario "S27. Finding 3: uncommitted changes refuse before anything is deleted, as up.sh would"
  reset
  take_backups
  dirty_tree
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest PLAN_ONLY=yes
  check "PLAN_ONLY refuses" test "$RC" -ne 0
  check "and names the path" out_has "monitoring/README.md"
  check "and says why" out_has "scripts/up.sh refuses to run with them"
  lose_cluster
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "a real run refuses" test "$RC" -ne 0
  check "before the marker" test ! -e "$H/.local/restore-clean.state"
  check "before anything ran" no_log 'kind create|kc apply|kc scale'
  reset
  dirty_tree
  : > "$H/state/calls.log"
  run env CONFIRM=yes SKIP_E2E=yes tests/drills/clean-restore.sh
  check "the drill refuses" test "$RC" -ne 0
  check "the drill deletes nothing" no_log 'kind delete cluster'
  check "the drill backs up nothing first" no_log 'kc apply Job plane-backup'
  check "the drill names the path" out_has "monitoring/README.md"
  reset
  lose_cluster
  dirty_tree
  run scripts/up.sh
  check "up.sh itself refuses it, the same way" out_has "uncommitted changes above"
}

S28() {
  scenario "S28. Finding 4: the disk check before a delete, and agreement with up.sh"
  reset
  set_disk 14
  printf '12.22GB' > "$H/state/kind-volume-size"
  : > "$H/state/calls.log"
  run env CONFIRM=yes SKIP_E2E=yes tests/drills/clean-restore.sh
  check "14 GiB + 93% of 11.4: under 25, the drill refuses" test "$RC" -ne 0
  check "before the delete" no_log 'kind delete cluster'
  check "and shows the arithmetic" out_has "about 24.6 GiB would be free after the delete: 14.0 GiB now plus 93% of the 11.4 GiB kind volume"
  check "and how to go on" out_has 'ALLOW_LOW_DISK="<reason>"'

  reset
  set_disk 14
  : > "$H/state/calls.log"
  run env CONFIRM=yes SKIP_E2E=yes ALLOW_LOW_DISK=yes tests/drills/clean-restore.sh
  check "ALLOW_LOW_DISK=yes is refused: it says nothing" test "$RC" -ne 0
  check "before the delete" no_log 'kind delete cluster'
  check "and it says what it wants" out_has "ALLOW_LOW_DISK takes a reason in words"

  reset
  set_disk 14
  : > "$H/state/calls.log"
  run env CONFIRM=yes SKIP_E2E=yes "ALLOW_LOW_DISK=short by half a GiB, and watching" tests/drills/clean-restore.sh
  check "a reason goes past it, exit 0 (got $RC)" test "$RC" -eq 0
  if [[ "$RC" -ne 0 ]]; then grep -E 'FAIL|fail' "$OUT" | head | sed 's/^/    | /'; fi
  check "deleted and restored" log_has 'kind create cluster'
  check "the drill logged it" grep -E 'clean-restore-drill.*short by half a GiB' "$H/.local/evidence-raw/low-disk-overrides.log"
  check "up.sh logged it" grep -E 'up\.sh.*short by half a GiB' "$H/.local/evidence-raw/low-disk-overrides.log"
  check "cluster-up.sh did not need to: 24 GiB clears its 15" test "$(grep -c 'cluster-up.sh' "$H/.local/evidence-raw/low-disk-overrides.log")" -eq 0

  reset
  set_disk 15
  : > "$H/state/calls.log"
  run env CONFIRM=yes SKIP_E2E=yes tests/drills/clean-restore.sh
  check "15 GiB + 93% of 11.4: 25.6 clears 25, and the run goes through, exit 0 (got $RC)" test "$RC" -eq 0
  check "with no override" test ! -e "$H/.local/evidence-raw/low-disk-overrides.log"

  reset
  set_disk 15
  printf '60' > "$H/state/reclaim-percent"
  : > "$H/state/calls.log"
  run env CONFIRM=yes SKIP_E2E=yes tests/drills/clean-restore.sh
  check "passes the check, and only 60% comes back: it does not stop at up.sh, exit 0 (got $RC)" test "$RC" -eq 0
  if [[ "$RC" -ne 0 ]]; then grep -E 'FAIL|fail' "$OUT" | head | sed 's/^/    | /'; fi
  check "the run says what happened" out_has "the drill's check counted on about"
  check "and up.sh logs it, with that reason" grep -E 'up\.sh.*counted on about' "$H/.local/evidence-raw/low-disk-overrides.log"

  reset
  lose_cluster
  set_disk 12
  : > "$H/state/calls.log"
  run scripts/up.sh
  check "up.sh with no cluster and 12 GiB: refuses" test "$RC" -ne 0
  check "up.sh says how to go on" out_has 'ALLOW_LOW_DISK="<reason>"'
  check "up.sh created nothing" no_log 'kind create'
  run env "ALLOW_LOW_DISK=no room, and this is only a test" UP_STOP_AFTER=cluster scripts/up.sh
  check "up.sh with a reason goes on (got $RC)" test "$RC" -eq 0
  check "up.sh logs it" grep -E 'up\.sh.*no room, and this is only a test' "$H/.local/evidence-raw/low-disk-overrides.log"
  check "and cluster-up.sh, past its own 15" grep -E 'cluster-up\.sh.*no room, and this is only a test' "$H/.local/evidence-raw/low-disk-overrides.log"
  reset
  lose_cluster
  set_disk 12
  run scripts/cluster-up.sh
  check "cluster-up.sh alone with no cluster and 12 GiB: refuses" test "$RC" -ne 0
  check "cluster-up.sh alone: says how to go on" out_has 'ALLOW_LOW_DISK="<reason>"'
  reset
  set_disk 11
  run scripts/up.sh
  check "up.sh on a cluster that exists asks only for the floor, exit 0 (got $RC)" test "$RC" -eq 0

  reset
  take_backups
  # An empty cluster that stays creates nothing, and it still has all of it to pull, and the restores after that
  # check the floor. So it needs that much plus the floor (finding 9 of the second review).
  empty_cluster
  set_disk 12
  run scripts/restore.sh clean latest PLAN_ONLY=yes
  check "an empty cluster that stays, 12 GiB: refused, it still has 12.94 GiB to pull (got $RC)" test "$RC" -ne 0
  check "and the plan says so" out_has "this empty cluster still has 12.94 GiB to pull"
  set_disk 22
  run scripts/restore.sh clean latest PLAN_ONLY=yes
  check "22 GiB: refused, 12.94 plus the 10 GiB floor is 22.94 (got $RC)" test "$RC" -ne 0
  set_disk 23
  run scripts/restore.sh clean latest PLAN_ONLY=yes
  check "23 GiB: goes through (got $RC)" test "$RC" -eq 0
  check "and the disk line is about this cluster, and not a delete" no_out "after a delete"
  show_tail

  reset
  take_backups
  lose_cluster
  set_disk 20
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "restore-clean with no cluster and 20 GiB: refuses" test "$RC" -ne 0
  check "before the marker" test ! -e "$H/.local/restore-clean.state"
  check "before anything ran" no_log 'kind create'
  run env "ALLOW_LOW_DISK=restoring here regardless, on purpose" scripts/restore.sh clean latest
  check "with a reason it goes through, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
}

S29() {
  scenario "S29. Finding 5: digests the registry cannot serve are listed before anything is touched"
  reset
  take_backups
  local one
  one="$(grep -hoE 'localhost:5001/[^[:space:]"@]+@sha256:[a-f0-9]{64}' "$H/gitops/environments/dev/manifests.yaml" | sort -u | head -1)"
  if [[ -z "$one" ]]; then
    fail "fixture: Git names no localhost:5001 digest, so this scenario proves nothing"
    return
  fi
  printf '%s\n' "$one" > "$H/state/registry-missing"
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest PLAN_ONLY=yes
  check "PLAN_ONLY refuses" test "$RC" -ne 0
  check "and lists the digest" out_has "$one"
  check "and gives the way from GHCR" out_has "scripts/ci/copy-to-local-registry.sh ghcr.io/"
  check "and the way by rebuilding" out_has "make images"
  check "and by promoting" out_has "make promote ENV=dev"
  check "and says the data is left alone" out_has "neither touches the data"
  check "and how to get a registry to copy into" out_has "make up UP_STOP_AFTER=cluster"
  check "and rebuilds nothing to find out" no_log 'rebuild images'
  lose_cluster
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "a real run refuses" test "$RC" -ne 0
  check "before anything ran" no_log 'kind create|rebuild images'
  check "before the marker" test ! -e "$H/.local/restore-clean.state"
  reset
  printf '%s\n' "$one" > "$H/state/registry-missing"
  : > "$H/state/calls.log"
  run env CONFIRM=yes SKIP_E2E=yes tests/drills/clean-restore.sh
  check "the drill refuses" test "$RC" -ne 0
  check "the drill deletes nothing" no_log 'kind delete cluster'
  reset
  take_backups
  touch "$H/state/registry-down"
  lose_cluster
  run scripts/restore.sh clean latest PLAN_ONLY=yes
  check "no cluster, the registry merely stopped, its volume there: no refusal, nothing is lost by finding out later (got $RC)" test "$RC" -eq 0
  check "and it says up.sh will check" out_has "scripts/up.sh starts it and checks the digests then"
  reset
  take_backups
  touch "$H/state/registry-down"
  touch "$H/state/registry-volume-gone"
  run scripts/restore.sh clean latest PLAN_ONLY=yes
  check "the registry and its volume gone, as after PURGE=yes: refuses" test "$RC" -ne 0
  check "and lists what it cannot serve" out_has "$one"
}

S30() {
  scenario "S30. Finding 6: a cluster lost with no make destroy leaves state about it, which must not be applied over"
  reset
  take_backups
  lose_cluster
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "Terraform did not apply over it" no_log 'tf local apply over stale state'
  check "the old state is kept, moved aside" test -n "$(find "$H/.local/terraform" -maxdepth 2 -path '*local.stale-*' -name terraform.tfstate)"
  check "the aside folder is private" test "$(stat -f %Lp "$(find "$H/.local/terraform" -maxdepth 1 -name 'local.stale-*')")" = 700
  check "the run says so" out_has "described one that is gone"
  check "the evidence says so" jq -e 'any(.steps[]; .step == "terraform-local-state")' "$(newest_evidence restore-clean)"
  check "and the new state is this cluster's" jq -e '.generation == 2' "$H/.local/terraform/local/terraform.tfstate"
  reset
  lose_cluster
  : > "$H/state/calls.log"
  run env UP_STOP_AFTER=terraform scripts/up.sh
  check "plain make up on a lost cluster too" no_log 'tf local apply over stale state'
  reset
  run env UP_STOP_AFTER=terraform scripts/up.sh
  check "make up with the cluster there keeps its state (got $RC)" test -z "$(find "$H/.local/terraform" -maxdepth 1 -name 'local.stale-*')"
  reset
  touch "$H/state/docker-down"
  take_backups
  run scripts/restore.sh clean latest
  check "Docker down: refuses, and does not take that for a lost cluster" out_has "Docker is not running"
  check "Docker down: state untouched" test -f "$H/.local/terraform/local/terraform.tfstate"
}

S31() {
  scenario "S31. Finding 7: a hard stop ran no trap. Infisical left at zero with auto-sync paused"
  reset
  take_backups
  lose_cluster
  : > "$H/state/calls.log"
  printf '[["plane-restore-2","infisical"]]' > "$H/state/fail-jobs.json"
  run scripts/restore.sh clean latest
  rm -f "$H/state/fail-jobs.json"
  # Exactly what SIGKILL between the scale and the end of the Job leaves: on_exit never ran.
  leave_paused infisical
  leave_scaled 0 infisical/infisical
  check "fixture: nothing answers" test "$(/usr/bin/curl -s -o /dev/null -w '%{http_code}' "$INFISICAL_URL/api/status")" = 503
  check "fixture: the Application reads what a wait cannot get past" test "$(cd "$H" && .tools/bin/kubectl -n argocd get application infisical -o jsonpath='{.status.sync.status}/{.status.health.status}')" = OutOfSync/Progressing
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "the resume finishes, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "auto-sync came back and the server was scaled up, before anything waited" order 'kc patch application infisical resume' 'kc scale deployment/infisical --replicas=1 ns=infisical' 'tf local apply|publish'
  check "then the restore went ahead" order 'kc scale deployment/infisical --replicas=1 ns=infisical' 'kc apply Job plane-restore ns=infisical'
  check "the run says what it repaired" jq -e 'any(.steps[]; .step == "repair-auto-sync-infisical")' "$(newest_evidence restore-clean)"
  check "marker removed" test ! -e "$H/.local/restore-clean.state"

  scenario "S31b. Finding 7: root and a Plane app left paused, with that app at zero"
  reset
  take_backups
  lose_cluster
  : > "$H/state/calls.log"
  printf '[["plane-restore-2","plane-dev"]]' > "$H/state/fail-jobs.json"
  run scripts/restore.sh clean latest
  rm -f "$H/state/fail-jobs.json"
  leave_paused root plane-dev
  leave_scaled 0 plane-dev/plane-api-wl plane-dev/plane-worker-wl plane-dev/plane-beat-worker-wl plane-dev/plane-live-wl
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "the resume finishes, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "root last, as argo_resume does" order 'kc patch application plane-dev resume' 'kc patch application root resume'
  check "the apps came back to Git's replicas first" order 'kc scale deployment/plane-api-wl --replicas=1 ns=plane-dev' 'kc apply Job plane-restore ns=plane-dev'
  check "none left paused at the end" test "$(cd "$H" && .tools/bin/kubectl -n argocd get applications -o json | jq '[.items[] | select(.spec.syncPolicy.automated.enabled == false)] | length')" = 0

  scenario "S31c. Finding 7: the real thing. Kill the whole process group with SIGKILL, in the Infisical restore Job"
  reset
  take_backups
  lose_cluster
  : > "$H/state/calls.log"
  printf '[["plane-restore-2","infisical"]]' > "$H/state/hang-jobs.json"
  ( cd "$H" && exec python3 -I -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' scripts/restore.sh clean latest ) > "$H/state/o5.txt" 2>&1 &
  local pid=$! waited=0 pgid
  until log_has 'kc apply Job plane-restore ns=infisical' || [[ "$waited" -gt 600 ]]; do
    /bin/sleep 0.2
    waited=$((waited + 1))
  done
  /bin/sleep 1
  pgid="$pid"
  kill -9 -- "-$pgid" 2>/dev/null
  wait "$pid" 2>/dev/null
  rm -f "$H/state/hang-jobs.json"
  check "fixture: the Job is still there, active, with its client gone" test "$(jq -r '[.[] | select(.state == "Running")] | length' "$H/state/jobs.json")" = 1
  check "fixture: the server is at zero, and paused" test "$(cd "$H" && .tools/bin/kubectl -n argocd get application infisical -o jsonpath='{.status.sync.status}/{.status.health.status}')" = OutOfSync/Progressing
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "the resume finishes, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "the Job with no client was removed first" order 'kc delete job plane-restore ns=infisical' 'kc patch application infisical resume'
  check "no restore ran with the server up" no_log '^ERROR'
  check "marker removed" test ! -e "$H/.local/restore-clean.state"

  scenario "S31d. A run that is alive is not a hard stop"
  reset
  take_backups
  lose_cluster
  : > "$H/state/calls.log"
  printf '[["plane-restore-2","infisical"]]' > "$H/state/hang-jobs.json"
  ( cd "$H" && exec python3 -I -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' scripts/restore.sh clean latest ) > "$H/state/o5.txt" 2>&1 &
  pid=$!
  waited=0
  until log_has 'kc apply Job plane-restore ns=infisical' || [[ "$waited" -gt 600 ]]; do
    /bin/sleep 0.2
    waited=$((waited + 1))
  done
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "a second run refuses" test "$RC" -ne 0
  check "and says another is running" out_has "is running here"
  check "and repairs nothing under it" no_log 'kc patch application infisical resume|kc delete job'
  kill -9 -- "-$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  rm -f "$H/state/hang-jobs.json"

  scenario "S31e. Finding 7: a power cut. The same state, and the node stopped too"
  reset
  take_backups
  lose_cluster
  : > "$H/state/calls.log"
  printf '[["plane-restore-2","infisical"]]' > "$H/state/fail-jobs.json"
  run scripts/restore.sh clean latest
  rm -f "$H/state/fail-jobs.json"
  leave_paused infisical
  leave_scaled 0 infisical/infisical
  S="$H/state" python3 -I -c '
import json, os
s = os.environ["S"]; c = json.load(open(f"{s}/cluster.json")); c["stopped"] = True
json.dump(c, open(f"{s}/cluster.json", "w"))'
  check "fixture: nothing answers, not even the cluster" test "$(cd "$H" && .tools/bin/kubectl get --raw /readyz >/dev/null 2>&1; echo "$?")" = 1
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "the resume finishes, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "the node first, then what it left behind" order 'docker start' 'kc patch application infisical resume' 'kc scale deployment/infisical --replicas=1 ns=infisical' 'kc apply Job plane-restore ns=infisical'
  check "marker removed" test ! -e "$H/.local/restore-clean.state"
}

S32() {
  scenario "S32. Finding 8: retention, on real folders. Five failed Infisical backups keep the last complete one"
  reset
  take_backups
  local good id bad_count
  good="$(ls "$H/.local/backups/infisical" | tail -1)"
  /bin/sleep 1
  stop_api
  for _ in 1 2 3 4 5 6; do
    ( cd "$H" && scripts/backup.sh infisical KEEP=5 ) > "$H/state/o6.txt" 2>&1
    /bin/sleep 1
  done
  start_api
  check "the last complete one is still there, after 6 that could not finish" test -d "$H/.local/backups/infisical/$good"
  check "and the failures are kept too: nothing pruned" test "$(ls "$H/.local/backups/infisical" | wc -l | tr -d ' ')" -eq 7
  run scripts/restore.sh clean latest PLAN_ONLY=yes
  check "and a clean restore still has it" out_has "Infisical  $good"

  reset
  take_backups
  good="$(ls "$H/.local/backups/infisical" | tail -1)"
  /bin/sleep 1
  stop_api
  ( cd "$H" && scripts/backup.sh infisical ) > "$H/state/o6.txt" 2>&1
  /bin/sleep 1
  start_api
  run scripts/backup.sh infisical KEEP=1
  check "a complete backup with KEEP=1 succeeds, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  id="$(ls "$H/.local/backups/infisical" | tail -1)"
  check "the newest complete set stays" test -d "$H/.local/backups/infisical/$id"
  check "the older complete one goes" test ! -e "$H/.local/backups/infisical/$good"
  check "and the failure older than it" test "$(ls "$H/.local/backups/infisical" | wc -l | tr -d ' ')" -eq 1

  # A backup that could not finish its set removes nothing, even where KEEP would have it.
  reset
  take_backups
  /bin/sleep 1
  take_backups
  /bin/sleep 1
  stop_api
  ( cd "$H" && KEEP=1 scripts/backup.sh infisical ) > "$H/state/o6.txt" 2>&1
  /bin/sleep 1
  start_api
  check "a backup with no complete set, KEEP=1: both complete ones stay" test "$(ls "$H/.local/backups/infisical" | wc -l | tr -d ' ')" -eq 3

  reset
  take_backups
  /bin/sleep 1
  take_backups
  /bin/sleep 1
  stop_api
  ( cd "$H" && scripts/backup.sh infisical ) > "$H/state/o6.txt" 2>&1
  /bin/sleep 1
  bad_count="$(ls "$H/.local/backups/infisical" | tail -1)"
  start_api
  run scripts/backup.sh infisical KEEP=2
  check "KEEP=2 counts complete sets only, exit 0 (got $RC)" test "$RC" -eq 0
  check "KEEP=2: two complete, and the failure between them is kept for an in-place restore" test "$(ls "$H/.local/backups/infisical" | wc -l | tr -d ' ')" -eq 3
  check "KEEP=2: the failure is the one kept" test -d "$H/.local/backups/infisical/$bad_count"

  reset
  ( cd "$H" && scripts/backup.sh dev ) > /dev/null 2>&1
  /bin/sleep 1
  ( cd "$H" && scripts/backup.sh dev ) > /dev/null 2>&1
  /bin/sleep 1
  run scripts/backup.sh dev KEEP=1
  check "the Plane Job's own retention lines still run, on real folders (got $RC)" test "$(ls "$H/.local/backups/dev" | wc -l | tr -d ' ')" -eq 1
}

S33() {
  scenario "S33. Finding 9: a proof that could not run is not a pass"
  reset
  take_backups
  lose_cluster
  printf '2' > "$H/state/smoke-rc-verify"
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "exit 2, as scripts/test.sh does (got $RC)" test "$RC" -eq 2
  check "the marker stays" test -f "$H/.local/restore-clean.state"
  check "it does not say complete" no_clean_complete
  check "the evidence says NOT RUN" jq -e '.result == "NOT RUN"' "$(newest_evidence restore-clean)"
  check "and names the steps" jq -e '.not_run == ["verify-sentinel-dev", "verify-sentinel-prod-sim"]' "$(newest_evidence restore-clean)"
  rm -f "$H/state/smoke-rc-verify"
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "run again with the proof working: exit 0 (got $RC)" test "$RC" -eq 0
  check "without restoring anything again" no_log 'kc apply Job plane-restore ns=plane-dev'
  check "marker removed" test ! -e "$H/.local/restore-clean.state"

  reset
  rm "$H"/.local/test-sentinel-*.json
  take_backups
  lose_cluster
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest PLAN_ONLY=yes
  check "a backup with no sentinel: the plan says what that means" out_has "records no sentinel, so its proof cannot run and this exits 2"
  run scripts/restore.sh clean latest
  check "a backup with no sentinel: exit 2 (got $RC)" test "$RC" -eq 2
  check "a backup with no sentinel: the option is named" out_has "ALLOW_NO_SENTINEL=yes"
  run env ALLOW_NO_SENTINEL=yes scripts/restore.sh clean latest
  check "the explicit option accepts it, exit 0 (got $RC)" test "$RC" -eq 0
  show_tail
  check "the option: marker removed" test ! -e "$H/.local/restore-clean.state"
  check "the option: the step still reads NOT RUN" jq -e '.result == "PASS" and (.not_run | index("verify-sentinel-dev") != null)' "$(newest_evidence restore-clean)"

  reset
  rm "$H"/.local/test-sentinel-*.json
  take_backups
  run scripts/restore.sh dev latest CONFIRM=yes
  check "one environment, the proof could not run: exit 2 (got $RC)" test "$RC" -eq 2
  check "one environment: the evidence says NOT RUN" jq -e '.result == "NOT RUN"' "$(newest_evidence restore-dev)"
  check "one environment: the data is back, and it says so" out_has "is back in dev"
}

S34() {
  scenario "S34. Finding 10: a plan shows what a backup holds, and warns when it looks like the wrong one"
  reset
  take_backups
  local old
  old="$(ls "$H/.local/backups/dev" | tail -1)"
  /bin/sleep 1
  # The trap: make up over the real data's Infisical keys, then make destroy backs up the empty result.
  printf '{"users":0,"workspaces":0,"projects":0,"issues":0,"file_assets":0}' > "$H/state/plane-counts.json"
  take_backups
  run scripts/restore.sh clean latest PLAN_ONLY=yes
  check "0 users: warned" out_has "holds 0 users, so it looks like a backup of an empty platform"
  check "0 users: names the backup that has them" out_has "dev/$old holds 23 users"
  check "0 users: names the way to it" out_has "BACKUP_DEV=$old"
  check "a sentinel with 0 workspaces in the dump: warned" out_has "records sentinel workspace s, and its dump counts 0 workspaces"
  rm "$H/state/plane-counts.json"
  # Finding 20 of the second review: on a live cluster, the plan's advice is the refusal's.
  check "a plan on a live cluster says what a real run would" out_has "a real run would refuse right now"
  check "and the advice skips a backup, which would take over BACKUP=latest" out_has "make destroy CONFIRM=yes SKIP_BACKUP=yes, then make restore-clean BACKUP=$(ls "$H/.local/backups/infisical" | tail -1)"
  check "and says why" out_has "Without SKIP_BACKUP=yes, make destroy backs up what is there now"
  check "and not the advice that makes BACKUP=latest name the empty set" no_out "Run make destroy first"
}

S35() {
  scenario "S35. Finding 11: an Infisical backup from a newer server than Git deploys or the cluster runs"
  reset
  printf 'docker.io/infisical/infisical:v0.999.0@sha256:ff' > "$H/state/server-image"
  take_backups
  rm "$H/state/server-image"
  local before
  before="$(jq -r .server_image "$(ls -d "$H"/.local/backups/infisical/* | tail -1)/manifest.json")"
  check "fixture: the backup is from the newer server" test "$before" = 'docker.io/infisical/infisical:v0.999.0@sha256:ff'
  : > "$H/state/calls.log"
  run scripts/restore.sh infisical latest CONFIRM=yes
  check "in place: refuses" test "$RC" -ne 0
  check "in place: says why" out_has "this backup is from Infisical v0.999.0"
  check "in place: before anything stopped" no_log 'kc scale|kc patch application infisical'
  check "in place: and says nothing was changed" out_has "refused, as said above. Nothing was changed"
  : > "$H/state/calls.log"
  run scripts/restore.sh infisical latest CONFIRM=yes ALLOW_NEWER_INFISICAL_BACKUP=yes
  check "in place: the override goes on" log_has 'kc apply Job plane-restore ns=infisical'
  reset
  printf 'docker.io/infisical/infisical:v0.999.0@sha256:ff' > "$H/state/server-image"
  take_backups
  rm "$H/state/server-image"
  run scripts/restore.sh clean latest PLAN_ONLY=yes
  check "clean: the plan refuses, from Git" test "$RC" -ne 0
  check "clean: says why" out_has "is from v0.999.0, and Git deploys v0.167"
  lose_cluster
  : > "$H/state/calls.log"
  run scripts/restore.sh clean latest
  check "clean: a real run refuses" test "$RC" -ne 0
  check "clean: before anything ran" no_log 'kind create'
  run scripts/restore.sh clean latest PLAN_ONLY=yes ALLOW_NEWER_INFISICAL_BACKUP=yes
  check "clean: the override passes the plan (got $RC)" test "$RC" -eq 0
  reset
  printf 'docker.io/infisical/infisical:v0.100.0@sha256:ee' > "$H/state/server-image"
  take_backups
  rm "$H/state/server-image"
  run scripts/restore.sh clean latest PLAN_ONLY=yes
  check "a backup from an older server is fine: migrations go forward (got $RC)" test "$RC" -eq 0
}

S36() {
  scenario "S36. Small ones: the backup folder's mode at creation (finding 14), the lock table (finding 15)"
  reset
  lose_cluster
  rm -rf "$H/.local/backups"
  ( umask 022; cd "$H" && scripts/cluster-up.sh ) > "$H/state/o7.txt" 2>&1
  check "cluster-up.sh makes .local/backups at 0700" test "$(stat -f %Lp "$H/.local/backups")" = 700
  check "the manifest asks for the larger lock table" grep -F 'max_locks_per_transaction=128' "$H/infisical/manifests/postgres.yaml"
}

# shellcheck source=clean-restore-harness/scenarios-second-review.sh
source "$STUBS/scenarios-second-review.sh"

SCENARIOS="S0 S1 S2 S3 S4 S5 S6 S7 S8 S9 S10 S11 S12 S13 S14 S15 S16 S17 S18 S19 S20 S21 S22 S23 S24 S25 S26 S27 S28 S29 S30 S31 S32 S33 S34 S35 S36 R1 R2 R3 R4 R5 R6 R7 R8 R8d R9 R10 R11 R12 R13 R14 R15 R16 R17 R18 R19 R21 R22"

for s in $SCENARIOS; do
  case " ${ONLY:-$SCENARIOS} " in
    *" $s "*) "$s" ;;
  esac
done

printf '\nRESULT %s passed, %s failed\n' "$PASSES" "$FAILS"
[[ "$FAILS" -eq 0 ]]
