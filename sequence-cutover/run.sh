#!/usr/bin/env bash
# Oracle sequence-cutover lab — driver. Everything runs INSIDE the container via `docker exec` (expdp/impdp/
# sqlplus), so you only need Docker. Companion to "Cutover Went Perfectly. The First New Order Failed With ORA-00001."
#
#   SETUP    : source schema SHOP with 9,000 orders keyed by ORDER_SEQ.
#   INITIAL  : expdp the whole schema (tables + sequences) and impdp it into NEWSHOP: the initial load.
#   DRIFT    : the source keeps taking orders (1,000 more) while the migration is in flight.
#   FINAL    : cutover-night refresh of the TABLE DATA ONLY (expdp/impdp CONTENT=DATA_ONLY, TRUNCATE).
#              Rows match the source; NEWSHOP.ORDER_SEQ is still where the initial load left it.
#   CUTOVER  : the first order on the new system -> ORA-00001. The check query flags the sequence as BEHIND.
#   FIX      : ALTER SEQUENCE ... RESTART START WITH max(id)+1 -> the check passes and the same insert works.
#
#   ./run.sh up        # start the database (first run pulls the image)
#   ./run.sh all       # setup -> initial -> drift -> final -> cutover -> fix
#   ./run.sh check     # run the pre-go-live sequence check on its own
#   ./run.sh sql       # SQL*Plus as SYSDBA
#   ./run.sh down / destroy
set -euo pipefail
cd "$(dirname "$0")"

C=ora-sequence-cutover-lab
export LAB_PORT="${LAB_PORT:-1521}"
CONN="system/Lab_Passw0rd1@localhost:1521/FREEPDB1"

die() { echo "!! FAIL: $*" >&2; exit 1; }
run_sys() { docker exec -i "$C" sqlplus -s -L "/ as sysdba"; }
sig() { printf '%s\n' "$1" | { grep -E "^$2=" || true; } | head -1 | cut -d= -f2- | tr -d '[:space:]'; }
dp() { docker exec -i "$C" "$@" 2>&1; }

wait_healthy() {
  echo "Waiting for the database to be ready..."
  for i in $(seq 1 90); do
    if docker exec "$C" healthcheck.sh >/dev/null 2>&1; then echo "Database is ready."; return 0; fi
    sleep 5
  done
  die "timed out waiting for the database"
}

state() {
  local o; o=$(run_sys < scripts/state.sql)
  SRC_ROWS=$(sig "$o" SRC_ROWS); SRC_MAX=$(sig "$o" SRC_MAX)
  TGT_ROWS=$(sig "$o" TGT_ROWS); TGT_MAX=$(sig "$o" TGT_MAX); TGT_SEQ=$(sig "$o" TGT_SEQ_NEXT)
}
show_state() {
  state
  printf '   source SHOP:     %6s rows, max(id)=%s\n' "${SRC_ROWS:-?}" "${SRC_MAX:-?}"
  printf '   target NEWSHOP:  %6s rows, max(id)=%s, ORDER_SEQ next=%s\n' "${TGT_ROWS:-?}" "${TGT_MAX:-?}" "${TGT_SEQ:-?}"
}
check() {
  local o; o=$(run_sys < scripts/check.sql)
  printf '%s\n' "$o" | grep -E 'next=' | sed 's/^/   check> /'
  BEHIND=$(sig "$o" BEHIND_COUNT)
}
cutover_insert() {
  local o; o=$(run_sys < scripts/cutover-insert.sql)
  INS=$(sig "$o" INSERT); NEW_ID=$(sig "$o" NEW_ID)
  ERR=$(printf '%s\n' "$o" | { grep -E '^ERR=' || true; } | head -1 | cut -d= -f2-)
}

cmd_up() { docker compose up -d; wait_healthy; }

cmd_setup() {
  wait_healthy
  echo ">> Source SHOP: 9,000 orders keyed by ORDER_SEQ..."
  docker exec "$C" mkdir -p /opt/oracle/dpdump
  run_sys < scripts/setup.sql >/dev/null || die "setup.sql failed"
}

