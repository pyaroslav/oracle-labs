#!/usr/bin/env bash
# Oracle RMAN recovery lab — break a throwaway database and recover it with RMAN. On Oracle Database Free.
# Everything runs INSIDE the container via `docker exec`, so you only need Docker.
#
#   ./run.sh up             # start Oracle Database Free (first run pulls the image + creates the DB)
#   ./run.sh setup          # enable ARCHIVELOG, create a demo tablespace + data, take an RMAN backup
#   ./run.sh validate       # prove a restore would work: RESTORE DATABASE VALIDATE + PREVIEW (read-only)
#   ./run.sh drill-datafile # lose a datafile from disk, then RESTORE + RECOVER it, verify the data is back
#   ./run.sh drill-pitr     # a bad DELETE, then point-in-time recovery (SET UNTIL SCN) to rewind past it
#   ./run.sh all            # setup + validate + drill-datafile + drill-pitr
#   ./run.sh sql            # SYSDBA SQL*Plus session inside the container
#   ./run.sh down           # stop & remove the container (keeps the data volume)
#   ./run.sh destroy        # stop & remove the container AND the data volume
set -euo pipefail
cd "$(dirname "$0")"

C=ora-rman-lab
export LAB_PORT="${LAB_PORT:-1521}"
DF='/opt/oracle/oradata/FREE/FREEPDB1/rman_demo.dbf'   # the datafile we deliberately lose
FRA='/opt/oracle/oradata/FRA'

run_sql()  { docker exec -i "$C" sqlplus -s -L "/ as sysdba"; }
run_rman() { docker exec -i "$C" rman target / ; }
die()      { echo "FAIL: $1" >&2; exit 1; }

wait_healthy() {
  echo "Waiting for the database to be ready..."
  for i in $(seq 1 90); do
    if docker exec "$C" healthcheck.sh >/dev/null 2>&1; then echo "Database is ready."; return 0; fi
    sleep 5
  done
  die "Timed out waiting for the database."
}

cmd_up() { docker compose up -d; wait_healthy; }

cmd_setup() {
  wait_healthy
  echo ">> SETUP: enabling ARCHIVELOG + FRA, creating demo data, taking an RMAN backup"
  docker exec "$C" bash -lc "mkdir -p $FRA"
  run_sql <<SQL
whenever sqlerror exit failure
alter system set db_recovery_file_dest_size=8G scope=both sid='*';
alter system set db_recovery_file_dest='$FRA' scope=both sid='*';
shutdown immediate
startup mount
alter database archivelog;
alter database open;
alter session set container=FREEPDB1;
begin execute immediate 'drop tablespace rman_demo including contents and datafiles'; exception when others then null; end;
/
create tablespace rman_demo datafile '$DF' size 50m autoextend on next 10m maxsize 300m;
create table orders_demo (id number primary key, note varchar2(60), created timestamp default systimestamp) tablespace rman_demo;
insert into orders_demo (id, note) select level, 'baseline row '||level from dual connect by level <= 100;
commit;
prompt SETUP_ROWS:
select count(*) from orders_demo;
exit
SQL
  echo ">> Taking the RMAN backup (whole database + archivelogs)..."
  run_rman <<'RMAN' | tee /tmp/rman-backup.log
configure controlfile autobackup on;
backup database plus archivelog;
exit
RMAN
  grep -qiE "RMAN-[0-9]|ORA-[0-9]" /tmp/rman-backup.log && die "backup hit RMAN/ORA errors (see above)."
  grep -qi "Finished backup" /tmp/rman-backup.log || die "RMAN backup did not finish."
  echo ">> SETUP OK — archivelog on, 100 rows, backup taken."
}

cmd_validate() {
  wait_healthy
  echo ">> VALIDATE: prove the backups can restore (read-only, changes nothing)"
  run_rman <<'RMAN' | tee /tmp/rman-validate.log
restore database validate check logical;
restore database preview summary;
exit
RMAN
  grep -qiE "RMAN-[0-9]|ORA-[0-9]" /tmp/rman-validate.log && die "validate hit RMAN/ORA errors."
  grep -qi "validation succeeded\|Finished restore" /tmp/rman-validate.log || die "validate did not confirm a good restore."
  echo ">> VALIDATE OK — a restore would succeed; recovery window is intact."
}

