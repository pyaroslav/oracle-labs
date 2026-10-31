#!/usr/bin/env bash
# Oracle SYSDATE time-zone lab — driver. Everything runs INSIDE the container via `docker exec`, so you only need Docker.
# Companion to the post on SYSDATE being hours off after a move to a UTC cloud host.
#
# A database server is "moved" by restarting the same instance with a different TZ in its environment, the way a
# lift-and-shift lands the database on a host that runs in UTC. Chicago's offset is read from the database each time
# (-5 in summer, -6 in winter), so the checks hold all year.
#
#   SETUP   : app schema TZ_APP (orders with ORDER_DATE DEFAULT SYSDATE), two nightly 2am jobs, DBTIMEZONE UTC.
#   ONPREM  : instance started in America/Chicago. Asserted: the app's SYSDATE is Chicago time, so is a job's.
#   MOVE    : instance restarted in UTC. Asserted: the app's SYSDATE and the job's jump to UTC; two orders placed
#             seconds apart are stored 5 (or 6) hours apart; the 2am scheduler job still runs at 2am Chicago.
#   TRAPS   : Asserted: DBTIMEZONE set to Chicago changes nothing for SYSDATE; a DBA shell with TZ set sees Chicago
#             while the app still sees UTC; TZ on the listener changes nothing (26ai); CURRENT_DATE follows the
#             client, not the server; a job stored with a fixed -05:00 offset runs at 1am after the DST change.
#   FIX_OS  : instance restarted with TZ=America/Chicago (the listener left in UTC). Asserted: app and job on
#             Chicago time again.
#   FIX_DB  : instance back on UTC; DBTIMEZONE America/Chicago + TIME_AT_DBTIMEZONE=USER_SQL (26ai).
#             Asserted: ORA-30079 while a TIMESTAMP WITH LOCAL TIME ZONE column holds data. Asserted: app, job
#             and the column default on Chicago time, with the OS still in UTC.
#
#   ./run.sh up        # start the database (first run pulls the image)
#   ./run.sh setup     # create the schema and jobs, reset both time-zone settings (safe to rerun)
#   ./run.sh onprem    # the "on-prem" server: instance in America/Chicago
#   ./run.sh move      # the "cloud" server: same instance restarted in UTC
#   ./run.sh traps     # what doesn't fix it
#   ./run.sh fix_os    # fix 1: give the instance its time zone back
#   ./run.sh fix_db    # fix 2: TIME_AT_DBTIMEZONE (26ai), the OS stays in UTC
#   ./run.sh all       # setup -> onprem -> move -> traps -> fix_os -> fix_db, in order (each step builds on the last)
#   ./run.sh sql       # SQL*Plus as SYSDBA
#   ./run.sh down / destroy
set -euo pipefail
cd "$(dirname "$0")"

C=ora-sysdate-timezone-lab
export LAB_PORT="${LAB_PORT:-1521}"
APP="tz_app/Tz_App_Passw0rd1@localhost:1521/FREEPDB1"
ZONE=America/Chicago

die() { echo "!! FAIL: $*" >&2; exit 1; }
run_sys() { docker exec -i "$C" sqlplus -s -L "/ as sysdba"; }
pdb() { printf 'whenever sqlerror exit failure\nalter session set container = FREEPDB1;\n%s\nexit\n' "$1" | run_sys >/dev/null \
  || die "failed: $1"; }
sig() { printf '%s\n' "$1" | grep -E "^$2=" | head -1 | cut -d= -f2-; }

wait_healthy() {
  echo "Waiting for the database to be ready..."
  for i in $(seq 1 90); do
    if docker exec "$C" healthcheck.sh >/dev/null 2>&1; then echo "Database is ready."; return 0; fi
    sleep 5
  done
  die "timed out waiting for the database"
}

