#!/usr/bin/env bash
# Oracle HA concepts lab — driver. Everything runs INSIDE the container via `docker exec`,
# so you do NOT need an Oracle client on your machine. Just Docker.
#
#   ./run.sh up        # start the database (first run pulls the image + creates the DB)
#   ./run.sh setup     # enable archivelog + create the demo schema
#   ./run.sh drill1    # human-error recovery (Flashback)        — "replication is not a backup"
#   ./run.sh drill2    # RMAN backup & restore of a lost datafile
#   ./run.sh drill3    # block-corruption detection & block recovery
#   ./run.sh all       # setup + all three drills, end to end
#   ./run.sh status    # show DB role / log mode / open mode
#   ./run.sh sql       # open a SYSDBA SQL*Plus session inside the container
#   ./run.sh reset     # drop demo objects
#   ./run.sh down      # stop & remove the container (keeps the data volume)
#   ./run.sh destroy   # stop & remove the container AND the data volume
set -euo pipefail
cd "$(dirname "$0")"

C=ora-ha-lab
PW=Lab_Passw0rd1
export LAB_PORT="${LAB_PORT:-1521}"

c_sys()  { docker exec -i "$C" sqlplus -s -L "/ as sysdba"; }
c_pdb()  { docker exec -i "$C" sqlplus -s -L "sys/${PW}@//localhost:1521/FREEPDB1 as sysdba"; }
c_app()  { docker exec -i "$C" sqlplus -s -L "labuser/${PW}@//localhost:1521/FREEPDB1"; }
c_rman() { docker exec -i "$C" rman target /; }
# scalar query helper (one value, no headings)
q() { docker exec -i "$C" sqlplus -s -L "$1" <<EOF
set heading off feedback off pagesize 0 trimspool on
$2
exit
EOF
}

wait_healthy() {
  echo "Waiting for the database to be ready..."
  for i in $(seq 1 90); do
    if docker exec "$C" healthcheck.sh >/dev/null 2>&1; then echo "Database is ready."; return 0; fi
    sleep 5
  done
  echo "Timed out waiting for the database." >&2; exit 1
}

cmd_up() { docker compose up -d; wait_healthy; }

cmd_setup() {
  wait_healthy
  local mode
  mode=$(q "/ as sysdba" "select log_mode from v\$database;" | tr -d '[:space:]')
  if [ "$mode" = "ARCHIVELOG" ]; then
    echo ">> ARCHIVELOG already enabled."
  else
    echo ">> Enabling ARCHIVELOG mode (needed for media/block recovery)..."
    c_sys <<'EOF'
whenever sqlerror exit sql.sqlcode
set echo on
shutdown immediate
startup mount
alter database archivelog;
alter database open;
archive log list
EOF
    wait_healthy
  fi
  echo ">> Creating demo schema..."
  c_sys < scripts/01-demo-schema.sql
  echo ">> Setup complete."
}

# Oracle won't flashback-query a table created seconds ago (ORA-01466). On a brand-new DB the demo
# table is young, so wait for it to age past the limit. After the first run it's already old (no wait).
ensure_aged() {
  local age
  age=$(q "sys/${PW}@//localhost:1521/FREEPDB1 as sysdba" \
    "select floor((sysdate-created)*86400) from dba_objects where owner='LABUSER' and object_name='ORDERS' and object_type='TABLE';" \
    | tr -d '[:space:]')
  if [[ "$age" =~ ^[0-9]+$ ]] && (( age < 75 )); then
    local w=$(( 75 - age ))
    echo "   (new table — waiting ${w}s for it to age past Oracle's young-object flashback limit)"
    sleep "$w"
  fi
}

cmd_drill1() { echo ">> DRILL 1: human-error recovery"; ensure_aged; c_app < scripts/drill1-human-error.sql; }

