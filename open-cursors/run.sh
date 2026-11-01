#!/usr/bin/env bash
# Oracle open-cursors lab — driver. Everything runs INSIDE the container via `docker exec`, so you only need Docker.
# Companion to the post on ORA-01000: maximum open cursors exceeded.
#
#   SETUP  : APP schema with ORDERS and two data-access procedures that return a ref cursor (a result set) to the
#            caller. The "app" is SQL*Plus holding each result set in its own REFCURSOR variable: a result set the
#            client never closes, the same thing as a JDBC ResultSet/Statement that is never closed.
#   LEAK   : the app calls GET_ORDERS and never closes the result. Asserted: ORA-01000 at call OPEN_CURSORS-1,
#            the first error names the leaked statement's SQL_ID (26ai), later ones don't, nothing in the alert log.
#   BLAME  : the leak stops just short of the limit, then an unrelated call (GET_CUSTOMER) needs a cursor.
#            Asserted: the unrelated call fails, the message still names the LEAKED statement, and another
#            session running the same call at the same moment is fine (the limit is per session).
#   FIND   : a leaking session and a busy healthy one (SESSION_CACHED_CURSORS 1000) side by side.
#            Asserted: by raw V$OPEN_CURSOR row count the healthy one looks worse (over the 300 limit) while its
#            'opened cursors current' is tiny; filtering CURSOR_TYPE LIKE 'OPEN%' finds the leaked statement.
#   RAISE  : OPEN_CURSORS 300 -> 400 while a session is stuck. Asserted: the stuck session keeps failing, and so
#            does a session connected before the raise (it keeps the old limit, 299);
#            a new session with the same leak fails later, at call 399. The leak is delayed, not fixed.
#   FIX    : the same calls, each result set closed after use. Asserted: 400 calls, no ORA-01000.
#
#   ./run.sh up        # start the database (first run pulls the image)
#   ./run.sh setup     # create the schema (resets the lab; safe to rerun)
#   ./run.sh leak      # never close the result set; ORA-01000 at the limit
#   ./run.sh blame     # an innocent call fails; the message names the leaker
#   ./run.sh find      # find the leaking session and statement (and the false positive)
#   ./run.sh raise     # raise OPEN_CURSORS: stuck sessions stay stuck, new ones fail later
#   ./run.sh fix       # close every result set: no error
#   ./run.sh all       # leak -> blame -> find -> raise -> fix (each starts from setup)
#   ./run.sh sql       # SQL*Plus as SYSDBA
#   ./run.sh down / destroy
set -euo pipefail
cd "$(dirname "$0")"

C=ora-open-cursors-lab
export LAB_PORT="${LAB_PORT:-1521}"
APP="app/App_Passw0rd1@localhost:1521/FREEPDB1"

die() { echo "!! FAIL: $*" >&2; exit 1; }
run_sys() { docker exec -i "$C" sqlplus -s -L "/ as sysdba"; }
pdb() { printf 'whenever sqlerror exit failure\nalter session set container = FREEPDB1;\n%s\nexit\n' "$1" | run_sys >/dev/null \
  || die "failed: $1"; }
sig() { printf '%s\n' "$1" | { grep -E "^$2=" || true; } | head -1 | cut -d= -f2-; }

wait_healthy() {
  echo "Waiting for the database to be ready..."
  for i in $(seq 1 90); do
    if docker exec "$C" healthcheck.sh >/dev/null 2>&1; then echo "Database is ready."; return 0; fi
    sleep 5
  done
  die "timed out waiting for the database"
}

open_cursors() { printf 'set pages 0 feedback off\nalter session set container = FREEPDB1;\nselect value from v$parameter where name = %s;\nexit\n' \
  "'open_cursors'" | run_sys | tr -d ' \t' | grep -E '^[0-9]+$'; }
alert_count() { docker exec "$C" bash -c 'grep -c "ORA-01000" /opt/oracle/diag/rdbms/free/FREE/trace/alert_FREE.log || true'; }