# app [docker exec options]: the clock as the application sees it, over the listener
app() { printf '@/tmp/clock.sql\n' | docker exec -i "$@" "$C" sqlplus -s -L "$APP"; }
wait_app() {
  for i in $(seq 1 60); do [[ "$(app 2>/dev/null || true)" == *OFFSET=* ]] && return 0; sleep 2; done
  die "the app could not connect"
}
# start the instance (and the listener) with a given TZ; empty = no TZ, which is UTC in this image
restart_db() {  # restart_db <instance TZ> <listener TZ>
  docker exec "$C" lsnrctl stop >/dev/null
  local o; o=$(printf 'shutdown immediate\nstartup\nexit\n' | docker exec -i -e "TZ=$1" "$C" sqlplus -s / as sysdba)
  [[ "$o" == *"Database opened"* ]] || die "the instance did not open"
  docker exec -e "TZ=$2" "$C" lsnrctl start >/dev/null
  printf 'alter system register;\nexit\n' | run_sys >/dev/null
  wait_app
}
reopen_pdb() {
  printf 'alter pluggable database FREEPDB1 close immediate;\nalter pluggable database FREEPDB1 open;\nalter system register;\nexit\n' \
    | run_sys >/dev/null
  wait_app
}

chicago() { sig "$(app)" CHICAGO; }
expect_offset() {  # expect_offset <label> <clock output> <expected hours>
  local o; o=$(sig "$2" OFFSET)
  printf '   %-44s SYSDATE offset from UTC: %s h\n' "$1" "$o"
  [ "$o" = "$3" ] || die "expected SYSDATE offset $3 for $1, got $o"
}
# a scheduler job, run by a job slave, records SYSDATE's offset from UTC
job_offset() {
  printf "set heading off feedback off pages 0
delete job_probe;
commit;
begin
  dbms_scheduler.create_job(job_name => 'PROBE', job_type => 'PLSQL_BLOCK', enabled => true,
    job_action => 'begin insert into job_probe values (''job'', round((sysdate - cast(sys_extract_utc(systimestamp) as date)) * 24)); commit; end;');
end;
/
exit
" | docker exec -i "$C" sqlplus -s -L "$APP" >/dev/null
  for i in $(seq 1 30); do
    local v; v=$(printf "set heading off feedback off pages 0\nselect 'JOB='||offset_hours from job_probe;\nexit\n" \
      | docker exec -i "$C" sqlplus -s -L "$APP" | grep '^JOB=' || true)
    [ -n "$v" ] && { echo "${v#JOB=}"; return 0; }
    sleep 1
  done
  die "the probe job did not run"
}
expect_job() {
  local j; j=$(job_offset)
  printf '   %-44s SYSDATE offset from UTC: %s h\n' "scheduler job (job slave)" "$j"
  [ "$j" = "$1" ] || die "expected the job to see offset $1, got $j"
}
place_order() {  # place_order <id> <label>: the app inserts, the database fills ORDER_DATE
  printf "insert into orders (id, placed) values (%s, '%s');\ncommit;\nexit\n" "$1" "$2" \
    | docker exec -i "$C" sqlplus -s -L "$APP" >/dev/null
}
orders() {
  printf "set heading off feedback off pages 0 lines 200 tab off
select '   order ' || id || '  ' || rpad(placed, 22) || to_char(order_date, 'YYYY-MM-DD HH24:MI') from orders order by id;
exit
" | docker exec -i "$C" sqlplus -s -L "$APP"
}

cmd_up() { docker compose up -d; wait_healthy; }

cmd_setup() {
  wait_healthy
  docker exec -i "$C" bash -c 'cat > /tmp/clock.sql' < scripts/clock.sql
  docker exec -i "$C" bash -c 'cat > /tmp/jobs.sql' < scripts/jobs.sql
  run_sys < scripts/setup.sql >/dev/null || die "setup.sql failed"
  restart_db "" ""
  local s; s=$(app)
  [ "$(sig "$s" DBTIMEZONE)" = "+00:00" ] || die "expected DBTIMEZONE +00:00 after setup"
  echo ">> Setup done: TZ_APP.ORDERS (ORDER_DATE DEFAULT SYSDATE), two 2am jobs, DBTIMEZONE +00:00."
}

