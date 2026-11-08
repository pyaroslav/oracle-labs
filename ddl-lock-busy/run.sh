#!/usr/bin/env bash
# Oracle ddl-lock-busy lab — driver. Everything runs INSIDE the container via `docker exec`, so you only need Docker.
# Companion to the post on ORA-00054: resource busy.
#
#   SETUP  : APP.ORDERS (1,000 rows, an index on AMOUNT). Leftover APP sessions are killed so each drill starts clean.
#            The "blocker" is a session that updates one row and then sits idle without committing: an application
#            that forgot to commit, a SQL Developer window left open, a pooled connection with an open transaction.
#   BUSY   : TRUNCATE while the blocker holds its row. Asserted: ORA-00054 at once, and the object number in the
#            26ai message is ORDERS' OBJECT_ID. The message doesn't name the session.
#   FIND   : from that object number to the session. Asserted: V$LOCKED_OBJECT finds exactly the blocker's SID,
#            INACTIVE, with an open transaction in V$TRANSACTION; and BLOCKING_SESSION is empty (nothing is waiting).
#   KINDS  : two kinds of blocked DDL, all with DDL_LOCK_TIMEOUT = 5. Asserted: CREATE INDEX gives up with ORA-00054
#            after the 5 s; ADD COLUMN and CREATE INDEX ONLINE don't fail, they wait until the blocker commits, and show the blocker in
#            BLOCKING_SESSION while they wait; another session's UPDATE runs at once while they wait.
#   QUEUE  : DROP COLUMN with DDL_LOCK_TIMEOUT = 30 while the blocker holds its row for 45 s. Asserted: another
#            session's UPDATE of a DIFFERENT row waits behind the DDL (BLOCKING_SESSION = the DDL session,
#            FINAL_BLOCKING_SESSION = the blocker) for 20 s or more, and the DDL still ends in ORA-00054.
#   SUPLOG : the same ADD COLUMN after ALTER DATABASE ADD SUPPLEMENTAL LOG DATA (what GoldenGate, LogMiner-based
#            tools and logical standby turn on). Asserted: ADD COLUMN now fails at once with ORA-00054 (nonblocking
#            DDL is downgraded to blocking), while CREATE INDEX ONLINE still waits. Supplemental logging is turned
#            off again afterwards (setup also turns it off).
#   FIX    : end the idle session (ALTER SYSTEM KILL SESSION). Asserted: the DDL then runs, and the blocker's
#            uncommitted change is rolled back.
#
#   ./run.sh up        # start the database (first run pulls the image)
#   ./run.sh setup     # create the schema (resets the lab; safe to rerun)
#   ./run.sh busy      # ORA-00054, and what the message tells you
#   ./run.sh find      # find the session from the message
#   ./run.sh kinds     # DDL that fails at once vs DDL that waits
#   ./run.sh queue     # DDL_LOCK_TIMEOUT makes everyone else's writes wait
#   ./run.sh suplog    # supplemental logging turns ADD COLUMN back into ORA-00054
#   ./run.sh fix       # end the idle session; the DDL runs
#   ./run.sh all       # busy -> find -> kinds -> queue -> suplog -> fix (each starts from setup)
#   ./run.sh sql       # SQL*Plus as SYSDBA
#   ./run.sh down / destroy
set -euo pipefail
cd "$(dirname "$0")"

C=ora-ddl-lock-busy-lab
export LAB_PORT="${LAB_PORT:-1521}"
APP="app/App_Passw0rd1@localhost:1521/FREEPDB1"
SIDQ=$'select \'SID=\'||sys_context(\'userenv\',\'sid\') from dual;\n'

die() { echo "!! FAIL: $*" >&2; exit 1; }
run_sys() { docker exec -i "$C" sqlplus -s -L "/ as sysdba"; }
# pdb_val <query>: one value from the PDB as SYS
pdb_val() { printf 'set pages 0 feedback off heading off\nalter session set container = FREEPDB1;\n%s\nexit\n' "$1" | run_sys \
  | tr -d ' \t\r' | grep -v '^$' | grep -v '^Session' | head -1 || true; }
