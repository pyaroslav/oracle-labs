#!/usr/bin/env bash
# Oracle Flashback lab — driver. Everything runs INSIDE the container via `docker exec`, so you only need
# Docker. Companion to the post "Oracle Flashback: Undo at the Database Level".
#
# Three human-error recoveries, hardest-hitting first:
#   badupdate : a committed WHERE-less UPDATE zeroes every balance -> FLASHBACK TABLE ... TO SCN rewinds it.
#   drop      : the table is dropped outright -> FLASHBACK TABLE ... TO BEFORE DROP brings it back.
#   database  : the whole app schema is dropped -> FLASHBACK DATABASE TO RESTORE POINT rewinds the entire DB.
#
#   ./run.sh up        # start the database (first run pulls the image)
#   ./run.sh setup     # enable ARCHIVELOG + FRA (one restart), build the demo schema (row movement on)
#   ./run.sh badupdate # reverse a bad UPDATE with FLASHBACK TABLE ... TO SCN
#   ./run.sh drop      # recover a dropped table with FLASHBACK TABLE ... TO BEFORE DROP
#   ./run.sh database  # rewind the whole database with FLASHBACK DATABASE TO RESTORE POINT
#   ./run.sh all       # setup -> badupdate -> drop -> database (each asserted)
#   ./run.sh sql       # SQL*Plus as SYSDBA inside the container
#   ./run.sh down      # stop & remove the container (keeps the data volume)
#   ./run.sh destroy   # stop & remove the container AND the data volume
set -euo pipefail
cd "$(dirname "$0")"

C=ora-flashback-lab
export LAB_PORT="${LAB_PORT:-1521}"
PW=Lab_Passw0rd1

die() { echo "!! FAIL: $*" >&2; exit 1; }
run_sys() { docker exec -i "$C" sqlplus -s -L "/ as sysdba"; }
run_app() { docker exec -i "$C" sqlplus -s -L "labuser/${PW}@//localhost:1521/FREEPDB1"; }
q() { { echo "set head off feed off pages 0 lines 200 verify off trimspool on"; printf '%s\n' "$2"; } \
      | docker exec -i "$C" sqlplus -s -L "$1" | tr -d '\r'; }
sig() { printf '%s' "$1" | grep -oE "$2=[-0-9A-Za-z_.]+" | head -1 | cut -d= -f2-; }

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
  docker exec "$C" mkdir -p /opt/oracle/oradata/fra
  local mode; mode=$(q "/ as sysdba" "select log_mode from v\$database;" | tr -d '[:space:]')
  if [ "$mode" != "ARCHIVELOG" ]; then
    echo ">> Enabling ARCHIVELOG + FRA (one restart, needed for the whole-database rewind)..."
    run_sys <<'EOF'
whenever sqlerror exit sql.sqlcode
alter system set db_recovery_file_dest_size = 6g scope=both;
alter system set db_recovery_file_dest = '/opt/oracle/oradata/fra' scope=both;
shutdown immediate
startup mount
alter database archivelog;
alter database open;
alter pluggable database all open;
EOF
    wait_healthy
  else
    echo ">> ARCHIVELOG already enabled."
  fi
  echo ">> Building demo schema (ACCOUNTS, 1000 rows, row movement on)..."
  run_sys < scripts/setup.sql >/dev/null
  echo ">> Setup complete."
}

# Oracle refuses a flashback to within ~seconds of a table's creation (ORA-01466). On a fresh DB the demo
# table is young, so wait for it to age past the limit; after the first run it's already old (no wait).
ensure_aged() {
  local age
  age=$(q "labuser/${PW}@//localhost:1521/FREEPDB1" \
    "select floor((sysdate-created)*86400) from user_objects where object_name='ACCOUNTS' and object_type='TABLE';" \
    | tr -d '[:space:]')
  if [[ "$age" =~ ^[0-9]+$ ]] && (( age < 75 )); then
    local w=$(( 75 - age ))
    echo "   (young table — waiting ${w}s past Oracle's flashback age limit)"
    sleep "$w"
  fi
}

