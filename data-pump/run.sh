#!/usr/bin/env bash
# Oracle Data Pump lab — driver. Everything runs INSIDE the container via `docker exec` (expdp/impdp/sqlplus),
# so you only need Docker. Companion to "Oracle Data Pump, Done Right: A Migration You Can Prove".
#
# Builds DPSHOP (5,000 customers, 20,000 orders), exports it, then proves what impdp gets right:
#   EXPORT    : expdp the schema to a dump file (asserts the job completes and the .dmp exists).
#   ROUNDTRIP : drop DPSHOP, impdp it back -> exact same row counts (a lossless round trip).
#   REMAP     : impdp REMAP_SCHEMA=dpshop:dpclone -> the data lands in a NEW schema (the migration move).
#   FILTER    : expdp INCLUDE just ORDERS -> a selective dump, re-imported into DPONLY and asserted.
#
#   ./run.sh up        # start the database (first run pulls the image)
#   ./run.sh setup     # build DPSHOP + the Data Pump directory
#   ./run.sh export    # expdp the schema
#   ./run.sh roundtrip # drop DPSHOP, impdp it back, assert row counts match
#   ./run.sh remap     # impdp into DPCLONE with REMAP_SCHEMA, assert row counts
#   ./run.sh filter    # expdp only ORDERS, impdp into DPONLY, assert only that table came across
#   ./run.sh all       # setup -> export -> roundtrip -> remap -> filter
#   ./run.sh sql       # SQL*Plus as SYSDBA inside the container
#   ./run.sh down      # stop & remove the container (keeps the data volume)
#   ./run.sh destroy   # stop & remove the container AND the data volume
set -euo pipefail
cd "$(dirname "$0")"

C=ora-data-pump-lab
export LAB_PORT="${LAB_PORT:-1521}"
PW='Lab_Passw0rd1'
CONN="system/$PW@localhost:1521/FREEPDB1"

die() { echo "!! FAIL: $*" >&2; exit 1; }
run_sys() { docker exec -i "$C" sqlplus -s -L "/ as sysdba"; }
# row counts + table list for a schema: counts DPCLONE
counts() { { echo "define SCHEMA=$1"; cat scripts/counts.sql; } | run_sys; }
# match a line starting with KEY=, take everything after the first '=', strip whitespace.
sig() { printf '%s\n' "$1" | grep -E "^$2=" | head -1 | cut -d= -f2- | tr -d '[:space:]'; }
dp()  { docker exec -i "$C" "$@"; }

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
  echo ">> Building DPSHOP (5,000 customers, 20,000 orders) + the Data Pump directory..."
  docker exec "$C" mkdir -p /opt/oracle/dpdump
  run_sys < scripts/setup.sql >/dev/null 2>&1 || true
  local m cust ord
  m=$(counts DPSHOP); cust=$(sig "$m" CUST); ord=$(sig "$m" ORD)
  echo "   DPSHOP customers=${cust:-?}  orders=${ord:-?}"
  [ "${cust:-0}" = "5000" ]  || die "expected 5000 customers, got '${cust:-null}' -- setup failed:"$'\n'"$m"
  [ "${ord:-0}"  = "20000" ] || die "expected 20000 orders, got '${ord:-null}'"
  echo ">> Setup complete."
}

cmd_export() {
  echo ">> expdp: exporting the DPSHOP schema..."
  local out
  out=$(dp expdp "$CONN" schemas=dpshop directory=dp_dir dumpfile=shop.dmp logfile=exp.log reuse_dumpfiles=yes 2>&1 || true)
  printf '%s\n' "$out" | grep -E 'exported "DPSHOP"|successfully completed' | sed 's/^/   /' || true
  printf '%s' "$out" | grep -q 'successfully completed' || die "expdp did not complete:"$'\n'"$out"
  docker exec "$C" test -f /opt/oracle/dpdump/shop.dmp || die "dump file shop.dmp was not created"
  echo "   -> shop.dmp written; export job completed."
}

cmd_roundtrip() {
  echo ">> Dropping DPSHOP, then re-importing it from the dump..."
  { echo "alter session set container=FREEPDB1;"; echo "drop user dpshop cascade;"; echo "exit"; } | run_sys >/dev/null 2>&1 || true
  local gone; gone=$(sig "$(counts DPSHOP)" TABLES)
  [ -z "$gone" ] || die "DPSHOP still has tables after drop ($gone) -- drop failed"
  dp impdp "$CONN" schemas=dpshop directory=dp_dir dumpfile=shop.dmp logfile=imp.log 2>&1 | grep -E 'imported "DPSHOP"|successfully completed' | sed 's/^/   /' || true
  local m cust ord; m=$(counts DPSHOP); cust=$(sig "$m" CUST); ord=$(sig "$m" ORD)
  echo "   after re-import: DPSHOP customers=${cust:-?}  orders=${ord:-?}"
  [ "${cust:-0}" = "5000" ] && [ "${ord:-0}" = "20000" ] || die "round trip lost data (customers=$cust orders=$ord, expected 5000/20000)"
  echo "   -> lossless round trip: exact same 5,000 + 20,000 rows came back."
}

