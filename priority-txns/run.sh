#!/usr/bin/env bash
# Oracle priority-txns lab — driver. Everything runs INSIDE the container via `docker exec`, so you only need Docker.
# Companion to the post on 26ai priority transactions (TXN_PRIORITY, PRIORITY_TXNS_*_WAIT_TARGET, ORA-63300).
#
#   SETUP    : APP.ORDERS (1,000 rows). Leftover APP sessions are killed, both wait targets go back to the default
#              (2147483647 s = never) and PRIORITY_TXNS_MODE to ROLLBACK, so each drill starts clean.
#              The "blocker" updates a row, then sits idle without committing (a batch that paused, a forgotten
#              SQL Developer window). The "waiter" is a normal session that wants the same row.
#   OFF      : blocker LOW, waiter HIGH, wait targets at the default. Asserted: nothing is rolled back; the waiter
#              waits until the blocker commits. Marking a session LOW does nothing on its own.
#   ROLLBACK : PRIORITY_TXNS_HIGH_WAIT_TARGET = 10. Asserted: the waiter gets its row after ~10 s (wait event
#              "enq: TX - row lock (HIGH priority)"); the idle blocker learns only on its NEXT statement
#              (ORA-63302 + ORA-63300); every statement after that, COMMIT included, fails with ORA-63302 until it
#              issues ROLLBACK; its whole transaction is gone (a second row it changed is back to NEW); the alert
#              log names both sessions; V$SYSSTAT "txns rollback priority_txns_high_wait_target" goes up by 1.
#   ACTIVE   : the blocker is still running (a PL/SQL block that sleeps after its update). Asserted: the running
#              call is interrupted with ORA-63300 at the wait target, it doesn't finish its work.
#   RULES    : who can roll back whom. Asserted: HIGH vs HIGH (the default for everyone) and LOW vs LOW: no
#              rollback; HIGH waiter vs MEDIUM blocker: rollback at the HIGH target; MEDIUM waiter vs LOW blocker:
#              no rollback until PRIORITY_TXNS_MEDIUM_WAIT_TARGET is set too, then rollback at that target (5 s).
#   DDL      : the waiter is DDL. Asserted: ALTER TABLE ADD COLUMN (which waits for row locks) rolls the LOW
#              blocker back at the target and runs; TRUNCATE still fails at once with ORA-00054; LOCK TABLE
#              (a table lock, not a row lock) just waits for the commit. Only row-lock waits count.
#   TRACK    : PRIORITY_TXNS_MODE = TRACK. Asserted: nothing is rolled back, the waiter waits for the commit, and
#              "txns track mode priority_txns_high_wait_target" counts the rollback that would have happened.
#   LIMITS   : Asserted: TXN_PRIORITY can't change inside an open transaction (ORA-63304), and an Oracle
#              Scheduler job can't set it at all (ORA-63303), so scheduler jobs always run at HIGH.
#
#   ./run.sh up        # start the database (first run pulls the image)
#   ./run.sh setup     # create the schema and reset the parameters (safe to rerun)
#   ./run.sh off | rollback | active | rules | ddl | track | limits
#   ./run.sh all       # every drill, each from setup
#   ./run.sh sql       # SQL*Plus as SYSDBA
#   ./run.sh down / destroy
set -euo pipefail
cd "$(dirname "$0")"

C=ora-priority-txns-lab
export LAB_PORT="${LAB_PORT:-1521}"
APP="app/App_Passw0rd1@localhost:1521/FREEPDB1"
HOLD=25    # how long the blocker sits on its row before it tries to commit
TARGET=10  # PRIORITY_TXNS_HIGH_WAIT_TARGET used by the drills

die() { echo "!! FAIL: $*" >&2; exit 1; }
run_sys() { docker exec -i "$C" sqlplus -s -L "/ as sysdba"; }
# pdb_val <statement>: run in FREEPDB1 as SYS, print the first non-empty line of output
pdb_val() { printf 'set pages 0 feedback off heading off lines 300\nalter session set container = FREEPDB1;\n%s\nexit\n' "$1" | run_sys \
  | sed 's/^[ \t]*//;s/[ \t\r]*$//' | grep -v '^$' | grep -v '^Session altered' | head -1 || true; }