sig() { printf '%s\n' "$1" | { grep -E "^$2=" || true; } | head -1 | cut -d= -f2-; }

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

# blocker <seconds>: update row 1, print the SID, sit idle without committing, then commit
blocker() {
  printf "set feedback off heading off pages 0\nselect 'SID='||sys_context('userenv','sid') from dual;\nupdate orders set status = 'PAID' where id = 1;\nhost sleep %s\ncommit;\nselect 'COMMITTED' from dual;\nexit\n" "$1" | bg blocker
  wait_for blocker 'SID=' 60; sleep 2
  sig "$(out blocker)" SID
}
ddl_bg() {  # ddl_bg <name> <ddl_lock_timeout> <statement>
  printf "set feedback off heading off pages 0\n%sset feedback on\nalter session set ddl_lock_timeout = %s;\n%s;\nexit\n" \
    "$SIDQ" "$2" "$3" | bg "$1"
}
writer_bg() { printf "set feedback off heading off pages 0\n%sset feedback on\nupdate orders set status = 'SHIPPED' where id = 2;\ncommit;\nexit\n" "$SIDQ" | bg writer; }
sid_of() { wait_for "$1" 'SID=' 30; sig "$(out "$1")" SID; }
col_of() { pdb_val "select nvl(to_char($2), '-') from v\$session where sid = $1;"; }

cmd_up() { docker compose up -d; wait_healthy; }

suplog() {  # suplog <on|off>: database-level minimal supplemental logging (set in the CDB root)
  local verb=drop; [ "$1" = on ] && verb=add
  printf 'whenever sqlerror continue\nalter database %s supplemental log data;\nexit\n' "$verb" | run_sys >/dev/null
  printf 'set pages 0 feedback off heading off\nselect supplemental_log_data_min from v$database;\nexit\n' | run_sys | tr -d ' \r' | grep -v '^$'
}

cmd_setup() {
  wait_healthy
  [ "$(suplog off)" = NO ] || die "could not turn supplemental logging off"
  pdb_val "begin for s in (select sid, serial# from v\$session where username = 'APP') loop
    execute immediate 'alter system kill session ''' || s.sid || ',' || s.serial# || ''' immediate'; end loop; end;
/" >/dev/null
  for i in $(seq 1 30); do [ "$(pdb_val "select count(*) from v\$session where username = 'APP';")" = 0 ] && break; sleep 1; done
  app_sql >/dev/null <<'EOF'
whenever sqlerror continue
drop table orders purge;
whenever sqlerror exit failure
create table orders (id number primary key, status varchar2(10), amount number);
insert into orders select level, 'NEW', level from dual connect by level <= 1000;
create index orders_amount_ix on orders(amount);
commit;
EOF
  [ "$(pdb_val "select count(*) from app.orders;")" = 1000 ] || die "setup did not create APP.ORDERS"
}

cmd_busy() {
  echo ">> BUSY: TRUNCATE while another session has an uncommitted change to one row."
  cmd_setup
  local b msg oid
  b=$(blocker 40)
  msg=$(printf 'truncate table orders;\nexit\n' | app_sql)
  printf '%s\n' "$msg" | grep -q 'ORA-00054' || die "expected ORA-00054, got: $msg"
  echo "   TRUNCATE failed at once:"
  printf '%s\n' "$msg" | sed -n '/ORA-00054/,/operation/p' | sed 's/^/     /'
  oid=$(pdb_val "select object_id from dba_objects where owner = 'APP' and object_name = 'ORDERS';")
  printf '%s\n' "$msg" | tr '\n' ' ' | grep -q "by $oid (\"Table\")" || die "expected object $oid in the message"
  echo "   the number in the message, $oid, is APP.ORDERS' OBJECT_ID; the blocking session (SID $b) isn't named."
  wait_for blocker COMMITTED 60
}