cmd_remap() {
  echo ">> impdp REMAP_SCHEMA=dpshop:dpclone (migrate into a NEW schema)..."
  dp impdp "$CONN" remap_schema=dpshop:dpclone directory=dp_dir dumpfile=shop.dmp logfile=remap.log 2>&1 | grep -E 'imported "DPCLONE"|successfully completed' | sed 's/^/   /' || true
  local m cust ord; m=$(counts DPCLONE); cust=$(sig "$m" CUST); ord=$(sig "$m" ORD)
  echo "   DPCLONE customers=${cust:-?}  orders=${ord:-?}"
  [ "${cust:-0}" = "5000" ] && [ "${ord:-0}" = "20000" ] || die "remap import wrong (DPCLONE customers=$cust orders=$ord, expected 5000/20000)"
  echo "   -> same data, new schema name. That's the migration move."
}

cmd_filter() {
  echo ">> expdp INCLUDE only ORDERS (a selective dump via PARFILE), then impdp into DPONLY..."
  # a PARFILE avoids the shell-quoting pain of command-line INCLUDE filters
  docker exec -i "$C" bash -c "cat > /opt/oracle/dpdump/filt.par" <<'PAR'
SCHEMAS=dpshop
INCLUDE=TABLE:"IN ('ORDERS')"
DIRECTORY=dp_dir
DUMPFILE=orders_only.dmp
LOGFILE=filt.log
REUSE_DUMPFILES=yes
PAR
  dp expdp "$CONN" parfile=/opt/oracle/dpdump/filt.par 2>&1 | grep -E 'exported "DPSHOP"."ORDERS"|successfully completed' | sed 's/^/   /' || true
  # a TABLE-mode filtered dump carries no CREATE USER DDL, so the remap target must exist first
  { echo "alter session set container=FREEPDB1;";
    echo "begin execute immediate 'drop user dponly cascade'; exception when others then null; end;"; echo "/";
    echo "create user dponly identified by \"$PW\" default tablespace users quota unlimited on users;";
    echo "grant create session to dponly;"; echo "exit"; } | run_sys >/dev/null 2>&1 || true
  dp impdp "$CONN" remap_schema=dpshop:dponly directory=dp_dir dumpfile=orders_only.dmp logfile=filtimp.log 2>&1 | grep -E 'imported "DPONLY"|successfully completed' | sed 's/^/   /' || true
  local m tables ord; m=$(counts DPONLY); tables=$(sig "$m" TABLES); ord=$(sig "$m" ORD)
  echo "   DPONLY tables=[${tables:-}]  orders=${ord:-?}"
  [ "${ord:-0}" = "20000" ]           || die "filtered import missing ORDERS rows (got '${ord:-null}')"
  case "${tables:-}" in *CUSTOMERS*) die "CUSTOMERS leaked into the filtered dump (tables=$tables) -- INCLUDE didn't filter";; esac
  echo "   -> only ORDERS came across (no CUSTOMERS). INCLUDE filtered the export exactly."
}

cmd_all() {
  cmd_setup; echo
  echo ">> EXPORT";    cmd_export;    echo
  echo ">> ROUNDTRIP"; cmd_roundtrip; echo
  echo ">> REMAP";     cmd_remap;     echo
  echo ">> FILTER";    cmd_filter;    echo
  echo ">> PASS: export/import is a lossless round trip; REMAP_SCHEMA migrates to a new name; INCLUDE filters exactly."
  echo ">> ALL DRILLS COMPLETE"
}

cmd_sql()     { docker exec -it "$C" sqlplus "/ as sysdba"; }
cmd_down()    { docker compose down; }
cmd_destroy() { docker compose down -v; }

case "${1:-}" in
  up) cmd_up ;;
  setup) cmd_setup ;;
  export) cmd_export ;;
  roundtrip) cmd_roundtrip ;;
  remap) cmd_remap ;;
  filter) cmd_filter ;;
  all) cmd_all ;;
  sql) cmd_sql ;;
  down) cmd_down ;;
  destroy) cmd_destroy ;;
  *) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
