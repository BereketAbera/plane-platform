#!/bin/sh
# Runs in the isolated namespace's Job, with SOURCE set to plane-prod, infisical or frameflow. POSIX sh on Alpine's busybox. Prints PROOF
# lines, which name tables, counts and hashes and no value, and scripts/hosted/restore-test.sh reads them. Exit 0 proved, 1 not.
#
# Postgres listens on a socket in this pod and nowhere else: no TCP at all, so this cannot reach anything and nothing can reach it.
set -eu
umask 077

fail() {
  printf 'PROOF-FAIL %s\n' "$*"
  exit 1
}

# Under whatever path restic saved it from, or the stream wrote it to.
SUMS="$(find /scratch/restored -type f -name SHA256SUMS | head -1)"
[ -n "$SUMS" ] || fail "the restored files hold no SHA256SUMS"
BACKUP="$(dirname "$SUMS")"
cd "$BACKUP"

field() { # a string field of manifest.json. No jq here, and the backup wrote each on a line of its own.
  sed -n "s/^ *\"$1\": \"\(.*\)\",\{0,1\}\$/\1/p" manifest.json | head -1
}

[ -s manifest.json ] || fail "the restored files hold no manifest.json"
printf 'PROOF manifest id=%s created_at=%s\n' "$(field id)" "$(field created_at)"
# Each manifest holds one of these, and the other two print empty.
printf 'PROOF fingerprint %s %s %s\n' "$(field secret_key_fp)" "$(field encryption_key_fp)" "$(field hatchet_master_keyset_fp)"

# Every file, the objects among them, against the hashes written before this was sealed.
sha256sum -c SHA256SUMS >/tmp/sums.out 2>&1 || {
  grep -v ': OK$' /tmp/sums.out | head -20
  fail "a restored file does not match its hash"
}
FILES="$(wc -l <SHA256SUMS | tr -d ' ')"
printf 'PROOF hashes %s files match\n' "$FILES"

export PGDATA=/scratch/pg PGHOST=/scratch/sock PGUSER=postgres
mkdir -p "$PGHOST"
initdb -D "$PGDATA" -U postgres --auth=trust --no-sync >/dev/null
# 785 partitions and more on Infisical, so its restore needs the locks its own server was given and more.
# No parallel workers, because their shared memory sits in the container's small /dev/shm.
pg_ctl -D "$PGDATA" -w -l /scratch/postgres.log -o "-c listen_addresses='' -c unix_socket_directories=$PGHOST -c fsync=off -c shared_buffers=128MB -c max_connections=20 -c max_locks_per_transaction=256 -c max_parallel_workers_per_gather=0 -c max_parallel_maintenance_workers=0" start >/dev/null ||
  {
    tail -5 /scratch/postgres.log
    fail "the scratch Postgres did not start"
  }

createdb restored
TAB="$(printf '\t')"
case "$SOURCE" in
  plane-prod)
    pg_restore --no-owner --no-privileges --exit-on-error --single-transaction -d restored postgres/plane.dump
    ;;
  infisical)
    # Never --single-transaction: thousands of partition indexes need more locks in one transaction than any server here has.
    pg_restore --no-owner --no-privileges --exit-on-error -d restored postgres/infisical.dump
    ;;
  frameflow)
    # Hatchet's, whose tables are partitioned by day, so the same as Infisical's.
    pg_restore --no-owner --no-privileges --exit-on-error -d restored postgres/hatchet.dump
    ;;
  *) fail "SOURCE is '$SOURCE'" ;;
esac
printf 'PROOF restored the dump into an empty database\n'

# The queries ship with the dump, so this is the check the backup made on its own scratch restore.
psql -XAt -F "$TAB" -v ON_ERROR_STOP=1 -d restored -f postgres/rowcounts.sql >/tmp/rowcounts.tsv
if ! cmp -s /tmp/rowcounts.tsv postgres/rowcounts.tsv; then
  diff postgres/rowcounts.tsv /tmp/rowcounts.tsv | head -20 || true
  fail "row counts differ from those recorded with the backup"
