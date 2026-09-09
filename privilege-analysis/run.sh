#!/usr/bin/env bash
# Oracle Privilege Analysis lab — driver. Everything runs INSIDE the container via `docker exec`, so you
# only need Docker. Companion to "Oracle Privilege Analysis: You Granted DBA. Here's What They Actually Used."
#
# Builds a deliberately OVER-privileged user (role PA_ROLE = 10 system privileges + 2 object grants = 12),
# captures what it really uses with DBMS_PRIVILEGE_CAPTURE, runs a tiny workload as it, then reports the gap:
#
#   PROVE : APPUSER was granted 12 privileges but the workload only USED three — CREATE SESSION, CREATE TABLE,
#           and SELECT on PAOWN.CUSTOMERS. Everything else (SELECT ANY TABLE, DROP ANY TABLE, CREATE ANY
#           TABLE, CREATE VIEW/PROCEDURE/SEQUENCE/SYNONYM, SELECT on PAOWN.ORDERS) sits UNUSED. That unused
#           pile is exactly what least-privilege says to revoke — and here it's evidence, not a guess.
#
#   ./run.sh up        # start the database (first run pulls the image)
#   ./run.sh setup     # build the over-privileged user + start the capture
#   ./run.sh workload  # run the small real workload AS APPUSER (this is what gets captured)
#   ./run.sh analyze   # stop the capture, generate the result, report USED vs UNUSED; assert the gap
#   ./run.sh all       # setup -> workload -> analyze
#   ./run.sh sql       # SQL*Plus as SYSDBA
#   ./run.sh appuser   # SQL*Plus as APPUSER
#   ./run.sh down      # stop & remove the container (keeps the data volume)
#   ./run.sh destroy   # stop & remove the container AND the data volume
set -euo pipefail
cd "$(dirname "$0")"

C=ora-privilege-analysis-lab
export LAB_PORT="${LAB_PORT:-1521}"
LABPW='Lab_Passw0rd1'

die() { echo "!! FAIL: $*" >&2; exit 1; }
run_sys()  { docker exec -i "$C" sqlplus -s -L "/ as sysdba"; }
run_user() { docker exec -i "$C" sqlplus -s -L "$1/$LABPW@localhost:1521/FREEPDB1"; }
# match a line KEY=..., take everything after the first '=', strip whitespace (privilege names have their
# spaces pre-replaced with '_' in the SQL, so stripping is safe and values stay readable).
sig() { printf '%s\n' "$1" | grep -E "^$2=" | head -1 | cut -d= -f2- | tr -d '[:space:]'; }
has() { case "$1" in *"$2"*) return 0;; *) return 1;; esac; }

wait_healthy() {
  echo "Waiting for the database to be ready..."
  for i in $(seq 1 90); do
    if docker exec "$C" healthcheck.sh >/dev/null 2>&1; then echo "Database is ready."; return 0; fi
    sleep 5
  done
  die "timed out waiting for the database"
}

cmd_up() { docker compose up -d; wait_healthy; }

cmd_setup() {
  wait_healthy
  echo ">> Building the over-privileged APPUSER (role PA_ROLE) and starting the capture..."
  run_sys < scripts/setup.sql >/dev/null 2>&1 || true   # asserts below are the real check
  local m enabled granted
  m=$(run_sys < scripts/meta.sql); enabled=$(sig "$m" CAP_ENABLED); granted=$(sig "$m" GRANTED)
  echo "   capture enabled=${enabled:-?}   privileges granted to APPUSER via PA_ROLE=${granted:-?}"
  [[ "${enabled:-N}" == Y* ]] || die "privilege capture APPUSER_CAP is not enabled (got '${enabled:-null}') -- is DBMS_PRIVILEGE_CAPTURE available on this edition?:"$'\n'"$m"
  [ "${granted:-0}" -ge 10 ]   || die "expected >=10 privileges granted, got '${granted:-null}' -- setup failed"
  echo ">> Setup complete (capture running)."
}