cmd_drill_datafile() {
  wait_healthy
  echo ">> DATAFILE LOSS DRILL: take rman_demo offline, delete it from disk, RESTORE + RECOVER"
  run_sql <<SQL
whenever sqlerror exit failure
alter session set container=FREEPDB1;
alter database datafile '$DF' offline;
exit
SQL
  docker exec "$C" bash -lc "rm -f '$DF'"
  docker exec "$C" bash -lc "test ! -f '$DF'" || die "datafile still on disk — rm failed."
  echo "   (datafile deleted from disk — the 'disaster')"
  run_rman <<SQL | tee /tmp/rman-datafile.log
restore datafile '$DF';
recover datafile '$DF';
exit
SQL
  grep -qiE "RMAN-[0-9]|ORA-[0-9]" /tmp/rman-datafile.log && die "datafile restore/recover hit errors."
  out=$(run_sql <<SQL
set heading off feedback off pagesize 0
alter session set container=FREEPDB1;
alter database datafile '$DF' online;
select 'ROWS='||count(*) from orders_demo;
exit
SQL
)
  echo "$out"
  echo "$out" | grep -q "ROWS=100" || die "expected 100 rows after recovery, got: $out"
  echo ">> DATAFILE DRILL OK — file was gone, restored + recovered, all 100 rows back."
}

cmd_drill_pitr() {
  wait_healthy
  echo ">> POINT-IN-TIME RECOVERY DRILL: insert a keeper row, note the SCN, do a bad DELETE, rewind past it"
  PIT_SCN=$(run_sql <<'SQL' | grep -oE '[0-9]{4,}' | tail -1
set heading off feedback off pagesize 0 verify off
alter session set container=FREEPDB1;
insert into orders_demo (id, note) values (9999, 'KEEPER before the bad delete');
commit;
select current_scn from v$database;
exit
SQL
)
  [ -n "${PIT_SCN:-}" ] || die "could not capture the recovery SCN."
  echo "   Captured recovery point: SCN $PIT_SCN (keeper row inserted, before the delete)"
  run_sql <<'SQL'
whenever sqlerror exit failure
alter session set container=FREEPDB1;
delete from orders_demo;
commit;
exit
SQL
  echo "   The 'bad DELETE' committed. Now rewinding the database to SCN $PIT_SCN..."
  run_rman <<RMAN | tee /tmp/rman-pitr.log
run {
  shutdown immediate;
  startup mount;
  set until scn $PIT_SCN;
  restore database;
  recover database;
  alter database open resetlogs;
}
exit
RMAN
  grep -qiE "RMAN-[0-9]|ORA-[0-9]" /tmp/rman-pitr.log && die "point-in-time recovery hit errors (see log)."
  out=$(run_sql <<'SQL'
set heading off feedback off pagesize 0
alter pluggable database FREEPDB1 open;
alter session set container=FREEPDB1;
select 'ROWS='||count(*) from orders_demo;
select 'KEEPER='||count(*) from orders_demo where id = 9999;
exit
SQL
)
  echo "$out"
  echo "$out" | grep -q "ROWS=101" || die "expected 101 rows after PITR (100 baseline + keeper), got: $out"
  echo "$out" | grep -q "KEEPER=1"  || die "keeper row not restored by PITR."
  echo ">> PITR OK — the bad DELETE was undone; the database was rewound to just before it."
}

cmd_all() {
  cmd_setup
  echo; cmd_validate
  echo; cmd_drill_datafile
  echo; cmd_drill_pitr
  echo; echo ">> ALL RMAN DRILLS PASSED — you broke it four ways and recovered every time."
}

cmd_sql()     { docker exec -it "$C" sqlplus "/ as sysdba"; }
cmd_down()    { docker compose down; }
cmd_destroy() { docker compose down -v; }

case "${1:-}" in
  up) cmd_up ;;
  setup) cmd_setup ;;
  validate) cmd_validate ;;
  drill-datafile) cmd_drill_datafile ;;
  drill-pitr) cmd_drill_pitr ;;
  all) cmd_all ;;
  sql) cmd_sql ;;
  down) cmd_down ;;
  destroy) cmd_destroy ;;
  *) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