sig() { printf '%s\n' "$1" | { grep -E "^$2=" || true; } | head -1 | cut -d= -f2-; }
param() { pdb_val "alter system set $1 = $2;" >/dev/null; [ "$(pdb_val "select upper(value) from v\$parameter where name = '$1';")" = "$2" ] || die "could not set $1 = $2"; }
stat() { pdb_val "select value from v\$sysstat where name = '$1';"; }
alert_hits() { docker exec "$C" bash -c 'grep -c "terminated by transaction" /opt/oracle/diag/rdbms/free/FREE/trace/alert_FREE.log || true'; }

wait_healthy() {
  echo "Waiting for the database to be ready..."
  for i in $(seq 1 90); do
    if docker exec "$C" healthcheck.sh >/dev/null 2>&1; then echo "Database is ready."; return 0; fi
    sleep 5
  done
  die "timed out waiting for the database"
}

app_sql() { docker exec -i "$C" sqlplus -s -L "$APP" 2>&1 || true; }
# bg <name>: run the script on stdin as APP in the background; output and elapsed seconds in /tmp/<name>.out
bg() {
  docker exec -i "$C" bash -c "cat > /tmp/$1.sql; rm -f /tmp/$1.out"
  docker exec -d "$C" bash -c "s=\$(date +%s); sqlplus -s -L $APP @/tmp/$1.sql > /tmp/$1.out 2>&1; echo ELAPSED=\$(( \$(date +%s) - s )) >> /tmp/$1.out"
}
out() { docker exec "$C" cat "/tmp/$1.out" 2>/dev/null || true; }
wait_for() {  # wait_for <name> <marker> [seconds]
  for i in $(seq 1 "${3:-120}"); do docker exec "$C" grep -q "$2" "/tmp/$1.out" 2>/dev/null && return 0; sleep 1; done
  out "$1" | tail -20; die "session $1 never printed $2"
}
done_in() { wait_for "$1" ELAPSED "${2:-120}"; sig "$(out "$1")" ELAPSED; }
first() { out "$1" | grep -m1 -oE "$2" || true; }

# blocker <priority>: update rows 1 and 500, sit idle for $HOLD s, then try to go on and commit
blocker() {
  cat <<EOF | bg blocker
set feedback on heading off pages 0
alter session set txn_priority = $1;
select 'SID='||sys_context('userenv','sid') from dual;
update orders set status = 'BATCH' where id in (1, 500);
host sleep $HOLD
select 'NEXT_STATEMENT' from dual;
commit;
select 'AFTER_COMMIT' from dual;
rollback;
select 'AFTER_ROLLBACK' from dual;
exit
EOF
  wait_for blocker 'SID=' 60; sleep 2
}
# waiter <priority> <statement>: the session that wants row 1
waiter() { printf "set feedback on heading off pages 0\nalter session set txn_priority = %s;\nselect 'SID='||sys_context('userenv','sid') from dual;\n%s;\ncommit;\nexit\n" "$1" "$2" | bg waiter; }
UPD="update orders set status = 'PAID' where id = 1"
rolled_back() { out blocker | grep -q 'ORA-63300'; }

cmd_up() { docker compose up -d; wait_healthy; }

cmd_setup() {
  wait_healthy
  pdb_val "begin for s in (select sid, serial# from v\$session where username = 'APP') loop
    execute immediate 'alter system kill session ''' || s.sid || ',' || s.serial# || ''' immediate'; end loop; end;
/" >/dev/null
  for i in $(seq 1 30); do [ "$(pdb_val "select count(*) from v\$session where username = 'APP';")" = 0 ] && break; sleep 1; done
  param priority_txns_high_wait_target 2147483647
  param priority_txns_medium_wait_target 2147483647
  param priority_txns_mode ROLLBACK
  app_sql >/dev/null <<'EOF'
whenever sqlerror continue
drop table orders purge;
whenever sqlerror exit failure
create table orders (id number primary key, status varchar2(10), amount number);
insert into orders select level, 'NEW', level from dual connect by level <= 1000;
commit;
EOF
  [ "$(pdb_val "select count(*) from app.orders;")" = 1000 ] || die "setup did not create APP.ORDERS"
}

