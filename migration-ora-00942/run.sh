#!/usr/bin/env bash
# Oracle migration ORA-00942 lab — driver. Everything runs INSIDE the container via `docker exec`, so you only need Docker.
# Companion to the post on ORA-00942 after a schema-mode Data Pump migration.
#
#   SETUP   : the SOURCE is FREEPDB1. REF owns CURRENCIES; APP owns ORDERS and CUSTOMERS plus a view, ORDER_TOTALS, that
#             joins REF.CURRENCIES (APP reads it through a grant from REF). Three readers, each with a different route:
#               REPORTING  select ... from app.orders    direct grant from APP
#               WEBAPP     select ... from orders        public synonym ORDERS + direct grant from APP
#               ANALYST    select ... from app.customers grant to role APP_READ, which ANALYST holds
#             A schema-mode export of REF and APP (expdp SCHEMAS=REF,APP) goes to app.dmp. The TARGET PDB is recreated
#             empty each time: it is the new database.
#   IMPORT  : the usual migration. The reader accounts are created on TARGET first, then one impdp SCHEMAS=REF,APP.
#             Asserted: the job reports exactly 1 error (the grant to role APP_READ) and says nothing about the public
#             synonym; REPORTING still reads, WEBAPP gets ORA-00942 "WEBAPP"."ORDERS", ANALYST gets ORA-00942
#             "APP"."CUSTOMERS", APP's view works.
#   ORDER   : REF and APP imported as two separate jobs, REF first, before any reader account exists. Asserted: 4 grant
#             errors (to APP, APP_READ, WEBAPP, REPORTING); APP gets ORA-00942 on REF.CURRENCIES and ORA-04063 on its own
#             view. After the accounts exist, re-running only the grants (impdp INCLUDE=OBJECT_GRANT) fixes REPORTING and
#             the view, with no recompile.
#   MESSAGE : what the 26ai message tells you. Asserted: it names the object it resolved to: an unqualified name
#             resolves to the user's own schema when no synonym exists; a missing grant and a missing table give the
#             same message.
#   PREFLIGHT: on the SOURCE, before the export: everything outside REF and APP that the readers depend on. Asserted:
#             1 role (APP_READ), 1 member of it (ANALYST), 1 public synonym (ORDERS), 2 user grantees (REPORTING,
#             WEBAPP), 1 grant between the migrated schemas (REF -> APP).
#   FIX     : after the IMPORT drill: a full-mode, metadata-only export filtered to the roles and public synonyms that
#             point at REF and APP, imported into TARGET; the role membership granted; the grants re-run with
#             INCLUDE=OBJECT_GRANT. Asserted: all four reads work.
#   PLSQL   : ANALYST's read works in SQL but a procedure doing the same SELECT compiles with ORA-00942, on the source as
#             well: roles are not used in definer's-rights PL/SQL. A direct grant fixes it.
#
#   ./run.sh up         # start the database (first run pulls the image)
#   ./run.sh setup      # build the source, export it, recreate an empty TARGET (safe to rerun)
#   ./run.sh import     # schema-mode import: which reads break, and what the job log says
#   ./run.sh order      # separate jobs in the wrong order, before the readers exist
#   ./run.sh message    # what the 26ai ORA-00942 message names
#   ./run.sh preflight  # the source queries that list what schema mode leaves behind
#   ./run.sh fix        # carry over roles, public synonyms and grants; every read works
#   ./run.sh plsql      # works in SQL, ORA-00942 in a procedure: roles in PL/SQL
#   ./run.sh all        # setup -> import -> message -> preflight -> fix -> plsql -> setup -> order
#   ./run.sh sql        # SQL*Plus as SYSDBA
#   ./run.sh down / destroy
set -euo pipefail
cd "$(dirname "$0")"

C=ora-migration-ora-00942-lab
export LAB_PORT="${LAB_PORT:-1521}"
SYSPW=Lab_Passw0rd1
DIR=/opt/oracle/oradata/mig

die() { echo "!! FAIL: $*" >&2; exit 1; }
ok() { echo "   ok: $*"; }
run_sys() { docker exec -i "$C" sqlplus -s -L "/ as sysdba"; }
# in_pdb <pdb>: script on stdin, run as SYS in that PDB
in_pdb() { { printf 'alter session set container = %s;\n' "$1"; cat; printf '\nexit\n'; } | run_sys; }
val() { printf 'set pages 0 feedback off heading off\n%s\n' "$2" | in_pdb "$1" \
  | tr -d ' \t\r' | grep -v '^$' | grep -v '^Session' | head -1 || true; }