cmd_drill2() {
  echo ">> DRILL 2: RMAN backup & restore of a lost datafile"
  local FNO FPATH
  FNO=$(q "/ as sysdba" "select file_id from cdb_data_files where tablespace_name='LABTS' and con_id=(select con_id from v\$pdbs where name='FREEPDB1');" | tr -d '[:space:]')
  FPATH=$(q "/ as sysdba" "select file_name from cdb_data_files where tablespace_name='LABTS' and con_id=(select con_id from v\$pdbs where name='FREEPDB1');" | tr -d '[:space:]')
  echo "   LABTS datafile = #$FNO  ($FPATH)"

  echo "   -- taking an RMAN backup..."
  c_rman <<'EOF'
configure controlfile autobackup on;
backup as compressed backupset database plus archivelog;
EOF

  echo "   -- simulating media failure: offline + delete the datafile"
  c_pdb <<EOF
whenever sqlerror exit sql.sqlcode
alter database datafile $FNO offline;
EOF
  docker exec "$C" rm -f "$FPATH"
  echo "   -- datafile removed from disk."

  echo "   -- restoring & recovering ONLY the lost datafile..."
  c_rman <<EOF
restore datafile $FNO;
recover datafile $FNO;
EOF
  c_pdb <<EOF
alter database datafile $FNO online;
EOF

  echo "   -- verifying the data survived:"
  c_app <<'EOF'
set heading on feedback on
select count(*) as orders_after_restore from orders;
EOF
}

cmd_drill3() {
  echo ">> DRILL 3: block-corruption detection & recovery"
  local FNO FPATH BLK BS
  FNO=$(q "sys/${PW}@//localhost:1521/FREEPDB1 as sysdba" "select dbms_rowid.rowid_to_absolute_fno(rowid,'LABUSER','ORDERS') from labuser.orders where rownum=1;" | tr -d '[:space:]')
  BLK=$(q "sys/${PW}@//localhost:1521/FREEPDB1 as sysdba" "select dbms_rowid.rowid_block_number(rowid) from labuser.orders where rownum=1;" | tr -d '[:space:]')
  FPATH=$(q "/ as sysdba" "select file_name from cdb_data_files where file_id=$FNO;" | tr -d '[:space:]')
  BS=$(q "/ as sysdba" "select value from v\$parameter where name='db_block_size';" | tr -d '[:space:]')
  echo "   A sample row lives in datafile #$FNO, block $BLK (block size $BS)"

  echo "   -- ensure a fresh backup exists (source for block recovery)..."
  c_rman <<EOF
backup as compressed backupset datafile $FNO;
EOF

  echo "   -- flushing cache, then corrupting that block on disk..."
  c_pdb <<'EOF'
alter system flush buffer_cache;
EOF
  docker exec "$C" bash -c "dd if=/dev/urandom of='$FPATH' bs=$BS seek=$BLK count=1 conv=notrunc status=none"

  echo "   -- DETECT with RMAN VALIDATE (RMAN exits non-zero when it FINDS corruption — expected):"
  c_rman <<EOF || true
validate check logical datafile $FNO;
EOF
  echo "   (corrupt blocks are also listed in V\$DATABASE_BLOCK_CORRUPTION)"

  echo "   -- REPAIR with block media recovery..."
  c_rman <<EOF
recover datafile $FNO block $BLK;
EOF

  echo "   -- re-validate (should now be clean):"
  c_rman <<EOF || true
validate check logical datafile $FNO;
EOF
}

cmd_all() { cmd_setup; cmd_drill1; cmd_drill2; cmd_drill3; echo ">> ALL DRILLS COMPLETE"; }

cmd_status() {
  c_sys <<'EOF'
set echo off feedback off
col name format a12
select name, db_unique_name, database_role, open_mode, log_mode from v$database;
EOF
}

cmd_reset() {
  c_pdb <<'EOF'
begin execute immediate 'drop table labuser.orders purge'; exception when others then null; end;
/
EOF
  echo "Demo objects dropped. Run './run.sh setup' to recreate."
}

cmd_sql()     { docker exec -it "$C" sqlplus "/ as sysdba"; }
cmd_down()    { docker compose down; }
cmd_destroy() { docker compose down -v; }

case "${1:-}" in
  up) cmd_up ;;
  setup) cmd_setup ;;
  drill1) cmd_drill1 ;;
  drill2) cmd_drill2 ;;
  drill3) cmd_drill3 ;;
  all) cmd_all ;;
  status) cmd_status ;;
  sql) cmd_sql ;;
  reset) cmd_reset ;;
  down) cmd_down ;;
  destroy) cmd_destroy ;;
  *) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