# pair <blocker prio> <waiter prio> <statement> : run one blocker/waiter pair; sets W (waiter s) and R (rolled back yes/no)
pair() {
  blocker "$1"; waiter "$2" "$3"
  W=$(done_in waiter 90); done_in blocker 90 >/dev/null
  R=no; if rolled_back; then R=yes; fi
}

cmd_off() {
  echo ">> OFF: blocker LOW, waiter HIGH, wait targets at the default (2147483647 s)."
  cmd_setup
  pair LOW HIGH "$UPD"
  echo "   waiter got row 1 after ${W}s; blocker rolled back: $R; blocker's COMMIT: $(first blocker 'Commit complete|ORA-6330[0-9]')"
  [ "$R" = no ] && [ "$W" -ge $((HOLD - 5)) ] || die "expected no rollback and a wait for the commit (waited ${W}s, rolled back $R)"
  echo "   -> LOW on its own changes nothing: without a wait target the waiter waits for the commit, as before 26ai."
}

cmd_rollback() {
  echo ">> ROLLBACK: PRIORITY_TXNS_HIGH_WAIT_TARGET = $TARGET; blocker LOW (idle, rows 1 and 500), waiter HIGH."
  cmd_setup
  param priority_txns_high_wait_target $TARGET
  local s0 a0 ev wsid
  s0=$(stat 'txns rollback priority_txns_high_wait_target'); a0=$(alert_hits)
  blocker LOW; waiter HIGH "$UPD"
  sleep 4
  wsid=$(sig "$(out waiter)" SID)
  ev=$(pdb_val "select event from v\$session where sid = $wsid;")
  echo "   waiter (SID $wsid) is waiting on: $ev"
  [ "$ev" = "enq: TX - row lock (HIGH priority)" ] || die "expected the HIGH priority row-lock wait, got '$ev'"
  W=$(done_in waiter 90); done_in blocker 90 >/dev/null
  echo "   waiter got row 1 after ${W}s"
  [ "$W" -ge $((TARGET - 2)) ] && [ "$W" -le $((TARGET + 4)) ] || die "expected the waiter to get the row after ~${TARGET}s, took ${W}s"
  echo "   blocker, $HOLD s later, on its next statements:"
  out blocker | grep -E '^ORA-6330|Rollback complete|AFTER_ROLLBACK' | sed 's/^/     /'
  out blocker | sed -n '/NEXT_STATEMENT/,/ORA-63300/p' | grep -q 'ORA-63302' || die "expected ORA-63302 on the next statement"
  rolled_back || die "expected ORA-63300 in the blocker's output"
  [ "$(out blocker | grep -c 'ORA-63302')" -ge 3 ] || die "expected ORA-63302 for every statement until ROLLBACK (COMMIT included)"
  out blocker | grep -q 'Commit complete' && die "COMMIT should not succeed after the automatic rollback"
  out blocker | grep -q AFTER_ROLLBACK || die "expected the session to work again after ROLLBACK"
  local r1 r500; r1=$(pdb_val "select status from app.orders where id = 1;"); r500=$(pdb_val "select status from app.orders where id = 500;")
  echo "   row 1 = $r1 (the waiter's change), row 500 = $r500 (the blocker had set it to BATCH)"
  [ "$r1" = PAID ] && [ "$r500" = NEW ] || die "expected row 1 PAID and row 500 NEW, got $r1 / $r500"
  local s1 a1; s1=$(stat 'txns rollback priority_txns_high_wait_target'); a1=$(alert_hits)
  echo "   V\$SYSSTAT txns rollback priority_txns_high_wait_target: $s0 -> $s1; alert log:"
  docker exec "$C" bash -c 'grep "terminated by transaction" /opt/oracle/diag/rdbms/free/FREE/trace/alert_FREE.log | tail -1' | fold -w 110 | sed 's/^/     /'
  [ "$s1" -eq $((s0 + 1)) ] || die "expected the rollback statistic to go up by 1"
  [ "$a1" -eq $((a0 + 1)) ] || die "expected one new 'terminated by transaction' line in the alert log"
  echo "   -> the whole LOW transaction is rolled back, and an idle session only finds out when it next talks to the database."
}

