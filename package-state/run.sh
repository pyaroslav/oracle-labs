#!/usr/bin/env bash
# Oracle package-state lab — driver. Everything runs INSIDE the container via `docker exec`, so you only need Docker.
# Companion to the post on ORA-04068: existing state of packages has been discarded.
#
#   SETUP  : APP.ORDERS (1,000 rows) and PRICING, a package with one package-level variable (a call counter that stands
#            in for any cached value: a config row, a session flag, a lookup table). Leftover APP sessions are killed,
#            the REL2 edition is dropped and the default edition is ORA$BASE again, so each drill starts clean.
#            Every "user" session calls the package, then waits for the deploy, then calls it again.
#   ERROR  : a session calls PRICING twice; the release replaces the package body. Asserted: the next call fails with
#            ORA-04068 / ORA-04061 / ORA-04065, the call after it works, and the counter starts again at 1 (the
#            state is gone, not just the error). The session's uncommitted insert is still there after the error.
#   COLLAT : the session also uses AUDIT_CTX, a second package with its own variable; only AUDIT_CTX is recompiled.
#            Asserted: PRICING keeps counting (1, 2, 3) until AUDIT_CTX raises ORA-04068; after that, PRICING, which the
#            release never touched, is back to 1 too. The error discards all of the session's package state.
#   WHICH  : which packages and which changes raise it, each against a session that already used the package.
#            Asserted: no error for a package with no variables or only literal constants, even when its spec changes;
#            ORA-04068 for a "constant" set from SYSDATE, for ALTER PACKAGE ... COMPILE BODY with no change, and for
#            ADD COLUMN on a table behind a %ROWTYPE package variable (a package that names its columns stays VALID).
#   POOL   : 8 pooled sessions, 6 of them have called PRICING, then one deploy. Asserted: 6 calls fail (one per session
#            that held state, none for the 2 that didn't), and the second round has 0 failures.
#   SERIAL : the same package with PRAGMA SERIALLY_REUSABLE. Asserted: no error after the deploy and the new code
#            at once, but the counter is 1 on every call (state lasts one call), and a call from SQL fails with ORA-06534.
#   EDITION: edition-based redefinition. The release is compiled in edition REL2 while a session in ORA$BASE keeps
#            working. Asserted: the old session never errors and its counter keeps counting (old code, old state);
#            a new session gets the old code until ALTER DATABASE DEFAULT EDITION = REL2, then the new code.
#
#   ./run.sh up        # start the database (first run pulls the image)
#   ./run.sh setup     # create the schema (resets the lab; safe to rerun)
#   ./run.sh error     # ORA-04068 after a deploy, and what the retry gives you
#   ./run.sh collat    # one package's ORA-04068 resets every package in the session
#   ./run.sh which     # which packages and changes raise it
#   ./run.sh pool      # one deploy, one error per pooled session that held state
#   ./run.sh serial    # PRAGMA SERIALLY_REUSABLE: no error, no state
#   ./run.sh edition   # edition-based redefinition: deploy under live sessions
#   ./run.sh all       # error -> collat -> which -> pool -> serial -> edition (each starts from setup)
#   ./run.sh sql       # SQL*Plus as SYSDBA
#   ./run.sh down / destroy
set -euo pipefail
cd "$(dirname "$0")"

C=ora-package-state-lab
export LAB_PORT="${LAB_PORT:-1521}"
APP="app/App_Passw0rd1@localhost:1521/FREEPDB1"

die() { echo "!! FAIL: $*" >&2; exit 1; }
run_sys() { docker exec -i "$C" sqlplus -s -L "/ as sysdba"; }
# pdb_sql: script on stdin, run as SYS in the PDB
pdb_sql() { { printf 'alter session set container = FREEPDB1;\n'; cat; printf '\nexit\n'; } | run_sys; }
# pdb_val <query>: one value from the PDB as SYS
pdb_val() { printf 'set pages 0 feedback off heading off\n%s\n' "$1" | pdb_sql \
  | tr -d ' \t\r' | grep -v '^$' | grep -v '^Session' | head -1 || true; }
app_sql() { docker exec -i "$C" sqlplus -s -L "$APP" 2>&1 || true; }

wait_healthy() {
  echo "Waiting for the database to be ready..."
  for i in $(seq 1 90); do
    if docker exec "$C" healthcheck.sh >/dev/null 2>&1; then echo "Database is ready."; return 0; fi
    sleep 5
  done
  die "timed out waiting for the database"
}

