#!/usr/bin/env bash
# Oracle VPD / Row-Level Security lab — driver. Everything runs INSIDE the container via `docker exec`, so
# you only need Docker. Companion to "Oracle Virtual Private Database: Row-Level Security You Can't Route Around".
#
# It builds ORDERS (3,000 rows: 1,800 EAST / 1,200 WEST), protects it with a Virtual Private Database policy
# (DBMS_RLS), then reads it back as three users to prove row-level security holds everywhere:
#
#   PROVE : REP_EAST sees only its 1,800 EAST rows; REP_WEST only its 1,200 WEST rows; MGR (holding EXEMPT
#           ACCESS POLICY) sees all 3,000. The predicate is enforced on COUNT, on SUM(amount), and on a
#           targeted lookup by id -- so a rep can't even reach another region's row by asking for it. That
#           proves VPD filters the BASE TABLE for every statement, unlike a view you could route around.
#           This is the ROW-level counterpart to the Data Redaction lab's COLUMN masking.
#
#   ./run.sh up        # start the database (first run pulls the image)
#   ./run.sh setup     # build ORDERS + the VPD policy + the three readers
#   ./run.sh prove     # read as REP_EAST / REP_WEST / MGR; assert each sees only what it should
#   ./run.sh all       # setup -> prove
#   ./run.sh sql       # SQL*Plus as SYSDBA inside the container
#   ./run.sh east      # SQL*Plus as REP_EAST (see the row filtering yourself)
#   ./run.sh down      # stop & remove the container (keeps the data volume)
#   ./run.sh destroy   # stop & remove the container AND the data volume
set -euo pipefail
cd "$(dirname "$0")"

C=ora-vpd-lab
export LAB_PORT="${LAB_PORT:-1521}"
LABPW='Lab_Passw0rd1'
EAST_TOTAL=1800; WEST_TOTAL=1200; ALL_TOTAL=3000

die() { echo "!! FAIL: $*" >&2; exit 1; }
run_sys()  { docker exec -i "$C" sqlplus -s -L "/ as sysdba"; }
run_user() { docker exec -i "$C" sqlplus -s -L "$1/$LABPW@localhost:1521/FREEPDB1"; }
read_meta() { run_sys < scripts/meta.sql; }
# match a line starting with KEY=, take everything after the first '=', strip whitespace (SQL*Plus
# right-justifies numbers with leading spaces; our values contain no internal spaces).
sig() { printf '%s\n' "$1" | grep -E "^$2=" | head -1 | cut -d= -f2- | tr -d '[:space:]'; }

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
  echo ">> Building ORDERS (3,000 rows: 1,800 EAST / 1,200 WEST) + the VPD policy + three readers..."
  run_sys < scripts/setup.sql >/dev/null 2>&1 || true   # asserts below are the real check
  local m tot e w pol
  m=$(read_meta); tot=$(sig "$m" TOTAL); e=$(sig "$m" EAST); w=$(sig "$m" WEST); pol=$(sig "$m" POLICIES)
  echo "   total=${tot:-?}  east=${e:-?}  west=${w:-?}  enabled policies=${pol:-?}"
  [ "${tot:-0}" = "$ALL_TOTAL" ]  || die "expected $ALL_TOTAL rows, got '${tot:-null}' -- setup failed:"$'\n'"$m"
  [ "${e:-0}"   = "$EAST_TOTAL" ] || die "expected $EAST_TOTAL EAST rows, got '${e:-null}'"
  [ "${w:-0}"   = "$WEST_TOTAL" ] || die "expected $WEST_TOTAL WEST rows, got '${w:-null}'"
  [ "${pol:-0}" -ge 1 ]           || die "VPD policy not enabled on VPDOWN.ORDERS (got '${pol:-null}') -- is DBMS_RLS available on this edition?"
  echo ">> Setup complete."
}