cmd_workload() {
  echo ">> Running the small real workload AS APPUSER (login, read CUSTOMERS, create one own table)..."
  run_user appuser < scripts/workload.sql >/dev/null 2>&1 || true
  # prove the workload actually connected + ran (scratch table exists), else the capture would be empty
  local n
  n=$(printf '%s' "alter session set container=FREEPDB1;
select 'N='||count(*) from appuser.scratch;
exit" | run_sys | grep -E '^N=' | cut -d= -f2 | tr -d '[:space:]')
  [ "${n:-0}" -ge 1 ] || die "workload did not run as APPUSER (appuser.scratch has no rows) -- did the login/grant work?"
  echo "   -> workload ran (appuser.scratch populated)."
}

cmd_analyze() {
  echo ">> Stopping the capture, computing the result, and comparing USED vs UNUSED..."
  local out used_sys unused_sys used_obj unused_obj nused nunused
  out=$(run_sys < scripts/analyze.sql)
  used_sys=$(sig "$out" USED_SYS);   unused_sys=$(sig "$out" UNUSED_SYS)
  used_obj=$(sig "$out" USED_OBJ);   unused_obj=$(sig "$out" UNUSED_OBJ)
  nused=$(sig "$out" NUSED);         nunused=$(sig "$out" NUNUSED)

  echo "   USED   (${nused:-?}): sys=[${used_sys:-}]  obj=[${used_obj:-}]"
  echo "   UNUSED (${nunused:-?}): sys=[${unused_sys:-}]  obj=[${unused_obj:-}]"

  # USED must include the three the workload actually exercised
  has "$used_sys" "CREATE_SESSION" || die "CREATE SESSION should be USED (got used_sys='${used_sys:-null}')"
  has "$used_sys" "CREATE_TABLE"   || die "CREATE TABLE should be USED (got used_sys='${used_sys:-null}')"
  has "$used_obj" "CUSTOMERS"      || die "SELECT on PAOWN.CUSTOMERS should be USED (got used_obj='${used_obj:-null}')"

  # UNUSED must include the scary over-grants the workload never touched
  has "$unused_sys" "DROP_ANY_TABLE"   || die "DROP ANY TABLE should be UNUSED (got unused_sys='${unused_sys:-null}')"
  has "$unused_sys" "CREATE_ANY_TABLE" || die "CREATE ANY TABLE should be UNUSED (got unused_sys='${unused_sys:-null}')"
  has "$unused_sys" "SELECT_ANY_TABLE" || die "SELECT ANY TABLE should be UNUSED -- the workload read only a table it had an explicit grant on (got unused_sys='${unused_sys:-null}')"
  has "$unused_obj" "ORDERS"           || die "SELECT on PAOWN.ORDERS should be UNUSED (got unused_obj='${unused_obj:-null}')"

  # and the gap should be real: more unused than used
  [ "${nused:-0}" -ge 3 ]    || die "expected >=3 used privileges, got '${nused:-null}'"
  [ "${nunused:-0}" -ge 6 ]  || die "expected >=6 unused privileges (the over-grant), got '${nunused:-null}'"
  [ "${nunused:-0}" -gt "${nused:-0}" ] || die "expected MORE unused than used (nunused=$nunused, nused=$nused)"

  echo "   -> APPUSER used ${nused} of $((nused+nunused)) privileges; ${nunused} sat unused, incl. SELECT/DROP/CREATE ANY TABLE."
  echo "   -> Least privilege = keep the used set, revoke the rest. Proven from evidence, not guessed."
}

cmd_all() {
  cmd_setup;    echo
  cmd_workload; echo
  cmd_analyze;  echo
  echo ">> PASS: the capture recorded exactly what APPUSER exercised; the granted-but-unused privileges are"
  echo ">>       the revoke list. That's Privilege Analysis: right-size grants from real usage, not a guess."
  echo ">> ALL DRILLS COMPLETE"
}

cmd_sql()     { docker exec -it "$C" sqlplus "/ as sysdba"; }
cmd_appuser() { docker exec -it "$C" sqlplus "appuser/$LABPW@localhost:1521/FREEPDB1"; }
cmd_down()    { docker compose down; }
cmd_destroy() { docker compose down -v; }

case "${1:-}" in
  up) cmd_up ;;
  setup) cmd_setup ;;
  workload) cmd_workload ;;
  analyze) cmd_analyze ;;
  all) cmd_all ;;
  sql) cmd_sql ;;
  appuser) cmd_appuser ;;
  down) cmd_down ;;
  destroy) cmd_destroy ;;
  *) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