# A "user" session: <before> calls, then it waits for the deploy (the file /tmp/deployed), then <after> calls.
# A call is "@<tag>" + a SELECT; result <name> <tag> prints what that call returned, or its first ORA- code.
call() { printf "\nprompt @%s\nselect 'V='||%s from dual;\n" "$1" "$2"; }
plcall() { printf "\nprompt @%s\nbegin dbms_output.put_line('V='||%s); end;\n/\n" "$1" "$2"; }
session() {  # session <name> <before-calls> <after-calls>   (stdin is not used)
  printf "set feedback off heading off pages 0 serveroutput on\nwhenever sqlerror continue\n%s\nprompt READY\nhost bash -c 'until [ -f /tmp/deployed ]; do sleep 0.2; done'\n%s\nprompt FINISHED\nexit\n" "$2" "$3" \
    | docker exec -i "$C" bash -c "cat > /tmp/$1.sql; rm -f /tmp/$1.out"
  docker exec -d "$C" bash -c "sqlplus -s -L $APP @/tmp/$1.sql > /tmp/$1.out 2>&1"
}
out() { docker exec "$C" cat "/tmp/$1.out" 2>/dev/null || true; }
wait_for() {  # wait_for <name> <marker> [seconds]
  local i
  for i in $(seq 1 "${3:-60}"); do docker exec "$C" grep -q "^$2" "/tmp/$1.out" 2>/dev/null && return 0; sleep 1; done
  out "$1" | tail -20; die "session $1 never printed $2"
}
result() { out "$1" | awk -v t="@$2" '$0==t{f=1;next} f&&/^@|^READY|^FINISHED/{exit}
  f&&/^V=/{sub(/^V=/,"");print;exit} f&&match($0,/ORA-[0-9]+/){print substr($0,RSTART,RLENGTH);exit}'; }
stack() { out "$1" | awk -v t="@$2" '$0==t{f=1;next} f&&/^@|^READY|^FINISHED/{exit} f&&/^ORA-/' | cut -c1-100; }
deploy() {  # deploy: SQL on stdin as APP, then release every waiting session
  local o; o=$(app_sql); printf '%s\n' "$o" | grep -E 'ORA-|PLS-|compilation errors' && die "deploy failed: $o"
  docker exec "$C" touch /tmp/deployed
}

# pricing_body <version> [pragma]: the package body; the version is what VERSION returns
pricing() {
  printf "create or replace package pricing as\n  %s\n  function next_call return number;\n  function version return varchar2;\nend;\n/\n" "${2:-}"
  pricing_body "$1" "${2:-}"
}
pricing_body() {
  printf "create or replace package body pricing as\n  %s\n  g_calls number := 0;\n  function next_call return number is begin g_calls := g_calls + 1; return g_calls; end;\n  function version return varchar2 is begin return '%s'; end;\nend;\n/\n" "${2:-}" "$1"
}

cmd_up() { docker compose up -d; wait_healthy; }

cmd_setup() {
  local i
  wait_healthy
  docker exec "$C" bash -c 'rm -f /tmp/deployed'
  pdb_val "begin for s in (select sid, serial# from v\$session where username = 'APP') loop
    execute immediate 'alter system kill session ''' || s.sid || ',' || s.serial# || ''' immediate'; end loop; end;
/" >/dev/null
  for i in $(seq 1 30); do [ "$(pdb_val "select count(*) from v\$session where username = 'APP';")" = 0 ] && break; sleep 1; done
  # a session that just ended can keep the edition "in use" (ORA-38805) for a few seconds
  for i in $(seq 1 60); do
    [ "$(pdb_val "select count(*) from dba_editions where edition_name = 'REL2';")" = 0 ] && break
    pdb_sql >/dev/null <<'EOF'
alter database default edition = ora$base;
whenever sqlerror continue
drop edition rel2 cascade;
EOF
    sleep 1
  done
  [ "$(pdb_val "select count(*) from dba_editions where edition_name = 'REL2';")" = 0 ] || die "could not drop edition REL2"
  { cat <<'EOF'
whenever sqlerror continue
begin
  for o in (select object_name, object_type from user_objects where object_type in ('PACKAGE', 'TABLE')) loop
    execute immediate 'drop ' || o.object_type || ' ' || o.object_name || case o.object_type when 'TABLE' then ' purge' end;
  end loop;
end;
/
whenever sqlerror exit failure
create table orders (id number primary key, status varchar2(10), amount number);
insert into orders select level, 'NEW', level from dual connect by level <= 1000;
commit;
EOF
    pricing v1; } | app_sql >/dev/null
  [ "$(pdb_val "select count(*) from app.orders;")" = 1000 ] || die "setup did not create APP.ORDERS"
  [ "$(pdb_val "select status from dba_objects where owner = 'APP' and object_name = 'PRICING' and object_type = 'PACKAGE BODY';")" = VALID ] \
    || die "setup did not create APP.PRICING"
}

cmd_error() {
  echo ">> ERROR: a session uses PRICING (one package variable); the release replaces the package body."
  cmd_setup
  local r1 r2 r3 r4 rows
  session s "$(call c1 pricing.next_call)$(call c2 pricing.next_call)
insert into orders values (1001, 'NEW', 1);" \
    "$(call c3 pricing.next_call)$(call c4 pricing.next_call)$(call ver pricing.version)$(call rows "(select count(*) from orders)")"
  wait_for s READY
  pricing_body v2 | deploy
  wait_for s FINISHED
  r1=$(result s c1); r2=$(result s c2); r3=$(result s c3); r4=$(result s c4); rows=$(result s rows)
  echo "   before the deploy: next_call = $r1, $r2"
  echo "   first call after it:"
  stack s c3 | sed 's/^/     /'
  echo "   the call after that: next_call = $r4, version = $(result s ver);  rows (with the uncommitted insert) = $rows"
  [ "$r1 $r2" = "1 2" ] || die "expected 1 2 before the deploy, got $r1 $r2"
  [ "$r3" = ORA-04068 ] || die "expected ORA-04068 on the first call after the deploy, got $r3"
  stack s c3 | grep -q 'ORA-04061' && stack s c3 | grep -q 'ORA-04065' || die "expected ORA-04061 and ORA-04065 under it"
  [ "$r4" = 1 ] || die "expected the retry to work and start again at 1, got $r4"
  [ "$rows" = 1001 ] || die "expected the uncommitted insert to survive the error, got $rows rows"
  echo "   -> the retry works, but the counter is back to 1: the package's state was thrown away, not just the call."
}

cmd_collat() {
  echo ">> COLLAT: the session uses PRICING and AUDIT_CTX (each has one variable); the release recompiles only AUDIT_CTX."
  cmd_setup
  app_sql >/dev/null <<'EOF2'
create or replace package audit_ctx as function next_call return number; end;
/
create or replace package body audit_ctx as g_calls number := 0;
function next_call return number is begin g_calls := g_calls + 1; return g_calls; end; end;
/
EOF2
  session s "$(call p1 pricing.next_call)$(call p2 pricing.next_call)$(call a1 audit_ctx.next_call)" \
    "$(call p3 pricing.next_call)$(call a2 audit_ctx.next_call)$(call a3 audit_ctx.next_call)$(call p4 pricing.next_call)"
  wait_for s READY
  printf 'alter package audit_ctx compile body;\n' | deploy
  wait_for s FINISHED
  local p="$(result s p1) $(result s p2) $(result s p3)" a="$(result s a1) $(result s a2) $(result s a3)" p4
  p4=$(result s p4)
  echo "   PRICING   (not redeployed): $p, then after AUDIT_CTX's error: $p4"
  echo "   AUDIT_CTX (recompiled):     $a"
  [ "$p" = "1 2 3" ] || die "expected PRICING to keep counting before the error, got $p"
  [ "$a" = "1 ORA-04068 1" ] || die "expected AUDIT_CTX: 1, ORA-04068, 1; got $a"
  [ "$p4" = 1 ] || die "expected PRICING to lose its state too after the error, got $p4"
  echo "   -> one package's ORA-04068 threw away the state of every package in the session, including untouched ones."
}

# which_case <label> <package DDL> <call> <change>: a session uses the package, <change> is deployed, then it calls again
which_case() {
  cmd_setup >/dev/null
  printf '%s\n' "$2" | app_sql | grep -E 'ORA-|errors' && die "could not create the package for: $1"
  session w "$(call before "$3")" "$(call after "$3")$(call again "$3")"
  wait_for w READY
  printf '%s\n' "$4" | deploy
  wait_for w FINISHED
  local a; a=$(result w after)
  printf '   %-62s %s\n' "$1" "$( [ "${a#ORA-}" != "$a" ] && echo "$a, then $(result w again)" || echo "no error ($a)")"
  WHICH_RESULT=$a
}

cmd_which() {
  echo ">> WHICH: a session has used the package; then one change is deployed and it calls again."
  local plain="create or replace package rates as function version return varchar2; end;
/
create or replace package body rates as function version return varchar2 is begin return 'v1'; end; end;
/"
  which_case "no variables: new body" "$plain" rates.version \
    "create or replace package body rates as function version return varchar2 is begin return 'v2'; end; end;
/"
  [ "$WHICH_RESULT" = v2 ] || die "expected the new code and no error, got $WHICH_RESULT"
  which_case "no variables: new spec (a function added) and body" "$plain" rates.version \
    "create or replace package rates as function version return varchar2; function extra return number; end;
/
create or replace package body rates as function version return varchar2 is begin return 'v2'; end;
function extra return number is begin return 1; end; end;
/"
  [ "$WHICH_RESULT" = v2 ] || die "expected the new code and no error, got $WHICH_RESULT"
  which_case "only a literal constant (c_rate constant number := 5)" \
    "create or replace package rates as c_rate constant number := 5; function version return varchar2; end;
/
create or replace package body rates as function version return varchar2 is begin return 'v1'; end; end;
/" rates.version \
    "create or replace package body rates as function version return varchar2 is begin return 'v2'; end; end;
/"
  [ "$WHICH_RESULT" = v2 ] || die "expected the new code and no error, got $WHICH_RESULT"
  which_case "a constant set at load (c_loaded constant date := sysdate)" \
    "create or replace package rates as c_loaded constant date := sysdate; function version return varchar2; end;
/
create or replace package body rates as function version return varchar2 is begin return 'v1'; end; end;
/" rates.version \
    "create or replace package body rates as function version return varchar2 is begin return 'v2'; end; end;
/"
  [ "$WHICH_RESULT" = ORA-04068 ] || die "expected ORA-04068 for a SYSDATE constant, got $WHICH_RESULT"
  which_case "one variable, ALTER PACKAGE ... COMPILE BODY, no code change" "" pricing.next_call \
    "alter package pricing compile body;"
  [ "$WHICH_RESULT" = ORA-04068 ] || die "expected ORA-04068 for a recompile with no change, got $WHICH_RESULT"
  which_case "a %ROWTYPE variable, then ALTER TABLE ORDERS ADD a column" \
    "create or replace package last_order as function version return varchar2; end;
/
create or replace package body last_order as g_last orders%rowtype;
function version return varchar2 is begin g_last.id := 1; return 'v1'; end; end;
/" last_order.version "alter table orders add (note varchar2(100));"
  [ "$WHICH_RESULT" = ORA-04068 ] || die "expected ORA-04068 after ADD COLUMN under a %ROWTYPE variable, got $WHICH_RESULT"
  which_case "a variable, named columns (no %ROWTYPE), then ADD a column" \
    "create or replace package order_stats as function version return varchar2; end;
/
create or replace package body order_stats as g_n number := 0;
function version return varchar2 is l number; begin select count(id) into l from orders; g_n := g_n + 1; return 'v1'; end; end;
/" order_stats.version "alter table orders add (note varchar2(100));"
  [ "$WHICH_RESULT" = v1 ] || die "expected no error for a package that names its columns, got $WHICH_RESULT"
  echo "   -> it's not the change that matters, it's whether the package holds state when it's recompiled."
}

cmd_pool() {
  echo ">> POOL: 8 pooled sessions; 6 have called PRICING. One deploy, then every session makes two calls."
  cmd_setup
  local i before e1=0 e2=0
  for i in 1 2 3 4 5 6 7 8; do
    before=""; [ "$i" -le 6 ] && before=$(call c0 pricing.next_call)
    session "p$i" "$before" "$(call c1 pricing.version)$(call c2 pricing.version)"
  done
  for i in 1 2 3 4 5 6 7 8; do wait_for "p$i" READY; done
  pricing_body v2 | deploy
  for i in 1 2 3 4 5 6 7 8; do
    wait_for "p$i" FINISHED
    [ "$(result "p$i" c1)" = ORA-04068 ] && e1=$((e1 + 1))
    [ "$(result "p$i" c2)" = ORA-04068 ] && e2=$((e2 + 1))
    [ "$i" -gt 6 ] && [ "$(result "p$i" c1)" != v2 ] && die "session $i never used PRICING, expected v2 at once"
  done
  echo "   first round after the deploy:  $e1 of 8 calls failed with ORA-04068"
  echo "   second round:                  $e2 of 8"
  [ "$e1" = 6 ] || die "expected 6 errors, one per session that held state, got $e1"
  [ "$e2" = 0 ] || die "expected no errors in the second round, got $e2"
  echo "   -> one error per connection that had used the package. A bigger pool means a bigger burst, once."
}

cmd_serial() {
  echo ">> SERIAL: PRICING with PRAGMA SERIALLY_REUSABLE (state lasts one server call)."
  cmd_setup
  pricing v1 "pragma serially_reusable;" | app_sql >/dev/null
  local s
  s=$(printf "set feedback off heading off pages 0\nselect pricing.version from dual;\nexit\n" | app_sql | grep -m1 -oE 'ORA-[0-9]+' || true)
  echo "   called from SQL (select pricing.version from dual): $s"
  [ "$s" = ORA-06534 ] || die "expected ORA-06534 from SQL, got $s"
  session s "$(plcall c1 "pricing.next_call||' '||pricing.version")$(plcall c2 "pricing.next_call||' '||pricing.version")" \
    "$(plcall c3 "pricing.next_call||' '||pricing.version")"
  wait_for s READY
  pricing_body v2 "pragma serially_reusable;" | deploy
  wait_for s FINISHED
  echo "   from PL/SQL, next_call and version: $(result s c1), $(result s c2);  after the deploy: $(result s c3)"
  [ "$(result s c1)" = "1 v1" ] && [ "$(result s c2)" = "1 v1" ] || die "expected '1 v1' twice, got $(result s c1) / $(result s c2)"
  [ "$(result s c3)" = "1 v2" ] || die "expected '1 v2' with no error after the deploy, got $(result s c3)"
  echo "   -> no ORA-04068 and the new code at once, but the counter never gets past 1, and SQL can't call it at all."
}

cmd_edition() {
  echo ">> EDITION: the release is compiled in edition REL2 while a session in ORA\$BASE keeps working."
  cmd_setup
  pdb_sql >/dev/null <<'EOF'
whenever sqlerror exit failure
alter user app enable editions;
create edition rel2;
grant use on edition rel2 to app;
EOF
  local ed="sys_context('userenv','current_edition_name')" n1 n2
  session s "$(call c1 "pricing.next_call||' '||pricing.version||' '||$ed")$(call c2 "pricing.next_call||' '||pricing.version||' '||$ed")" \
    "$(call c3 "pricing.next_call||' '||pricing.version||' '||$ed")"
  wait_for s READY
  { printf 'alter session set edition = rel2;\n'; pricing_body v2; } | deploy
  n1=$(printf "set feedback off heading off pages 0\nselect pricing.version||' '||%s from dual;\nexit\n" "$ed" | app_sql | grep -v '^$' | head -1)
  wait_for s FINISHED
  echo "   the live session (next_call, version, edition): $(result s c1) | $(result s c2) | after the deploy: $(result s c3)"
  echo "   a new session, before the switch:  $n1"
  [ "$(result s c3)" = "3 v1 ORA\$BASE" ] || die "expected '3 v1 ORA\$BASE' (no error, state kept), got $(result s c3)"
  [ "$n1" = "v1 ORA\$BASE" ] || die "expected new sessions on v1 before the switch, got $n1"
  pdb_sql >/dev/null <<'EOF'
whenever sqlerror exit failure
alter database default edition = rel2;
EOF
  n2=$(printf "set feedback off heading off pages 0\nselect pricing.version||' '||%s from dual;\nexit\n" "$ed" | app_sql | grep -v '^$' | head -1)
  echo "   ALTER DATABASE DEFAULT EDITION = REL2, then a new session: $n2"
  [ "$n2" = "v2 REL2" ] || die "expected new sessions on v2 in REL2, got $n2"
  echo "   -> the old session finished on the old code with its state; new connections pick up the release."
}

case "${1:-}" in
  up) cmd_up ;;
  setup) cmd_setup; echo "Schema ready." ;;
  error) cmd_error ;; collat) cmd_collat ;; which) cmd_which ;; pool) cmd_pool ;; serial) cmd_serial ;; edition) cmd_edition ;;
  all) cmd_error; cmd_collat; cmd_which; cmd_pool; cmd_serial; cmd_edition; cmd_setup >/dev/null; echo ">> All checks passed." ;;
  sql) docker exec -it "$C" sqlplus / as sysdba ;;
  down) docker compose down ;;
  destroy) docker compose down -v ;;
  *) sed -n '2,36p' "$0"; exit 1 ;;
esac