# calls <from> <to> [close]: one GET_ORDERS call per line, each result set in its own variable (never closed),
# or fetched and closed right away with "close" (PRINT reads the result set and closes it)
calls() {
  local i
  for i in $(seq "$1" "$2"); do
    echo "variable rc$i refcursor"
    echo "exec app.get_orders(mod($i,100), :rc$i)"
    [ "${3:-}" = close ] && echo "print rc$i"
  done
  return 0
}
module() { echo "set feedback off"; echo "exec dbms_application_info.set_module('$1', null)"; }
app_sql() { docker exec -i "$C" sqlplus -s -L "$APP" 2>&1 || true; }
# background session: script on stdin, output to /tmp/<name>.out in the container
app_bg() {
  docker exec -i "$C" bash -c "cat > /tmp/$1.sql"
  docker exec "$C" rm -f "/tmp/$1.out"
  docker exec -d "$C" bash -c "sqlplus -s -L $APP @/tmp/$1.sql > /tmp/$1.out 2>&1"
}
wait_for() {  # wait_for <name> <marker>
  for i in $(seq 1 120); do docker exec "$C" grep -q "$2" "/tmp/$1.out" 2>/dev/null && return 0; sleep 1; done
  docker exec "$C" tail -20 "/tmp/$1.out" || true; die "session $1 never printed $2"
}
first_fail() { printf '%s\n' "$1" | grep -B6 'ORA-01000' | grep -m1 -oE 'get_orders\(mod\([0-9]+' | grep -oE '[0-9]+$' || true; }
leaked_id() { sig "$(run_sys < scripts/leaked_sql_id.sql)" SQLID; }

cmd_up() { docker compose up -d; wait_healthy; }

cmd_setup() {
  wait_healthy
  run_sys < scripts/setup.sql >/dev/null || die "setup.sql failed"
  echo "   OPEN_CURSORS = $(open_cursors)"
}

cmd_leak() {
  echo ">> Setup, then the app calls GET_ORDERS 320 times and never closes a result set."
  cmd_setup
  local lim before out ff n id; lim=$(open_cursors); before=$(alert_count)
  out=$( { module leaky-app; calls 1 320; echo exit; } | app_sql)
  ff=$(first_fail "$out"); n=$(printf '%s\n' "$out" | grep -c 'ORA-01000' || true)
  echo "   first ORA-01000 at call $ff (OPEN_CURSORS $lim; the session already had two cursors open)"
  [ "$ff" = "$((lim - 1))" ] || die "expected the first failure at call $((lim - 1)), got '$ff'"
  echo "   calls that failed: $n of 320 (every one after the limit)"
  [ "$n" = "$((320 - lim + 2))" ] || die "expected $((320 - lim + 2)) failures, got $n"
  echo ">> The first error, exactly as the app gets it:"
  printf '%s\n' "$out" | grep -m1 -A1 'ORA-01000' | sed 's/^/   /'
  id=$(leaked_id)
  printf '%s\n' "$out" | grep -A1 'Potential Leaked SQL_ID' | grep -q "$id" || die "first error does not name SQL_ID $id"
  echo "   $id is: $(printf 'set pages 0 feedback off\nalter session set container = FREEPDB1;\nselect sql_text from v$sql where sql_id = %s and rownum = 1;\nexit\n' "'$id'" | run_sys | grep -m1 SELECT)"
  local named; named=$(printf '%s\n' "$out" | grep -c 'Potential Leaked SQL_ID' || true)
  echo "   errors that name a SQL_ID: $named of $n (only the first one in the session)"
  [ "$named" = 1 ] || die "expected exactly one error to name the SQL_ID"
  echo "   ORA-01000 lines added to the alert log: $(( $(alert_count) - before ))"
  [ "$(alert_count)" = "$before" ] || die "expected nothing in the alert log"
  echo "   -> only the application sees ORA-01000; the database logs nothing."
}