cmd_initial() {
  echo ">> Initial load: expdp SCHEMAS=shop (tables + sequences) -> impdp REMAP_SCHEMA=shop:newshop"
  local o
  o=$(dp expdp "$CONN" schemas=shop directory=dp_dir dumpfile=initial.dmp logfile=initial_exp.log reuse_dumpfiles=yes)
  printf '%s' "$o" | grep -q 'successfully completed' || die "initial expdp failed:"$'\n'"$o"
  o=$(dp impdp "$CONN" schemas=shop remap_schema=shop:newshop directory=dp_dir dumpfile=initial.dmp logfile=initial_imp.log)
  printf '%s' "$o" | grep -q 'successfully completed\|completed with' || die "initial impdp failed:"$'\n'"$o"
  show_state
  [ "$TGT_ROWS" = "9000" ] || die "expected 9,000 rows on the target after the initial load, got '$TGT_ROWS'"
}

cmd_drift() {
  echo ">> The source keeps taking orders during the migration window: 1,000 more..."
  run_sys < scripts/more-orders.sql >/dev/null || die "more-orders.sql failed"
  show_state
  [ "$SRC_ROWS" = "10000" ] || die "expected 10,000 source rows, got '$SRC_ROWS'"
}

cmd_final() {
  echo ">> Cutover night: refresh the TABLE DATA ONLY (expdp/impdp CONTENT=DATA_ONLY, TABLE_EXISTS_ACTION=TRUNCATE)"
  local o
  o=$(dp expdp "$CONN" tables=shop.orders content=data_only directory=dp_dir dumpfile=final.dmp logfile=final_exp.log reuse_dumpfiles=yes)
  printf '%s' "$o" | grep -q 'successfully completed' || die "final expdp failed:"$'\n'"$o"
  o=$(dp impdp "$CONN" remap_schema=shop:newshop content=data_only table_exists_action=truncate directory=dp_dir dumpfile=final.dmp logfile=final_imp.log)
  printf '%s' "$o" | grep -q 'successfully completed\|completed with' || die "final impdp failed:"$'\n'"$o"
  show_state
  [ "$TGT_ROWS" = "$SRC_ROWS" ] && [ "$TGT_MAX" = "$SRC_MAX" ] || die "target rows/max should match the source after the refresh"
  echo "   -> row counts match: every check that compares data passes."
}

cmd_cutover() {
  echo ">> Pre-go-live sequence check (the step that is easy to skip):"
  check
  [ "${BEHIND:-0}" -ge 1 ] || die "expected the check to flag ORDER_SEQ as BEHIND"
  echo ">> Go-live anyway: the first order on the NEW system..."
  cutover_insert
  echo "   insert: ${INS:-?}   ${ERR:-}"
  [ "$INS" = "ORA-00001" ] || die "expected ORA-00001 on the first insert, got '${INS:-null}' (new id ${NEW_ID:-?})"
  echo "   -> the sequence was copied at the initial load and never moved; it hands out keys that already exist."
}

cmd_fix() {
  echo ">> Fix: ALTER SEQUENCE newshop.order_seq RESTART START WITH max(id)+1"
  run_sys < scripts/fix.sql >/dev/null || die "fix.sql failed"
  check
  [ "${BEHIND:-1}" = "0" ] || die "the check still flags a sequence as BEHIND after the fix"
  cutover_insert
  echo "   insert: ${INS:-?}   new id=${NEW_ID:-?}"
  [ "$INS" = "OK" ] || die "the insert still fails after the fix: ${ERR:-}"
  state
  [ "$NEW_ID" -gt "$SRC_MAX" ] || die "expected the new id to be above the migrated max ($SRC_MAX), got $NEW_ID"
  echo "   -> the same insert now succeeds, with a key above everything that was migrated."
}

cmd_all() {
  cmd_setup; echo
  cmd_initial; echo
  cmd_drift; echo
  cmd_final; echo
  cmd_cutover; echo
  cmd_fix; echo
  echo ">> PASS: a data-only final refresh left the target sequence behind the migrated keys -> ORA-00001 on the"
  echo ">>       first new order; the check flagged it and RESTART START WITH max(id)+1 fixed it."
  echo ">> ALL DRILLS COMPLETE"
}

cmd_check()   { check; }
cmd_sql()     { docker exec -it "$C" sqlplus "/ as sysdba"; }
cmd_down()    { docker compose down; }
cmd_destroy() { docker compose down -v; }

case "${1:-}" in
  up) cmd_up ;;
  setup) cmd_setup ;;
  initial) cmd_initial ;;
  drift) cmd_drift ;;
  final) cmd_final ;;
  cutover) cmd_cutover ;;
  fix) cmd_fix ;;
  all) cmd_all ;;
  check) cmd_check ;;
  sql) cmd_sql ;;
  down) cmd_down ;;
  destroy) cmd_destroy ;;
  *) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
