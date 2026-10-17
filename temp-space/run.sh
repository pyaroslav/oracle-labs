#!/usr/bin/env bash
# Oracle ORA-01652 lab — driver. Everything runs INSIDE the container via `docker exec`, so you only need Docker.
# Companion to the post on ORA-01652 "unable to extend temp segment".
#
#   SETUP    : TEMP_SMALL (32 MB, no autoextend) as the app user's temp tablespace; ORDERS (200,000 rows) and
#              CUSTOMERS (2,000 rows).
#   BEFORE   : the open-orders report with its join predicate missing (and DISTINCT added to hide the duplicates).
#              Asserted: ORA-01652 on TEMP_SMALL. Then the three views of TEMP right after the failure.
#   DIAGNOSE : EXPLAIN PLAN for the report. Asserted: MERGE JOIN CARTESIAN.
#   SPACE    : add a 288 MB tempfile (10x the space) and run the same report. Asserted: ORA-01652 again.
#              While it runs, V$TEMPSEG_USAGE polled from a second session. Asserted: SQL_ID_TEMPSEG is the report's SQL ID.
#              Then the culprit from ASH, the way you find it when the message has no SQL ID.
#   FIX      : drop the extra tempfile (back to 32 MB) and run the report with the join restored.
#              Asserted: 50,000 rows and 0 MB of TEMP.
#
#   ./run.sh up        # start the database (first run pulls the image)
#   ./run.sh setup     # build the tablespace, user and tables
#   ./run.sh before    # the broken report on 32 MB of TEMP; assert ORA-01652
#   ./run.sh diagnose  # EXPLAIN PLAN for the report
#   ./run.sh space     # 10x the TEMP; assert it fails again
#   ./run.sh fix       # back to 32 MB; the fixed report; assert it fits
#   ./run.sh all       # setup -> before -> diagnose -> space -> fix
#   ./run.sh sql       # SQL*Plus as SYSDBA
#   ./run.sh down / destroy
set -euo pipefail
cd "$(dirname "$0")"

C=ora-temp-space-lab
export LAB_PORT="${LAB_PORT:-1521}"

die() { echo "!! FAIL: $*" >&2; exit 1; }
run_sys() { docker exec -i "$C" sqlplus -s -L "/ as sysdba"; }
run_app() { docker exec -i "$C" sqlplus -s -L "ts/Ts_Passw0rd1@localhost:1521/FREEPDB1"; }
sig() { printf '%s\n' "$1" | grep -E "^$2=" | head -1 | cut -d= -f2- | tr -d '[:space:]'; }

wait_healthy() {
  echo "Waiting for the database to be ready..."
  for i in $(seq 1 90); do
    if docker exec "$C" healthcheck.sh >/dev/null 2>&1; then echo "Database is ready."; return 0; fi
    sleep 5
  done
  die "timed out waiting for the database"
}

alert_file() {
  local d
  d=$(printf "set heading off feedback off pages 0\nselect value from v\$diag_info where name = 'Diag Trace';\nexit\n" | run_sys | tr -d '[:space:]')
  echo "$d/alert_FREE.log"
}

# report: run the broken report, time it, and pull the SQL ID and temp used out of the ORA-01652 message
report() {
  local t0 t1 out
  t0=$(date +%s%N)
  out=$(run_app < scripts/report_broken.sql 2>&1 || true)
  t1=$(date +%s%N)
  ELAPSED=$(awk -v n=$(( (t1 - t0) / 1000000 )) 'BEGIN { printf "%.1f", n / 1000 }')
  ERR=$(printf '%s\n' "$out" | tr '\n' ' ' | grep -o 'ORA-01652[^H]*' | head -1 | sed 's/  */ /g' || true)
  SQLID=$(printf '%s\n' "$out" | tr '\n' ' ' | grep -o 'SQL ID : [a-z0-9]*' | head -1 | awk '{print $4}' || true)
  USED=$(printf '%s\n' "$out" | tr '\n' ' ' | grep -o 'used by session : [0-9]*' | head -1 | awk '{print $5}' || true)
}

temp_size() {
  printf "set heading off feedback off pages 0\nalter session set container=FREEPDB1;\nselect round(sum(bytes) / 1048576) from dba_temp_files where tablespace_name = 'TEMP_SMALL';\nexit\n" \
    | run_sys | grep -E '^[[:space:]]*[0-9]+[[:space:]]*$' | tr -d '[:space:]'
}

cmd_up() { docker compose up -d; wait_healthy; }

cmd_setup() {
  wait_healthy
  echo ">> Building TEMP_SMALL (32 MB, no autoextend), user TS, ORDERS (200,000 rows), CUSTOMERS (2,000 rows)..."
  run_sys < scripts/setup.sql >/dev/null || die "setup.sql failed"
  echo ">> Setup complete."
}