cmd_blame() {
  echo ">> The leak stops just short of the limit. Then a different call needs one more cursor."
  cmd_setup
  local lim out id; lim=$(open_cursors)
  { module leaky-app; calls 1 $((lim - 2)); echo "prompt LEAK_READY"
    echo "variable c refcursor"; echo "exec app.get_customer(7, :c)"; echo "prompt CALL_DONE"
    echo "host sleep 20"; echo exit; } | app_bg leaky
  wait_for leaky CALL_DONE
  out=$(docker exec "$C" cat /tmp/leaky.out)
  [ -z "$(first_fail "$out")" ] || die "the leak itself should not have failed yet"
  echo "   $((lim - 2)) leaked GET_ORDERS calls succeeded. The next call, GET_CUSTOMER:"
  printf '%s\n' "$out" | sed -n '/get_customer/,/^Help/p' | grep -E 'ORA-|^[0-9a-z]{13}$' | sed 's/^/   /'
  id=$(leaked_id)
  printf '%s\n' "$out" | grep -q 'get_customer' || die "expected GET_CUSTOMER to fail"
  printf '%s\n' "$out" | grep -A1 'Potential Leaked SQL_ID' | grep -q "$id" \
    || die "expected the error to name the leaked GET_ORDERS statement ($id)"
  echo "   -> GET_CUSTOMER failed, but the SQL_ID in the message ($id) is GET_ORDERS: the leaker."
  out=$( { module healthy-app; echo "variable c refcursor"; echo "exec app.get_customer(7, :c)"; echo "print c"; echo exit; } | app_sql)
  printf '%s\n' "$out" | grep -q 'ORA-' && { printf '%s\n' "$out"; die "the other session failed"; }
  echo "   another session, same call, while the first is still stuck: OK (OPEN_CURSORS is a per-session limit)"
}

cmd_find() {
  echo ">> Two app sessions: one leaking 250 result sets, one busy and healthy with SESSION_CACHED_CURSORS 1000."
  cmd_setup
  { module leaky-app; calls 1 250; echo "prompt LEAK_READY"; echo "host sleep 30"; echo exit; } | app_bg leaky
  { module busy-app; echo "alter session set session_cached_cursors = 1000;"
    for r in 1 2 3 4; do for i in $(seq 1 450); do echo "select count(*) from app.orders where id = $i;"; done; done
    echo "prompt BUSY_READY"; echo "host sleep 30"; echo exit; } | app_bg busy
  wait_for leaky LEAK_READY; wait_for busy BUSY_READY
  local s leak busy lr br
  s=$(run_sys < scripts/sessions.sql)
  echo ">> Per session (as a DBA, from a third session):"
  printf '%s\n' "$s" | grep -E '^(SESS|TYPE)' | sed 's/^/   /'
  leak=$(printf '%s\n' "$s" | grep '^SESS' | grep 'module=leaky-app')
  busy=$(printf '%s\n' "$s" | grep '^SESS' | grep 'module=busy-app')
  lr=$(printf '%s\n' "$busy" | grep -oE 'v\$open_cursor_rows=[0-9]+' | cut -d= -f2)
  br=$(printf '%s\n' "$busy" | grep -oE 'opened_current=[0-9]+' | cut -d= -f2)
  [ "${lr:-0}" -gt "$(open_cursors)" ] || die "expected the healthy session to show more V\$OPEN_CURSOR rows than OPEN_CURSORS"
  [ "${br:-999}" -le 5 ] || die "expected the healthy session to have almost nothing open"
  local lo; lo=$(printf '%s\n' "$leak" | grep -oE 'opened_current=[0-9]+' | cut -d= -f2)
  [ "${lo:-0}" -ge 250 ] || die "expected the leaking session to have 250+ cursors open"
  echo "   -> counting V\$OPEN_CURSOR rows, busy-app ($lr) looks worse than leaky-app. It has $br cursors open:"
  echo "      the rest are closed cursors in the session cursor cache, which don't count toward OPEN_CURSORS."
  echo ">> The statement each session really holds open (CURSOR_TYPE LIKE 'OPEN%'):"
  local t; t=$(run_sys < scripts/top_sql.sql | grep '^TOP')
  printf '%s\n' "$t" | sed 's/^/   /'
  [ "$(printf '%s\n' "$t" | grep -c .)" = 1 ] || die "expected exactly one session to hold a statement open many times"
  [[ "$t" == *"open=250 "*"APP.ORDERS WHERE CUSTOMER_ID"* ]] || die "expected the GET_ORDERS statement open 250 times"
}