cmd_active() {
  echo ">> ACTIVE: the LOW blocker is still running (PL/SQL that sleeps 30 s after its update); target $TARGET s."
  cmd_setup
  param priority_txns_high_wait_target $TARGET
  cat <<'EOF' | bg blocker
set feedback on heading off pages 0
alter session set txn_priority = LOW;
begin
  update orders set status = 'BATCH' where id = 1;
  dbms_session.sleep(30);
  update orders set status = 'BATCH' where id = 500;
end;
/
rollback;
exit
EOF
  sleep 2; waiter HIGH "$UPD"
  W=$(done_in waiter 60); local b; b=$(done_in blocker 60)
  echo "   waiter got the row after ${W}s; the blocker's PL/SQL call ended after ${b}s with:"
  out blocker | grep -E '^ORA-6330[0-9]' | head -2 | sed 's/^/     /'
  rolled_back || die "expected ORA-63300 in the running call"
  [ "$b" -le $((TARGET + 6)) ] || die "expected the running call to be interrupted near ${TARGET}s, it ran ${b}s"
  [ "$(pdb_val "select status from app.orders where id = 500;")" = NEW ] || die "the interrupted block should not have reached row 500"
  echo "   -> a running statement is interrupted at the target; it doesn't get to finish."
}

cmd_rules() {
  echo ">> RULES: who can roll back whom (HIGH target $TARGET s; blocker holds its row ${HOLD}s)."
  local b w med
  for spec in "HIGH HIGH unset no" "LOW LOW unset no" "MEDIUM HIGH unset yes" "LOW MEDIUM unset no" "LOW MEDIUM 5 yes"; do
    set -- $spec; b=$1; w=$2; med=$3
    cmd_setup >/dev/null
    param priority_txns_high_wait_target $TARGET
    [ "$med" = unset ] || param priority_txns_medium_wait_target "$med"
    pair "$b" "$w" "$UPD"
    printf '   blocker %-6s waiter %-6s medium target %-5s -> rolled back: %-3s waiter waited %ss\n' "$b" "$w" "$med" "$R" "$W"
    [ "$R" = "$4" ] || die "expected rolled back = $4 for $b vs $w"
    if [ "$R" = yes ]; then
      local t=$TARGET; [ "$w" = MEDIUM ] && t=$med
      [ "$W" -ge $((t - 2)) ] && [ "$W" -le $((t + 4)) ] || die "expected the waiter to get the row after ~${t}s, took ${W}s"
    else
      [ "$W" -ge $((HOLD - 5)) ] || die "expected the waiter to wait for the commit, took ${W}s"
    fi
  done
  echo "   -> only a higher priority waiter rolls back, only after its own target; everyone is HIGH unless told otherwise."
}

cmd_ddl() {
  echo ">> DDL: the HIGH waiter is DDL; the LOW blocker holds row 1; target $TARGET s."
  local stmt r
  for stmt in "alter table orders add (note varchar2(10))" "truncate table orders" "lock table orders in exclusive mode"; do
    cmd_setup >/dev/null
    param priority_txns_high_wait_target $TARGET
    pair LOW HIGH "$stmt"
    r=$(first waiter 'ORA-[0-9]+|Table altered|Table truncated|Table\(s\) Locked')
    printf '   %-42s %-16s after %3ss; blocker rolled back: %s\n' "$stmt" "$r" "$W" "$R"
    case "$stmt" in
      *add*)  [ "$r" = "Table altered" ] && [ "$R" = yes ] && [ "$W" -le $((TARGET + 4)) ] || die "expected ADD COLUMN to roll the blocker back and run" ;;
      trunc*) [ "$r" = ORA-00054 ] && [ "$R" = no ] && [ "$W" -le 3 ] || die "expected TRUNCATE to fail at once with ORA-00054" ;;
      lock*)  [ "$R" = no ] && [ "$W" -ge $((HOLD - 5)) ] || die "expected LOCK TABLE to wait for the commit" ;;
    esac
  done
  echo "   -> only waits for a ROW lock count: DDL that waits (ADD COLUMN) benefits, DDL that fails at once and table locks don't."
}