cmd_prove() {
  echo ">> Reading VPDOWN.ORDERS as three different users..."
  local E W M
  E=$(run_user rep_east < scripts/read.sql)
  W=$(run_user rep_west < scripts/read.sql)
  M=$(run_user mgr      < scripts/read.sql)

  local e_rows e_reg e_sum e_pick w_rows w_reg w_sum w_pick m_rows m_reg m_sum
  e_rows=$(sig "$E" ROWS); e_reg=$(sig "$E" REGIONS); e_sum=$(sig "$E" SUMAMT); e_pick=$(sig "$E" PICKWEST)
  w_rows=$(sig "$W" ROWS); w_reg=$(sig "$W" REGIONS); w_sum=$(sig "$W" SUMAMT); w_pick=$(sig "$W" PICKWEST)
  m_rows=$(sig "$M" ROWS); m_reg=$(sig "$M" REGIONS); m_sum=$(sig "$M" SUMAMT)

  printf '   %-9s %-6s %-10s %-10s %s\n' "user" "rows" "regions" "sum(amt)" "sees WEST id=3?"
  printf '   %-9s %-6s %-10s %-10s %s\n' "----" "----" "-------" "--------" "---------------"
  printf '   %-9s %-6s %-10s %-10s %s\n' "REP_EAST" "${e_rows:-?}" "${e_reg:-?}" "${e_sum:-?}" "${e_pick:-?}"
  printf '   %-9s %-6s %-10s %-10s %s\n' "REP_WEST" "${w_rows:-?}" "${w_reg:-?}" "${w_sum:-?}" "${w_pick:-?}"
  printf '   %-9s %-6s %-10s %-10s %s\n' "MGR"      "${m_rows:-?}" "${m_reg:-?}" "${m_sum:-?}" "(exempt)"

  # REP_EAST: only its 1,800 EAST rows, sum 180000, and CANNOT see WEST id=3
  [ "${e_rows:-0}" = "$EAST_TOTAL" ] || die "REP_EAST saw ${e_rows:-null} rows, expected $EAST_TOTAL (only EAST)"
  [ "$e_reg" = "EAST" ]              || die "REP_EAST saw regions '${e_reg:-null}', expected only EAST"
  [ "${e_sum:-0}" = "180000" ]       || die "REP_EAST SUM(amount)=${e_sum:-null}, expected 180000 -- the aggregate must be filtered too"
  [ "${e_pick:-x}" = "0" ]           || die "REP_EAST could see WEST row id=3 (pick=${e_pick:-null}) -- VPD not enforced on a targeted lookup"

  # REP_WEST: only its 1,200 WEST rows, sum 120000, and CAN see its own WEST id=3
  [ "${w_rows:-0}" = "$WEST_TOTAL" ] || die "REP_WEST saw ${w_rows:-null} rows, expected $WEST_TOTAL (only WEST)"
  [ "$w_reg" = "WEST" ]              || die "REP_WEST saw regions '${w_reg:-null}', expected only WEST"
  [ "${w_sum:-0}" = "120000" ]       || die "REP_WEST SUM(amount)=${w_sum:-null}, expected 120000"
  [ "${w_pick:-x}" = "1" ]           || die "REP_WEST could not see its own WEST row id=3 (pick=${w_pick:-null})"

  # MGR: EXEMPT ACCESS POLICY -> sees every row
  [ "${m_rows:-0}" = "$ALL_TOTAL" ]  || die "MGR saw ${m_rows:-null} rows, expected $ALL_TOTAL (exempt sees all)"
  [ "$m_reg" = "EAST,WEST" ]         || die "MGR saw regions '${m_reg:-null}', expected EAST,WEST"
  [ "${m_sum:-0}" = "300000" ]       || die "MGR SUM(amount)=${m_sum:-null}, expected 300000"

  echo "   -> each rep is confined to its region on rows, sum, AND a by-id lookup; MGR is exempt and sees all 3,000."
}

cmd_all() {
  cmd_setup
  echo
  echo ">> PROVE: row-level security, enforced on the base table for every statement"
  cmd_prove
  echo
  echo ">> PASS: VPD appended each session's predicate to VPDOWN.ORDERS -- the reps are confined to their own"
  echo ">>       region (counts, sums, and targeted lookups alike), and EXEMPT ACCESS POLICY lets MGR see all."
  echo ">>       Row-level security you can't route around -- the opposite trade-off from a view or a column mask."
  echo ">> ALL DRILLS COMPLETE"
}

cmd_sql()     { docker exec -it "$C" sqlplus "/ as sysdba"; }
cmd_east()    { docker exec -it "$C" sqlplus "rep_east/$LABPW@localhost:1521/FREEPDB1"; }
cmd_down()    { docker compose down; }
cmd_destroy() { docker compose down -v; }

case "${1:-}" in
  up) cmd_up ;;
  setup) cmd_setup ;;
  prove) cmd_prove ;;
  all) cmd_all ;;
  sql) cmd_sql ;;
  east) cmd_east ;;
  down) cmd_down ;;
  destroy) cmd_destroy ;;
  *) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