cmd_onprem() {
  echo ">> On-prem: the database server runs in $ZONE."
  restart_db "$ZONE" "$ZONE"
  local s; s=$(app); local ch; ch=$(sig "$s" CHICAGO)
  echo "   app sees: $(printf '%s\n' "$s" | grep '^SYSDATE=')"
  expect_offset "app session (over the listener)" "$s" "$ch"
  expect_job "$ch"
  place_order 1 "on-prem"
}

cmd_move() {
  echo ">> Moved: the same database on a cloud host that runs in UTC. Nothing else changed."
  restart_db "" ""
  local s; s=$(app); local ch; ch=$(sig "$s" CHICAGO)
  echo "   app sees: $(printf '%s\n' "$s" | grep '^SYSDATE=')"
  expect_offset "app session (over the listener)" "$s" 0
  expect_job 0
  place_order 2 "in the cloud"
  echo ">> Two orders, placed seconds apart:"
  orders
  local d; d=$(printf "set heading off feedback off pages 0\nselect 'GAP='||round((max(decode(id,2,order_date)) - max(decode(id,1,order_date))) * 24) from orders;\nexit\n" \
    | docker exec -i "$C" sqlplus -s -L "$APP" | grep '^GAP=' | cut -d= -f2)
  echo "   -> stored $d hours apart. The second one is in UTC, in a column full of Chicago times."
  [ "$d" = "$(( -ch ))" ] || die "expected the orders to be $(( -ch )) hours apart, got $d"
  echo ">> The 2am jobs (next run, Chicago time):"
  local j; j=$(run_sys < scripts/jobs.sql)
  printf '%s\n' "$j" | grep '^NEXT' | sed 's/^/   /'
  [ "$(sig "$j" 'NEXT NIGHTLY_REGION')" = "02:00" ] || die "expected the region-based job to stay at 02:00 Chicago"
  echo "   -> the scheduler stores the time zone with the job: it did not move."
}

cmd_traps() {
  echo ">> Trap 1: set the DATABASE time zone to Chicago."
  pdb "alter database set time_zone = '$ZONE';"
  reopen_pdb
  local s; s=$(app)
  echo "   DBTIMEZONE is now $(sig "$s" DBTIMEZONE)"
  expect_offset "app session" "$s" 0
  echo "   -> DBTIMEZONE is for TIMESTAMP WITH LOCAL TIME ZONE. SYSDATE ignores it."

  echo ">> Trap 2: check it from a DBA shell on the server, with TZ=$ZONE in that shell."
  local b; b=$(printf 'alter session set container = FREEPDB1;\n@/tmp/clock.sql\n' \
    | docker exec -i -e "TZ=$ZONE" "$C" sqlplus -s / as sysdba)
  local ch; ch=$(sig "$b" CHICAGO)
  expect_offset "sqlplus / as sysdba (local, TZ set)" "$b" "$ch"
  expect_offset "app session, same moment" "$(app)" 0
  echo "   -> a local connection's server process takes the TZ of YOUR shell. The app's doesn't."

  echo ">> Trap 3: restart only the listener with TZ=$ZONE."
  docker exec "$C" lsnrctl stop >/dev/null
  docker exec -e "TZ=$ZONE" "$C" lsnrctl start >/dev/null
  printf 'alter system register;\nexit\n' | run_sys >/dev/null
  wait_app
  expect_offset "app session" "$(app)" 0
  echo "   -> on 26ai the app's server process took the instance's TZ, not the listener's."

  echo ">> Trap 4: use CURRENT_DATE instead of SYSDATE."
  local u; u=$(app)
  local c; c=$(sig "$u" CURRENT_DATE_OFFSET)
  printf '   %-44s CURRENT_DATE offset from UTC: %s h\n' "app client with no time zone set" "$c"
  [ "$c" = 0 ] || die "expected CURRENT_DATE in UTC for a UTC client, got $c"
  u=$(app -e "ORA_SDTZ=$ZONE"); c=$(sig "$u" CURRENT_DATE_OFFSET)
  printf '   %-44s CURRENT_DATE offset from UTC: %s h\n' "app client with ORA_SDTZ=$ZONE" "$c"
  [ "$c" = "$ch" ] || die "expected CURRENT_DATE in Chicago with ORA_SDTZ set, got $c"
  echo "   -> CURRENT_DATE follows the CLIENT's time zone. Cloud app servers run in UTC too."

  echo ">> Trap 5: a 2am job stored with a fixed offset (what SYSTIMESTAMP gives: -05:00 in summer)."
  local j; j=$(run_sys < scripts/jobs.sql)
  printf '%s\n' "$j" | grep '^WINTER' | sed 's/^/   after the November DST change, /'
  [ "$(sig "$j" 'WINTER NIGHTLY_OFFSET')" = "01:00" ] || die "expected the fixed-offset job to drift to 01:00"
  [ "$(sig "$j" 'WINTER NIGHTLY_REGION')" = "02:00" ] || die "expected the region job to stay at 02:00"
  echo "   -> use a region name (America/Chicago), never an offset, in START_DATE."
}