cmd_track() {
  echo ">> TRACK: PRIORITY_TXNS_MODE = TRACK, target $TARGET s, blocker LOW, waiter HIGH."
  cmd_setup
  param priority_txns_high_wait_target $TARGET
  param priority_txns_mode TRACK
  local t0 t1; t0=$(stat 'txns track mode priority_txns_high_wait_target')
  pair LOW HIGH "$UPD"
  t1=$(stat 'txns track mode priority_txns_high_wait_target')
  echo "   rolled back: $R; waiter waited ${W}s; txns track mode priority_txns_high_wait_target: $t0 -> $t1"
  [ "$R" = no ] && [ "$W" -ge $((HOLD - 5)) ] || die "expected TRACK to roll nothing back"
  [ "$t1" -eq $((t0 + 1)) ] || die "expected the TRACK statistic to go up by 1"
  param priority_txns_mode ROLLBACK
  echo "   -> TRACK counts the rollbacks you would get; run it first to choose the target."
}

cmd_limits() {
  echo ">> LIMITS: where TXN_PRIORITY can't be set."
  cmd_setup
  local e
  e=$(printf "update orders set status = 'Y' where id = 5;\nalter session set txn_priority = LOW;\nrollback;\nexit\n" | app_sql | grep -m1 -oE 'ORA-63304' || true)
  echo "   ALTER SESSION SET txn_priority inside an open transaction: $e"
  [ "$e" = ORA-63304 ] || die "expected ORA-63304"
  pdb_val "grant create job to app;" >/dev/null
  app_sql >/dev/null <<'EOF'
whenever sqlerror continue
drop table joblog purge;
create table joblog (msg varchar2(4000));
begin
  dbms_scheduler.create_job(job_name => 'SET_PRIORITY_JOB', job_type => 'PLSQL_BLOCK', enabled => true, auto_drop => true,
    job_action => 'declare m varchar2(4000); begin execute immediate ''alter session set txn_priority = LOW''; insert into joblog values (''SET OK''); commit; exception when others then m := dbms_utility.format_error_stack; insert into joblog values (m); commit; end;');
end;
/
exit
EOF
  for i in $(seq 1 30); do e=$(pdb_val "select count(*) from app.joblog;"); [ "$e" -ge 1 ] && break; sleep 1; done
  e=$(pdb_val "select regexp_substr(msg, 'ORA-63303|SET OK') from app.joblog;")
  echo "   ALTER SESSION SET txn_priority inside a DBMS_SCHEDULER job: $e"
  [ "$e" = ORA-63303 ] || die "expected ORA-63303 from the scheduler job, got '$e'"
  echo "   -> set the priority before the transaction starts, from a client session; scheduler jobs stay HIGH."
}

case "${1:-}" in
  up) cmd_up ;;
  setup) cmd_setup; echo "Schema ready." ;;
  off) cmd_off ;; rollback) cmd_rollback ;; active) cmd_active ;; rules) cmd_rules ;; ddl) cmd_ddl ;; track) cmd_track ;; limits) cmd_limits ;;
  all) cmd_off; cmd_rollback; cmd_active; cmd_rules; cmd_ddl; cmd_track; cmd_limits; cmd_setup >/dev/null; echo ">> All checks passed." ;;
  sql) docker exec -it "$C" sqlplus / as sysdba ;;
  down) docker compose down ;;
  destroy) docker compose down -v ;;
  *) sed -n '2,37p' "$0"; exit 1 ;;
esac