cmd_find() {
  echo ">> FIND: from the object number in the message to the session holding the lock."
  cmd_setup
  local b oid found status tx bs
  b=$(blocker 40)
  oid=$(pdb_val "select object_id from dba_objects where owner = 'APP' and object_name = 'ORDERS';")
  echo "   select session_id, locked_mode from v\$locked_object where object_id = $oid;"
  found=$(pdb_val "select listagg(session_id || ':' || locked_mode, ',') from v\$locked_object where object_id = $oid;")
  echo "   -> $found   (mode 3 = row exclusive: an open DML transaction)"
  [ "$found" = "$b:3" ] || die "expected exactly the blocker $b in mode 3, got $found"
  status=$(col_of "$b" status)
  tx=$(pdb_val "select count(*) from v\$session s join v\$transaction t on t.addr = s.taddr where s.sid = $b;")
  bs=$(pdb_val "select count(*) from v\$session where username = 'APP' and blocking_session is not null;")
  echo "   session $b: $status, open transactions: $tx, sessions waiting on anyone: $bs"
  [ "$status" = INACTIVE ] || die "expected the blocker to be INACTIVE, got $status"
  [ "$tx" = 1 ] || die "expected an open transaction for session $b"
  [ "$bs" = 0 ] || die "expected no session with BLOCKING_SESSION set"
  echo "   -> an idle session with an open transaction; nothing is waiting on it, so BLOCKING_SESSION is empty everywhere."
  wait_for blocker COMMITTED 60
}

cmd_kinds() {
  echo ">> KINDS: which DDL gives up, and which waits. DDL_LOCK_TIMEOUT = 5 for all three; the blocker commits after 30s."
  local stmt b e r ses bs w
  for stmt in "create index orders_status_ix on orders(status)" \
              "alter table orders add (note varchar2(100))" \
              "create index orders_status_ix on orders(status) online"; do
    cmd_setup >/dev/null
    b=$(blocker 30)
    ddl_bg ddl 5 "$stmt"
    sleep 6
    ses=$(sid_of ddl); bs=$(col_of "$ses" blocking_session)
    writer_bg; w=$(done_in writer 20)
    e=$(done_in ddl 60)
    r=$(out ddl | grep -m1 -oE 'ORA-00054|Index created|Table altered' || true)
    printf '   %-56s %-16s after %ss' "$stmt" "$r" "$e"
    if [ "$r" = ORA-00054 ]; then
      echo
      [ "$e" -ge 4 ] && [ "$e" -le 9 ] || die "expected ORA-00054 after the 5s DDL_LOCK_TIMEOUT, took ${e}s"
    else
      echo "  (blocking_session $bs; another session's UPDATE took ${w}s)"
      [ "$e" -ge 25 ] || die "expected '$stmt' to wait for the commit, took ${e}s"
      [ "$bs" = "$b" ] || die "expected BLOCKING_SESSION = $b while it waited, got $bs"
      [ "$w" -le 3 ] || die "expected other DML to run while it waited, took ${w}s"
    fi
    case "$stmt" in *online*|*add*) [ "$r" != ORA-00054 ] || die "expected '$stmt' to wait, not fail";;
                    *) [ "$r" = ORA-00054 ] || die "expected '$stmt' to fail at once";; esac
    wait_for blocker COMMITTED 60
  done
  echo "   -> the waiting kind ignores DDL_LOCK_TIMEOUT and waits as long as the transaction stays open."
}

cmd_queue() {
  echo ">> QUEUE: DROP COLUMN with DDL_LOCK_TIMEOUT = 30; the blocker keeps its row for 45s."
  cmd_setup
  local b d bs fbs w e
  b=$(blocker 45)
  ddl_bg ddl 30 "alter table orders drop column amount"
  sleep 3
  writer_bg
  sleep 4
  d=$(sid_of ddl)
  local wsid; wsid=$(sid_of writer)
  bs=$(col_of "$wsid" blocking_session); fbs=$(col_of "$wsid" final_blocking_session)
  echo "   the UPDATE of row 2 (session $wsid): blocking_session $bs, final_blocking_session $fbs (DDL $d, blocker $b)"
  [ -n "$d" ] && [ "$bs" = "$d" ] || die "expected the UPDATE to wait on the DDL session $d, got $bs"
  [ "$fbs" = "$b" ] || die "expected the final blocker to be $b, got $fbs"
  e=$(done_in ddl 60); w=$(done_in writer 60)
  out ddl | grep -q ORA-00054 || die "expected the DDL to time out with ORA-00054: $(out ddl)"
  echo "   DROP COLUMN: ORA-00054 after ${e}s;  the UPDATE of a different row waited ${w}s"
  [ "$w" -ge 20 ] || die "expected the UPDATE to wait 20s or more behind the DDL, waited ${w}s"
  echo "   -> while the DDL waited for its lock, every new write to the table waited behind it, and it failed anyway."
  wait_for blocker COMMITTED 60
}