# as <user> <pdb> <sql>: one statement as a user; prints the value (V=...) or the first ORA- line
as() {
  printf 'set feedback off heading off pages 0\n%s\nexit\n' "$3" \
    | docker exec -i "$C" sqlplus -s -L "$1/$(pw "$1")@localhost:1521/$2" 2>&1 \
    | grep -E '^V=|ORA-[0-9]+' | head -1 | sed 's/^V=//' || true
}
pw() { case "$1" in app) echo App_Passw0rd1;; ref) echo Ref_Passw0rd1;; reporting) echo Rep_Passw0rd1;;
  webapp) echo Web_Passw0rd1;; analyst) echo Ana_Passw0rd1;; esac; }
dp() {  # dp <expdp|impdp> <pdb> <args...>: run Data Pump, print the log lines that matter
  local tool=$1 pdb=$2; shift 2
  docker exec "$C" bash -c "$tool system/$SYSPW@localhost:1521/$pdb directory=MIG $* 2>&1" \
    | grep -E 'ORA-[0-9]+|^Failing|^GRANT|completed|imported|exported' || true
}
expect() {  # expect <label> <actual> <pattern>
  printf '%s\n' "$2" | grep -qE -- "$3" || die "$1: expected /$3/, got: $2"
  ok "$1 -> $2"
}

READS() {  # READS <pdb>: the four reads, one line each
  echo "   REPORTING  select count(*) from app.orders     : $(as reporting "$1" "select 'V='||count(*) from app.orders;")"
  echo "   WEBAPP     select count(*) from orders         : $(as webapp "$1" "select 'V='||count(*) from orders;")"
  echo "   ANALYST    select count(*) from app.customers  : $(as analyst "$1" "select 'V='||count(*) from app.customers;")"
  echo "   APP        select count(*) from order_totals   : $(as app "$1" "select 'V='||count(*) from order_totals;")"
}

wait_healthy() {
  echo "Waiting for the database to be ready..."
  for i in $(seq 1 90); do
    if docker exec "$C" healthcheck.sh >/dev/null 2>&1; then echo "Database is ready."; return 0; fi
    sleep 5
  done
  die "timed out waiting for the database"
}

cmd_up() { docker compose up -d; wait_healthy; }

new_target() {  # new_target: drop TARGET if it exists, create it empty, with a USERS tablespace and the MIG directory
  run_sys >/dev/null <<EOF
whenever sqlerror continue
alter pluggable database target close immediate;
drop pluggable database target including datafiles;
whenever sqlerror exit failure
create pluggable database target admin user tadmin identified by $SYSPW
  file_name_convert = ('/opt/oracle/oradata/FREE/pdbseed/', '/opt/oracle/oradata/FREE/TARGET/');
alter pluggable database target open;
alter session set container = target;
create tablespace users datafile '/opt/oracle/oradata/FREE/TARGET/users01.dbf' size 50m autoextend on;
create directory mig as '$DIR';
exit
EOF
  [ "$(val TARGET "select open_mode from v\$pdbs where name = 'TARGET';")" = "READWRITE" ] || die "TARGET is not open"
}

readers_on() {  # readers_on <pdb>: create the three reader accounts (no grants on APP objects)
  in_pdb "$1" >/dev/null <<'EOF'
create user reporting identified by Rep_Passw0rd1;
create user webapp identified by Web_Passw0rd1;
create user analyst identified by Ana_Passw0rd1;
grant create session, create procedure to reporting, webapp, analyst;
EOF
}

