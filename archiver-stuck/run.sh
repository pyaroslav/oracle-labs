#!/usr/bin/env bash
# Oracle archiver-stuck (ORA-00257) lab — driver. Everything runs INSIDE the container via `docker exec`, so you
# only need Docker. Companion to "ORA-00257: The Database Stopped Accepting Writes. The Archiver Is Stuck."
#
#   REPRODUCE : the database is in ARCHIVELOG mode with a tiny, fixed-size Fast Recovery Area. Generate redo and
#               switch logs a couple of times -- the FRA fills, the archiver (ARCn) can't write the next archived
#               log, and archive destination 1 goes to ERROR (ORA-19809, "Stuck archiver condition declared").
#               A normal (non-SYSDBA) session that tries to write is then refused with ORA-00257. Asserts both.
#   FIX       : back up the archived logs to a location OUTSIDE the FRA and DELETE the inputs (RMAN) so they stop
#               piling up, then grow the FRA for headroom and let the archiver catch up. Destination 1 returns to
#               VALID and the same normal user connects and writes again. Asserts the outage is cleared.
#
#   ./run.sh up        # start the database (first run pulls the image)
#   ./run.sh setup     # ARCHIVELOG + a dedicated 50 MB FRA + a redo-generating schema
#   ./run.sh reproduce # fill the FRA until the archiver sticks; assert ORA-00257 for a normal user
#   ./run.sh fix       # RMAN backup+delete of archived logs + headroom; assert writes resume
#   ./run.sh all       # setup -> reproduce -> fix
#   ./run.sh sql       # SQL*Plus as SYSDBA
#   ./run.sh down / destroy
set -euo pipefail
cd "$(dirname "$0")"

C=ora-archiver-stuck-lab
export LAB_PORT="${LAB_PORT:-1521}"

die() { echo "!! FAIL: $*" >&2; exit 1; }
run_sys() { docker exec -i "$C" sqlplus -s -L "/ as sysdba"; }
run_arc() { timeout 25 docker exec -i "$C" sqlplus -s -L "arc/Lab_Passw0rd1@localhost:1521/FREEPDB1"; }
sig() { printf '%s\n' "$1" | grep -E "^$2=" | head -1 | cut -d= -f2- | tr -d '[:space:]'; }

wait_healthy() {
  echo "Waiting for the database to be ready..."
  for i in $(seq 1 90); do
    if docker exec "$C" healthcheck.sh >/dev/null 2>&1; then echo "Database is ready."; return 0; fi
    sleep 5
  done
  die "timed out waiting for the database"
}

# read the archiver state -> sets globals FRA_PCT / DEST_STATUS
read_status() {
  local s; s=$(run_sys < scripts/status.sql)
  FRA_PCT=$(sig "$s" FRA_PCT); DEST_STATUS=$(sig "$s" DEST_STATUS)
}

cmd_up() { docker compose up -d; wait_healthy; }

cmd_setup() {
  wait_healthy
  docker exec "$C" mkdir -p /opt/oracle/fra /opt/oracle/backup >/dev/null 2>&1 || true
  echo ">> Enabling ARCHIVELOG, pointing archiving at a dedicated FRA, building the redo schema..."
  run_sys < scripts/setup.sql >/dev/null 2>&1 || true
  echo ">> Clearing any archived logs from a previous run, then shrinking the FRA to the tiny lab size..."
  docker exec -i "$C" rman target / >/dev/null 2>&1 <<'RMAN' || true
delete noprompt archivelog all;
RMAN
  run_sys < scripts/shrink.sql >/dev/null 2>&1 || true
  local m logmode frasize arc
  m=$(run_sys < scripts/meta.sql)
  logmode=$(sig "$m" LOGMODE); frasize=$(sig "$m" FRASIZE_MB); arc=$(sig "$m" ARC_EXISTS)
  echo "   log_mode=${logmode:-?}  FRA=${frasize:-?}MB  arc.t present=${arc:-?}"
  [ "${logmode:-}" = "ARCHIVELOG" ] || die "expected ARCHIVELOG mode, got '${logmode:-null}' -- setup failed:"$'\n'"$m"
  [ "${frasize:-0}" = "50" ]        || die "expected a 50 MB FRA, got '${frasize:-null} MB'"
  [ "${arc:-0}" = "1" ]             || die "expected the arc.t redo table to exist, got ARC_EXISTS='${arc:-null}'"
  echo ">> Setup complete."
}