cmd_suplog() {
  echo ">> SUPLOG: database-level supplemental logging on (as for GoldenGate or LogMiner), then the same DDL."
  cmd_setup
  local b r e stmt
  trap 'suplog off >/dev/null' EXIT
  [ "$(suplog on)" = YES ] || die "could not turn supplemental logging on"
  for stmt in "alter table orders add (note varchar2(100))" "create index orders_status_ix on orders(status) online"; do
    cmd_setup >/dev/null; suplog on >/dev/null
    b=$(blocker 25)
    ddl_bg ddl 0 "$stmt"
    e=$(done_in ddl 60)
    r=$(out ddl | grep -m1 -oE 'ORA-00054|Index created|Table altered' || true)
    printf '   %-56s %-16s after %ss\n' "$stmt" "$r" "$e"
    case "$stmt" in
      *online*) [ "$r" = "Index created" ] && [ "$e" -ge 15 ] || die "expected CREATE INDEX ONLINE to keep waiting" ;;
      *) [ "$r" = ORA-00054 ] && [ "$e" -le 3 ] || die "expected ADD COLUMN to fail at once with supplemental logging" ;;
    esac
    wait_for blocker COMMITTED 60
  done
  [ "$(suplog off)" = NO ] || die "could not turn supplemental logging off"
  trap - EXIT
  echo "   -> with supplemental logging, ADD COLUMN is blocking DDL again: the deploy that waited elsewhere fails here."
}

cmd_fix() {
  echo ">> FIX: end the idle session, then run the DDL."
  cmd_setup
  local b serial r
  b=$(blocker 120)
  serial=$(pdb_val "select serial# from v\$session where sid = $b;")
  pdb_val "alter system kill session '$b,$serial' immediate;" >/dev/null
  for i in $(seq 1 30); do [ "$(pdb_val "select count(*) from v\$session where sid = $b and serial# = $serial;")" = 0 ] && break; sleep 1; done
  r=$(printf 'truncate table orders;\nexit\n' | app_sql | grep -m1 -oE 'ORA-[0-9]+|Table truncated' || true)
  echo "   killed session $b,$serial; TRUNCATE: $r"
  [ "$r" = "Table truncated" ] || die "expected the TRUNCATE to run after the kill, got $r"
  cmd_setup >/dev/null
  b=$(blocker 120)
  serial=$(pdb_val "select serial# from v\$session where sid = $b;")
  pdb_val "alter system kill session '$b,$serial' immediate;" >/dev/null
  for i in $(seq 1 30); do [ "$(pdb_val "select count(*) from v\$session where sid = $b and serial# = $serial;")" = 0 ] && break; sleep 1; done
  r=$(pdb_val "select status from app.orders where id = 1;")
  echo "   row 1 after the kill: $r (the blocker had set it to PAID, uncommitted)"
  [ "$r" = NEW ] || die "expected the killed session's change to be rolled back, got $r"
  echo "   -> killing the session rolls its transaction back. Find out what it was doing first."
}

case "${1:-}" in
  up) cmd_up ;;
  setup) cmd_setup; echo "Schema ready." ;;
  busy) cmd_busy ;; find) cmd_find ;; kinds) cmd_kinds ;; queue) cmd_queue ;; suplog) cmd_suplog ;; fix) cmd_fix ;;
  all) cmd_busy; cmd_find; cmd_kinds; cmd_queue; cmd_suplog; cmd_fix; echo ">> All checks passed." ;;
  sql) docker exec -it "$C" sqlplus / as sysdba ;;
  down) docker compose down ;;
  destroy) docker compose down -v ;;
  *) sed -n '2,36p' "$0"; exit 1 ;;
esac