cmd_fix_os() {
  echo ">> Fix 1: start the instance with TZ=$ZONE again (the listener stays in UTC)."
  restart_db "$ZONE" ""
  local s; s=$(app); local ch; ch=$(sig "$s" CHICAGO)
  expect_offset "app session" "$s" "$ch"
  expect_job "$ch"
  place_order 3 "after fix 1"
}

cmd_fix_db() {
  echo ">> Fix 2 (26ai): the host stays in UTC; the database answers in its own time zone."
  restart_db "" ""
  expect_offset "app session, before" "$(app)" 0
  echo "   precondition: no data in TIMESTAMP WITH LOCAL TIME ZONE columns."
  local e; e=$(printf "alter session set container = FREEPDB1;
create table tz_app.tsltz_check (c timestamp with local time zone);
insert into tz_app.tsltz_check values (systimestamp);
commit;
alter database set time_zone = 'Europe/London';
drop table tz_app.tsltz_check purge;
exit
" | run_sys | grep -o 'ORA-30079' | head -1 || true)
  echo "   with one row in such a column: ${e:-no error}"
  [ "$e" = ORA-30079 ] || die "expected ORA-30079 while a TSLTZ column holds data"
  pdb "alter database set time_zone = '$ZONE';"
  pdb "alter system set time_at_dbtimezone = user_sql scope = spfile;"
  reopen_pdb
  local s; s=$(app); local ch; ch=$(sig "$s" CHICAGO)
  echo "   app sees: $(printf '%s\n' "$s" | grep '^SYSDATE=')"
  expect_offset "app session, after" "$s" "$ch"
  expect_job "$ch"
  place_order 4 "after fix 2"
  echo ">> All four orders. Order 2 was written in the gap, and it is still wrong:"
  orders
  local d; d=$(printf "set heading off feedback off pages 0\nselect 'GAP='||round((max(decode(id,4,order_date)) - max(decode(id,1,order_date))) * 24) from orders;\nexit\n" \
    | docker exec -i "$C" sqlplus -s -L "$APP" | grep '^GAP=' | cut -d= -f2)
  [ "$d" = 0 ] || die "expected order 4 on Chicago time like order 1, got a $d hour gap"
  echo "   -> new rows are right again; rows from the gap need a one-off correction."
}

case "${1:-}" in
  up) cmd_up ;;
  setup) cmd_setup ;;
  onprem) cmd_onprem ;;
  move) cmd_move ;;
  traps) cmd_traps ;;
  fix_os) cmd_fix_os ;;
  fix_db) cmd_fix_db ;;
  all) cmd_setup; cmd_onprem; cmd_move; cmd_traps; cmd_fix_os; cmd_fix_db; echo ">> All checks passed." ;;
  sql) docker exec -it "$C" sqlplus / as sysdba ;;
  down) docker compose down ;;
  destroy) docker compose down -v ;;
  *) sed -n '2,31p' "$0"; exit 1 ;;
esac