cmd_raise() {
  echo ">> A session hits the limit. The DBA raises OPEN_CURSORS to 400 while it is stuck."
  cmd_setup
  { module leaky-app; calls 1 305; echo "prompt STUCK"; echo "host sleep 10"; echo "prompt RESUMED"
    calls 306 360; echo "prompt AFTER_RAISE_DONE"; echo exit; } | app_bg stuck
  # a pooled connection opened before the change, still clean: it starts leaking only after the raise
  { module pooled-app; echo "prompt CONNECTED"; echo "host sleep 12"; echo "prompt LEAKING"; calls 1 420; echo "prompt POOLED_DONE"; echo exit; } \
    | app_bg pooled
  wait_for stuck STUCK; wait_for pooled CONNECTED
  pdb "alter system set open_cursors = 400;"
  echo "   OPEN_CURSORS = $(open_cursors)"
  # the checks below only mean something if the raise landed before either session went on
  docker exec "$C" grep -q '^RESUMED' /tmp/stuck.out && die "the stuck session resumed before the raise (slow runner?)"
  docker exec "$C" grep -q '^LEAKING' /tmp/pooled.out && die "the pooled session started before the raise (slow runner?)"
  wait_for stuck AFTER_RAISE_DONE
  local out ok; out=$(docker exec "$C" sed -n '/^STUCK/,$p' /tmp/stuck.out)
  ok=$(printf '%s\n' "$out" | grep -c 'get_orders(mod(' || true)  # SQL*Plus echoes only the calls that failed
  echo "   the stuck session, 55 more calls after the raise: $ok failed with ORA-01000"
  [ "$ok" = 55 ] || die "expected all 55 calls to keep failing, got $ok"
  wait_for pooled POOLED_DONE
  out=$(docker exec "$C" cat /tmp/pooled.out)
  echo "   a session connected BEFORE the raise, leaking after it: first ORA-01000 at call $(first_fail "$out")"
  [ "$(first_fail "$out")" = 299 ] || die "expected the pre-existing session to keep the old limit (299)"
  out=$( { module leaky-app; calls 1 420; echo exit; } | app_sql)
  echo "   a session connected AFTER the raise, same leak: first ORA-01000 at call $(first_fail "$out")"
  [ "$(first_fail "$out")" = 399 ] || die "expected the new session to fail at call 399"
  echo "   -> the new limit reaches only new connections, and there the leak fails at 399 instead of 299."
  pdb "alter system set open_cursors = 300;"
}

cmd_fix() {
  echo ">> The same 400 calls, each result set read and closed after use."
  cmd_setup
  local out; out=$( { module fixed-app; calls 1 400 close; echo "prompt FIX_DONE"; echo exit; } | app_sql)
  printf '%s\n' "$out" | grep -q FIX_DONE || die "the fixed run did not finish"
  local n; n=$(printf '%s\n' "$out" | grep -c 'ORA-01000' || true)
  echo "   400 calls (OPEN_CURSORS $(open_cursors)): ORA-01000 x$n"
  [ "$n" = 0 ] || die "expected no ORA-01000 when every result set is closed"
}

case "${1:-}" in
  up) cmd_up ;;
  setup) cmd_setup ;;
  leak) cmd_leak ;;
  blame) cmd_blame ;;
  find) cmd_find ;;
  raise) cmd_raise ;;
  fix) cmd_fix ;;
  all) cmd_leak; cmd_blame; cmd_find; cmd_raise; cmd_fix; echo ">> All checks passed." ;;
  sql) docker exec -it "$C" sqlplus / as sysdba ;;
  down) docker compose down ;;
  destroy) docker compose down -v ;;
  *) sed -n '2,31p' "$0"; exit 1 ;;
esac