fi
TABLES="$(wc -l </tmp/rowcounts.tsv | tr -d ' ')"
ROWS="$(awk -F "$TAB" '{ total += $2 } END { print total + 0 }' /tmp/rowcounts.tsv)"
printf 'PROOF rowcounts %s tables, %s rows, as recorded\n' "$TABLES" "$ROWS"

if [ "$SOURCE" = plane-prod ]; then
  psql -XAt -F "$TAB" -v ON_ERROR_STOP=1 -d restored -f postgres/content.sql >/tmp/content.tsv
  cmp -s /tmp/content.tsv postgres/content.tsv || fail "the content hashes differ from those recorded with the backup"
  printf 'PROOF content the hashes of issues, projects and file_assets match\n'

  # What a restore's GATE2 asks, on what came back: every row marked uploaded has its object here.
  psql -XAt -v ON_ERROR_STOP=1 -d restored \
    -c "SELECT asset FROM file_assets WHERE is_uploaded AND NOT is_deleted AND deleted_at IS NULL" | LC_ALL=C sort >/tmp/uploaded.txt
  (cd objects && find . -type f | sed 's|^\./||') | LC_ALL=C sort >/tmp/objects.txt
  MISSING="$(LC_ALL=C comm -23 /tmp/uploaded.txt /tmp/objects.txt | wc -l | tr -d ' ')"
  UPLOADED="$(wc -l </tmp/uploaded.txt | tr -d ' ')"
  OBJECTS="$(wc -l </tmp/objects.txt | tr -d ' ')"
  [ "$MISSING" = 0 ] || fail "$MISSING of $UPLOADED rows marked uploaded have no object in this backup"
  printf 'PROOF objects %s objects, %s rows marked uploaded, none missing\n' "$OBJECTS" "$UPLOADED"
fi

if [ "$SOURCE" = frameflow ]; then
  # Frameflow's SQLite copy is not opened here, because this image has no SQLite. The copy passed integrity_check when the backup took
  # it, and its hash, checked above, says these are those bytes.
  [ "$(head -c 15 sqlite/app.db)" = "SQLite format 3" ] || fail "sqlite/app.db is not a SQLite database"
  [ "$(cat sqlite/integrity.txt)" = ok ] || fail "the integrity_check recorded with the SQLite copy is not ok"
  printf 'PROOF sqlite the copy passed integrity_check when it was taken, and holds the %s tables recorded with it\n' "$(wc -l <sqlite/rowcounts.tsv | tr -d ' ')"

  # What Plane's GATE2 asks, from the list the backup took from that same copy: every object its rows name is here.
  (cd objects && find . -type f | sed 's|^\./||') | LC_ALL=C sort >/tmp/objects.txt
  OBJECTS="$(wc -l </tmp/objects.txt | tr -d ' ')"
  if [ -f sqlite/object-keys.txt ]; then
    LC_ALL=C sort sqlite/object-keys.txt >/tmp/named.txt
    MISSING="$(LC_ALL=C comm -23 /tmp/named.txt /tmp/objects.txt | wc -l | tr -d ' ')"
    NAMED="$(wc -l </tmp/named.txt | tr -d ' ')"
    [ "$MISSING" = 0 ] || fail "$MISSING of the $NAMED objects the rows name are not in this backup"
    printf 'PROOF objects %s objects, %s named by the rows, none missing\n' "$OBJECTS" "$NAMED"
  else
    printf 'PROOF objects %s objects. The backup recorded no list of what its rows name, so that was not compared\n' "$OBJECTS"
  fi
fi

pg_ctl -D "$PGDATA" -m fast -w stop >/dev/null
printf 'PROOF-RESULT pass %s %s\n' "$FILES" "$TABLES"