cmd_reproduce() {
  echo ">> Filling the tiny 50 MB FRA with archived redo until the archiver's destination fails..."
  local i
  DEST_STATUS=""
  for i in $(seq 1 12); do
    read_status
    [ "${DEST_STATUS:-}" = "ERROR" ] && break
    timeout 60 docker exec -i "$C" sqlplus -s -L "/ as sysdba" < scripts/gen.sql    >/dev/null 2>&1 || true
    timeout 45 docker exec -i "$C" sqlplus -s -L "/ as sysdba" < scripts/switch.sql >/dev/null 2>&1 || true
    read_status
    echo "   round $i: FRA=${FRA_PCT:-?}%  dest_1=${DEST_STATUS:-?}"
    [ "${DEST_STATUS:-}" = "ERROR" ] && break
  done
  [ "${DEST_STATUS:-}" = "ERROR" ] || die "archiver destination did not fail (dest_1='${DEST_STATUS:-null}', FRA=${FRA_PCT:-?}%)"
  echo ">> dest_1 = ERROR (FRA ~${FRA_PCT}% full). Driving the online redo logs to full-and-unarchived so the"
  echo ">> instance can no longer accept redo: one background app session floods redo and blocks on a log switch."
  docker cp scripts/flood.sql "$C":/tmp/flood.sql >/dev/null 2>&1 || true
  docker exec -d "$C" bash -lc "sqlplus -s -L '/ as sysdba' @/tmp/flood.sql >/tmp/flood.log 2>&1" || true
  echo ">> A normal (non-SYSDBA) user now tries to connect and write..."
  local out="" k
  for k in $(seq 1 15); do
    out=$(run_arc <<'SQL' 2>&1 || true
set feedback off
insert into arc.t values (-1, 'blocked');
commit;
select 'OK' from dual;
SQL
)
    printf '%s' "$out" | grep -q "ORA-00257" && break
    sleep 3
  done
  if printf '%s' "$out" | grep -q "ORA-00257"; then
    printf '%s\n' "$out" | grep -E "ORA-00257" | head -1 | sed 's/^/      /'
    echo "   -> ORA-00257 confirmed: every non-SYSDBA session is locked out until the FRA is freed."
  else
    die "expected ORA-00257 for a normal user once the logs filled, last attempt:"$'\n'"$out"
  fi
}

cmd_fix() {
  echo ">> Fix 1 (sustainable): RMAN backs up the archived logs OUTSIDE the FRA and deletes the inputs..."
  docker exec -i "$C" rman target / 2>&1 <<'RMAN' | grep -E "input archived log thread|deleted archived log|Finished backup|RMAN-[0-9]|ORA-[0-9]" | head -20 || true
configure controlfile autobackup off;
backup archivelog all format '/opt/oracle/backup/arch_%U' delete all input;
RMAN
  echo ">> Fix 2 (headroom): grow the FRA and let the archiver catch up..."
  run_sys < scripts/fix.sql >/dev/null 2>&1 || true
  read_status
  echo "   FRA now ${FRA_PCT:-?}% full, dest_1 = ${DEST_STATUS:-?}"
  [ "${DEST_STATUS:-}" = "VALID" ] || die "expected dest_1 back to VALID after the fix, got '${DEST_STATUS:-null}'"
  echo ">> Verifying the outage is over: the same normal user connects and writes..."
  local out; out=$(run_arc <<'SQL' 2>&1 || true
set feedback off pages 0
insert into arc.t values (-2, 'recovered');
commit;
select 'ARC_OK ROWS='||count(*) from arc.t;
SQL
)
  if printf '%s' "$out" | grep -q "ARC_OK"; then
    printf '%s\n' "$out" | grep -E "ARC_OK" | head -1 | sed 's/^/   /'
    echo "   -> the archiver is writing again and normal sessions work. Outage cleared."
  else
    die "expected the normal user to connect + write after the fix, got:"$'\n'"$out"
  fi
}

cmd_all() {
  cmd_setup; echo
  cmd_reproduce; echo
  cmd_fix; echo
  echo ">> PASS: a full Fast Recovery Area stuck the archiver -> ORA-00257 locked out every non-SYSDBA session;"
  echo ">>       backing up and removing the archived logs (RMAN) plus headroom cleared it and writes resumed."
  echo ">> ALL DRILLS COMPLETE"
}

cmd_sql()     { docker exec -it "$C" sqlplus "/ as sysdba"; }
cmd_down()    { docker compose down; }
cmd_destroy() { docker compose down -v; }

case "${1:-}" in
  up) cmd_up ;;
  setup) cmd_setup ;;
  reproduce) cmd_setup >/dev/null 2>&1 || true; cmd_reproduce ;;
  fix) cmd_fix ;;
  all) cmd_all ;;
  sql) cmd_sql ;;
  down) cmd_down ;;
  destroy) cmd_destroy ;;
  *) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