cmd_setup() {
  wait_healthy
  docker exec "$C" bash -c "mkdir -p $DIR && rm -f $DIR/*.dmp $DIR/*.log $DIR/*.sql"
  in_pdb FREEPDB1 >/dev/null <<'EOF'
whenever sqlerror continue
drop public synonym orders;
drop role app_read;
drop user app cascade;
drop user ref cascade;
drop user reporting cascade;
drop user webapp cascade;
drop user analyst cascade;
drop directory mig;
begin
  for j in (select table_name from dba_tables where owner = 'SYSTEM' and table_name like 'SYS\_EXPORT\_%' escape '\') loop
    execute immediate 'drop table system.' || j.table_name || ' purge';
  end loop;
end;
/
whenever sqlerror exit failure
create directory mig as '/opt/oracle/oradata/mig';
create user ref identified by Ref_Passw0rd1 quota unlimited on users;
create user app identified by App_Passw0rd1 quota unlimited on users;
grant create session, create table, create view, create procedure to app, ref;
create user reporting identified by Rep_Passw0rd1;
create user webapp identified by Web_Passw0rd1;
create user analyst identified by Ana_Passw0rd1;
grant create session, create procedure to reporting, webapp, analyst;
create role app_read;
grant app_read to analyst;
create table ref.currencies (code varchar2(3) primary key, name varchar2(30));
insert into ref.currencies values ('USD', 'US dollar');
insert into ref.currencies values ('EUR', 'Euro');
grant select on ref.currencies to app;
create table app.customers (id number primary key, name varchar2(40));
create table app.orders (id number primary key, customer_id number, amount number, currency varchar2(3));
insert into app.customers select level, 'Customer ' || level from dual connect by level <= 100;
insert into app.orders select level, mod(level, 100) + 1, level * 10,
  case mod(level, 2) when 0 then 'USD' else 'EUR' end from dual connect by level <= 1000;
commit;
create view app.order_totals as
  select o.currency, c.name currency_name, sum(o.amount) total
  from app.orders o join ref.currencies c on c.code = o.currency group by o.currency, c.name;
grant select on app.orders to reporting;
grant select on app.orders to webapp;
create public synonym orders for app.orders;
grant select on app.customers to app_read;
EOF
  echo "== SOURCE (FREEPDB1): every read works"
  local r; r=$(READS FREEPDB1); echo "$r"
  printf '%s\n' "$r" | grep -q 'ORA-' && die "a read fails on the source"
  echo "== Schema-mode export: expdp SCHEMAS=REF,APP"
  dp expdp FREEPDB1 schemas=REF,APP dumpfile=app.dmp logfile=exp.log | grep -E 'exported|completed'
  docker exec "$C" test -s "$DIR/app.dmp" || die "export produced no dump file"
  new_target
  echo "== TARGET recreated, empty"
}

cmd_import() {
  echo "== TARGET: reader accounts created (as an account team would), then impdp SCHEMAS=REF,APP in one job"
  readers_on TARGET
  local log; log=$(dp impdp TARGET schemas=REF,APP dumpfile=app.dmp logfile=imp.log); echo "$log" | sed 's/^/   /'
  expect "errors in the job" "$(echo "$log" | grep -oE 'completed with [0-9]+ error' | grep -oE '[0-9]+')" '^1$'
  expect "the one failed grant" "$(echo "$log" | grep '^GRANT')" 'TO "APP_READ"'
  echo "$log" | grep -qi synonym && die "the log mentions the synonym"
  ok "the log says nothing about public synonym ORDERS"
  echo "== The same four reads on TARGET"
  READS TARGET
  expect "REPORTING (direct grant, travelled with APP)" "$(as reporting TARGET "select 'V='||count(*) from app.orders;")" '^1000$'
  expect "WEBAPP (public synonym, not in a schema export)" "$(as webapp TARGET "select 'V='||count(*) from orders;")" 'ORA-00942: table or view "WEBAPP"."ORDERS"'
  expect "ANALYST (grant to a role that does not exist)" "$(as analyst TARGET "select 'V='||count(*) from app.customers;")" 'ORA-00942: table or view "APP"."CUSTOMERS"'
  expect "APP view over REF (same job, grant applied)" "$(as app TARGET "select 'V='||count(*) from order_totals;")" '^2$'
  expect "public synonyms on TARGET" "$(val TARGET "select count(*) from dba_synonyms where owner = 'PUBLIC' and table_owner = 'APP';")" '^0$'
  expect "role APP_READ on TARGET" "$(val TARGET "select count(*) from dba_roles where role = 'APP_READ';")" '^0$'
}

cmd_order() {
  echo "== TARGET: REF and APP as two separate jobs, REF first, no reader accounts yet"
  local l1 l2
  l1=$(dp impdp TARGET schemas=REF dumpfile=app.dmp logfile=imp_ref.log); echo "$l1" | sed 's/^/   REF: /'
  l2=$(dp impdp TARGET schemas=APP dumpfile=app.dmp logfile=imp_app.log); echo "$l2" | sed 's/^/   APP: /'
  expect "REF job: grant to APP fails (APP does not exist yet)" "$(echo "$l1" | grep '^GRANT')" 'TO "APP"'
  expect "APP job: failed grants" "$(echo "$l2" | grep -c '^GRANT')" '^3$'
  expect "APP job: view created with errors" "$(echo "$l2" | grep -o 'ORA-39082')" 'ORA-39082'
  expect "APP reads REF.CURRENCIES" "$(as app TARGET "select 'V='||count(*) from ref.currencies;")" 'ORA-00942: table or view "REF"."CURRENCIES"'
  expect "APP reads its own view" "$(as app TARGET "select 'V='||count(*) from order_totals;")" 'ORA-04063'
  echo "== Reader accounts created now, after the import"
  readers_on TARGET
  expect "REPORTING (account exists, grant never ran)" "$(as reporting TARGET "select 'V='||count(*) from app.orders;")" 'ORA-00942'
  echo "== Re-run only the grants: impdp INCLUDE=OBJECT_GRANT for REF and APP"
  dp impdp TARGET schemas=REF,APP dumpfile=app.dmp include=OBJECT_GRANT logfile=imp_grants.log | sed 's/^/   /'
  expect "REPORTING" "$(as reporting TARGET "select 'V='||count(*) from app.orders;")" '^1000$'
  expect "APP's view, no recompile needed" "$(as app TARGET "select 'V='||count(*) from order_totals;")" '^2$'
  expect "view status" "$(val TARGET "select status from dba_objects where owner = 'APP' and object_name = 'ORDER_TOTALS';")" '^VALID$'
}

cmd_message() {
  echo "== What the 26ai message names (on the SOURCE, where everything exists)"
  expect "unqualified name, no such table, no synonym" "$(as webapp FREEPDB1 "select 'V='||count(*) from no_such_table;")" '"WEBAPP"."NO_SUCH_TABLE"'
  expect "table exists, no grant" "$(as webapp FREEPDB1 "select 'V='||count(*) from app.customers;")" 'ORA-00942: table or view "APP"."CUSTOMERS" does not exist'
  expect "table does not exist at all" "$(as webapp FREEPDB1 "select 'V='||count(*) from app.no_such_table;")" 'ORA-00942: table or view "APP"."NO_SUCH_TABLE" does not exist'
  echo "   -> no grant and no table read the same; an unqualified name shows the schema it fell back to"
}

cmd_preflight() {
  echo "== SOURCE: what REF and APP depend on that a schema-mode export of REF,APP does not carry"
  in_pdb FREEPDB1 <<'EOF' | grep -vE '^$|^Session'
set lines 150 pages 100 feedback off
col kind format a26
col detail format a70
with migrated as (select column_value as owner from table(sys.odcivarchar2list('REF', 'APP')))
select 'role (not exported)' kind, p.grantee || ' has ' || p.privilege || ' on ' || p.owner || '.' || p.table_name detail
from dba_tab_privs p join dba_roles r on r.role = p.grantee
where p.owner in (select owner from migrated)
union all
select 'role member (not exported)', m.grantee || ' holds ' || m.granted_role
from dba_role_privs m
where m.granted_role in (select grantee from dba_tab_privs where owner in (select owner from migrated))
  and m.grantee not in ('SYS', 'SYSTEM')
union all
select 'public synonym (not exported)', 'PUBLIC.' || s.synonym_name || ' -> ' || s.table_owner || '.' || s.table_name
from dba_synonyms s where s.owner = 'PUBLIC' and s.table_owner in (select owner from migrated)
union all
select 'synonym in another schema', s.owner || '.' || s.synonym_name || ' -> ' || s.table_owner || '.' || s.table_name
from dba_synonyms s where s.owner <> 'PUBLIC' and s.table_owner in (select owner from migrated)
  and s.owner not in (select owner from migrated)
union all
select 'grantee must exist first', p.grantee || ' (' || p.privilege || ' on ' || p.owner || '.' || p.table_name || ')'
from dba_tab_privs p join dba_users u on u.username = p.grantee
where p.owner in (select owner from migrated) and p.grantee not in (select owner from migrated)
union all
select 'grant between migrated', p.owner || '.' || p.table_name || ' -> ' || p.grantee
from dba_tab_privs p
where p.owner in (select owner from migrated) and p.grantee in (select owner from migrated)
order by 1, 2;
EOF
  expect "roles" "$(val FREEPDB1 "select count(distinct p.grantee) from dba_tab_privs p join dba_roles r on r.role = p.grantee where p.owner in ('REF','APP');")" '^1$'
  expect "role members" "$(val FREEPDB1 "select count(*) from dba_role_privs where granted_role = 'APP_READ' and grantee not in ('SYS','SYSTEM');")" '^1$'
  expect "public synonyms" "$(val FREEPDB1 "select count(*) from dba_synonyms where owner = 'PUBLIC' and table_owner in ('REF','APP');")" '^1$'
  expect "user grantees outside REF/APP" "$(val FREEPDB1 "select count(distinct p.grantee) from dba_tab_privs p join dba_users u on u.username = p.grantee where p.owner in ('REF','APP') and p.grantee not in ('REF','APP');")" '^2$'
}

cmd_fix() {
  echo "== Carry over what schema mode left behind"
  docker exec -i "$C" bash -c "cat > $DIR/extras.par" <<'EOF'
full=y
content=metadata_only
dumpfile=extras.dmp
logfile=exp_extras.log
include=ROLE:"IN (SELECT grantee FROM dba_tab_privs WHERE owner IN ('REF','APP'))"
include=PUBLIC_SYNONYM/SYNONYM:"IN (SELECT synonym_name FROM dba_synonyms WHERE owner = 'PUBLIC' AND table_owner IN ('REF','APP'))"
EOF
  echo "   1. full-mode, metadata-only export of the roles and public synonyms that point at REF and APP"
  dp expdp FREEPDB1 parfile=$DIR/extras.par | sed 's/^/      /'
  dp impdp TARGET dumpfile=extras.dmp logfile=imp_extras.log | sed 's/^/      /'
  expect "role APP_READ on TARGET" "$(val TARGET "select count(*) from dba_roles where role = 'APP_READ';")" '^1$'
  expect "public synonym ORDERS on TARGET" "$(val TARGET "select count(*) from dba_synonyms where owner = 'PUBLIC' and synonym_name = 'ORDERS';")" '^1$'
  echo "   2. the role membership (ROLE_GRANT takes no name filter in a full export; generate it on the source)"
  in_pdb TARGET <<'EOF' | grep -E 'ORA-' && die "role grant failed"
grant app_read to analyst;
EOF
  ok "grant app_read to analyst"
  echo "   3. re-run the object grants now that the role exists"
  dp impdp TARGET schemas=REF,APP dumpfile=app.dmp include=OBJECT_GRANT logfile=imp_grants2.log | sed 's/^/      /'
  echo "== The four reads on TARGET"
  local r; r=$(READS TARGET); echo "$r"
  printf '%s\n' "$r" | grep -q 'ORA-' && die "a read still fails after the fix"
  ok "all four reads work"
}

cmd_plsql() {
  local proc="create or replace procedure cust_count as n number; begin select count(*) into n from app.customers; end;
/
show errors
select 'V='||status from user_objects where object_name = 'CUST_COUNT';"
  echo "== ANALYST reads APP.CUSTOMERS through role APP_READ"
  expect "SQL on TARGET" "$(as analyst TARGET "select 'V='||count(*) from app.customers;")" '^100$'
  expect "same SELECT in a procedure on TARGET" "$(as analyst TARGET "$proc")" 'ORA-00942: table or view "APP"."CUSTOMERS"'
  expect "same procedure on the SOURCE" "$(as analyst FREEPDB1 "$proc")" 'ORA-00942'
  echo "   -> not a migration problem: definer's-rights PL/SQL ignores roles"
  in_pdb TARGET <<'EOF' | grep -E 'ORA-' && die "direct grant failed"
grant select on app.customers to analyst;
EOF
  expect "after a direct grant" "$(as analyst TARGET "$proc")" '^VALID$'
}

cmd_all() {
  local t0=$SECONDS
  cmd_setup; cmd_import; cmd_message; cmd_preflight; cmd_fix; cmd_plsql
  cmd_setup; cmd_order
  echo "== ALL DRILLS PASSED in $((SECONDS - t0)) s"
}

case "${1:-}" in
  up) cmd_up ;;
  setup) cmd_setup ;;
  import) cmd_import ;;
  order) cmd_order ;;
  message) cmd_message ;;
  preflight) cmd_preflight ;;
  fix) cmd_fix ;;
  plsql) cmd_plsql ;;
  all) cmd_all ;;
  sql) docker exec -it "$C" sqlplus / as sysdba ;;
  down) docker compose down ;;
  destroy) docker compose down -v ;;
  *) sed -n '2,40p' "$0"; exit 1 ;;
esac