cmd_before() {
  wait_healthy
  echo ">> The open-orders report on $(temp_size) MB of TEMP:"
  report
  [ -n "$ERR" ] || die "expected ORA-01652, the report did not fail"
  echo "   failed after ${ELAPSED}s:"
  echo "   $ERR"
  [ -n "$SQLID" ] || die "could not read the SQL ID from the error message"
  echo ">> From the alert log:"
  docker exec "$C" bash -c "grep 'ORA-01652: unable' '$(alert_file)' | tail -1" | sed 's/^/   /'
  echo ">> TEMP_SMALL right after the failure, three ways:"
  local v; v=$(run_sys < scripts/temp_views.sql)
  local rows hu hf su fs sz
  rows=$(sig "$v" TEMPSEG_ROWS); hu=$(sig "$v" HDR_USED_MB); hf=$(sig "$v" HDR_FREE_MB)
  su=$(sig "$v" SORTSEG_USED_MB); fs=$(sig "$v" FREESPACE_MB); sz=$(sig "$v" SIZE_MB)
  printf '   V$TEMPSEG_USAGE      : %s rows (the culprit is already gone)\n' "$rows"
  printf '   V$TEMP_SPACE_HEADER  : %s MB used, %s MB free (looks full)\n' "$hu" "$hf"
  printf '   V$SORT_SEGMENT       : %s MB in use (it is not)\n' "$su"
  printf '   DBA_TEMP_FREE_SPACE  : %s MB free of %s MB\n' "$fs" "$sz"
  [ "$rows" = "0" ] || die "expected V\$TEMPSEG_USAGE to be empty after the failure, got $rows rows"
  [ "$su" = "0" ] || die "expected 0 MB in use in V\$SORT_SEGMENT after the failure, got $su"
}

cmd_diagnose() {
  wait_healthy
  echo ">> The plan for the report (EXPLAIN PLAN, nothing executed):"
  local plan; plan=$(run_app < scripts/diagnose.sql)
  printf '%s\n' "$plan" | grep -E '^\||^-' | sed 's/^/   /' || true
  printf '%s\n' "$plan" | grep -q 'MERGE JOIN CARTESIAN' || die "expected MERGE JOIN CARTESIAN in the plan"
  echo "   -> no join between ORDERS and CUSTOMERS: every OPEN order times every customer, then DISTINCT over all of it."
}

cmd_space() {
  wait_healthy
  echo ">> Adding a 288 MB tempfile: TEMP_SMALL goes from 32 MB to 320 MB, online."
  run_sys < scripts/add_space.sql >/dev/null || die "add_space.sql failed"
  echo ">> The SAME report on $(temp_size) MB of TEMP, watched live from a second session:"
  # poll until the report holds TEMP (no fixed sleep: CI runners are faster or slower than a desktop)
  ( for i in $(seq 1 60); do
      run_sys < scripts/live.sql > .live.out 2>&1
      grep -q '^LIVE_SQL_ID_TEMPSEG=[a-z0-9]' .live.out && break
      sleep 0.2
    done ) &
  local watcher=$!
  report
  wait "$watcher" || true
  local lv; lv=$(cat .live.out); rm -f .live.out
  local lid lts lmb ltx
  lid=$(sig "$lv" LIVE_SQL_ID); lts=$(sig "$lv" LIVE_SQL_ID_TEMPSEG); lmb=$(sig "$lv" LIVE_MB); ltx=$(sig "$lv" LIVE_SQL_ID_TEXT)
  printf '   V$TEMPSEG_USAGE while it ran: %s MB\n' "$lmb"
  printf '     SQL_ID         = %s  (%s...)\n' "$lid" "$(printf '%s' "$ltx" | tr '~' ' ' | cut -c1-45)"
  printf '     SQL_ID_TEMPSEG = %s  (the report)\n' "$lts"
  [ -n "$ERR" ] || die "expected ORA-01652 again with 10x the space, the report succeeded"
  echo "   failed after ${ELAPSED}s:"
  echo "   $ERR"
  [ "$lts" = "$SQLID" ] || die "expected V\$TEMPSEG_USAGE.SQL_ID_TEMPSEG ($lts) to match the SQL ID in the error ($SQLID)"
  [ "${USED:-0}" -gt 160 ] || die "expected the session to use most of the 320 MB before failing, it used ${USED:-?} MB"
  echo "   -> ten times the space bought ten times the runtime, then the same error."
  echo ">> Finding it after the fact from ASH (the 19c way, where the message has no SQL ID):"
  run_sys < scripts/ash.sql | sed '/^$/d' | sed 's/^/   /'
}

cmd_fix() {
  wait_healthy
  echo ">> Dropping the extra tempfile: TEMP_SMALL back to 32 MB."
  run_sys < scripts/remove_space.sql >/dev/null || die "remove_space.sql failed"
  echo ">> The report with the join predicate restored, on $(temp_size) MB of TEMP:"
  local t0 t1 out
  t0=$(date +%s%N)
  out=$(run_app < scripts/report_fixed.sql) || die "the fixed report failed:"$'\n'"$out"
  t1=$(date +%s%N)
  local rows; rows=$(sig "$out" ROWS)
  local v; v=$(run_sys < scripts/fixed_temp.sql)
  local mb; mb=$(sig "$v" FIXED_TEMP_MB)
  printf '   %s rows in %ss, %s MB of TEMP\n' "$rows" "$(awk -v n=$(( (t1 - t0) / 1000000 )) 'BEGIN { printf "%.1f", n / 1000 }')" "$mb"
  [ "$rows" = "50000" ] || die "expected 50000 rows, got $rows"
  [ "$(sig "$v" FIXED_SQL_SEEN)" -ge 1 ] || die "could not find the fixed report in V\$SQL"
  [ "$mb" = "0" ] || die "expected the fixed report to need no TEMP, it used $mb MB"
  echo "   -> one line of SQL, not 300 MB of disk, was the fix."
}

case "${1:-}" in
  up) cmd_up ;;
  setup) cmd_setup ;;
  before) cmd_before ;;
  diagnose) cmd_diagnose ;;
  space) cmd_space ;;
  fix) cmd_fix ;;
  all) cmd_setup; cmd_before; cmd_diagnose; cmd_space; cmd_fix; echo ">> All checks passed." ;;
  sql) docker exec -it "$C" sqlplus / as sysdba ;;
  down) docker compose down ;;
  destroy) docker compose down -v ;;
  *) sed -n '2,22p' "$0"; exit 1 ;;
esac