cmd_badupdate() {
  echo ">> DRILL 1 — reverse a bad UPDATE with FLASHBACK TABLE ... TO SCN"
  ensure_aged
  local o zu zf rows
  o=$(run_app < scripts/badupdate.sql)
  zu=$(sig "$o" ZEROED_AFTER_UPDATE); zf=$(sig "$o" ZEROED_AFTER_FLASHBACK); rows=$(sig "$o" ROWS)
  echo "   balances zeroed by the bad UPDATE: ${zu:-?}   still zero after flashback: ${zf:-?}   rows: ${rows:-?}"
  [ "${zu:-0}" -ge 1000 ] || die "the bad UPDATE didn't zero the balances (got ${zu:-null}):"$'\n'"$o"
  [ "${zf:-1}" -eq 0 ]    || die "flashback did NOT restore the balances (${zf:-null} still zero)"
  [ "${rows:-0}" -eq 1000 ] || die "row count wrong after flashback (${rows:-null})"
  echo "   -> the table was rewound to the moment before the mistake."
}

cmd_drop() {
  echo ">> DRILL 2 — recover a dropped table with FLASHBACK TABLE ... TO BEFORE DROP"
  local o ed ef ra
  o=$(run_app < scripts/undrop.sql)
  ed=$(sig "$o" EXISTS_AFTER_DROP); ef=$(sig "$o" EXISTS_AFTER_FLASHBACK); ra=$(sig "$o" ROWS_AFTER)
  echo "   table present after drop: ${ed:-?}   after flashback: ${ef:-?}   rows: ${ra:-?}"
  [ "${ed:-1}" -eq 0 ] || die "the table was still present after the drop (${ed:-null}):"$'\n'"$o"
  [ "${ef:-0}" -eq 1 ] || die "flashback-to-before-drop did NOT restore the table (${ef:-null})"
  [ "${ra:-0}" -eq 1000 ] || die "row count wrong after undrop (${ra:-null})"
  echo "   -> the dropped table came back from the recycle bin, rows intact."
}

cmd_database() {
  echo ">> DRILL 3 — rewind the WHOLE database with FLASHBACK DATABASE TO RESTORE POINT"
  run_sys >/dev/null <<'EOF'
whenever sqlerror exit sql.sqlcode
create restore point before_disaster guarantee flashback database;
EOF
  echo "   guaranteed restore point 'before_disaster' created."

  echo "   -- the disaster: DROP USER labuser CASCADE (the whole app schema is gone)"
  run_sys >/dev/null <<'EOF'
whenever sqlerror exit sql.sqlcode
alter session set container = FREEPDB1;
drop user labuser cascade;
EOF
  local gone
  gone=$(q "/ as sysdba" "alter session set container=FREEPDB1;
select count(*) from all_users where username='LABUSER';" | tr -d '[:space:]')
  [ "${gone:-1}" -eq 0 ] || die "the disaster (drop user) didn't take (LABUSER count=${gone:-null})"
  echo "   after the disaster: LABUSER schema exists? no (count 0)"

  echo "   -- rewinding the entire database (shutdown, mount, flashback, open resetlogs)..."
  run_sys <<'EOF'
whenever sqlerror exit sql.sqlcode
shutdown immediate
startup mount
flashback database to restore point before_disaster;
alter database open resetlogs;
alter pluggable database all open;
EOF
  wait_healthy

  local rows
  rows=$(q "/ as sysdba" "alter session set container=FREEPDB1;
select count(*) from labuser.accounts;" | tr -d '[:space:]')
  echo "   after FLASHBACK DATABASE: labuser.accounts rows = ${rows:-?}"
  [ "${rows:-0}" -eq 1000 ] || die "the whole-database rewind did NOT bring the schema back (rows=${rows:-null})"

  run_sys >/dev/null <<'EOF'
whenever sqlerror continue
drop restore point before_disaster;
EOF
  echo "   -> the dropped schema is back — the entire database was rewound to before the disaster."
}

cmd_all() {
  cmd_setup
  echo;  cmd_badupdate
  echo;  cmd_drop
  echo;  cmd_database
  echo
  echo ">> PASS: bad UPDATE reversed (TO SCN), dropped table recovered (TO BEFORE DROP), whole database rewound (TO RESTORE POINT)."
  echo ">> ALL DRILLS COMPLETE"
}

cmd_sql()     { docker exec -it "$C" sqlplus "/ as sysdba"; }
cmd_down()    { docker compose down; }
cmd_destroy() { docker compose down -v; }

case "${1:-}" in
  up) cmd_up ;;
  setup) cmd_setup ;;
  badupdate) cmd_badupdate ;;
  drop) cmd_drop ;;
  database) cmd_database ;;
  all) cmd_all ;;
  sql) cmd_sql ;;
  down) cmd_down ;;
  destroy) cmd_destroy ;;
  *) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
