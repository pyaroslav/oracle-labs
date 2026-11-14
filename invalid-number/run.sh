#!/usr/bin/env bash
# Oracle ORA-01722 lab — driver. Everything runs INSIDE the container via `docker exec`, so you only need Docker.
# Companion to the post on ORA-01722 (invalid number) that appears when the plan changes, not the data.
#
#   SETUP  : APP.SENSORS (1,000 sensors: 900 TEMP, 100 STATUS; site HQ has 500 of them, sites S000-S099 have 5 each)
#            and APP.READINGS (500,000 rows, 500 per sensor, clustered by sensor, index on SENSOR_ID). VAL is VARCHAR2:
#            TEMP sensors write numbers ('150.5'), STATUS sensors write text ('OK', 'ALARM', 'n/a').
#            The report: count a site's TEMP readings above 150, with TO_NUMBER(r.val) and the site as a bind.
#   DAY1   : the cursor's first execution is a small site (S007). Asserted: the adaptive plan resolves to NESTED LOOPS,
#            S007 returns 495 and then HQ returns 54450 on the same cursor. TO_NUMBER only ever sees TEMP rows.
#            Statistics: every gather in the lab is the same call, with frequency histograms on SENSORS.SITE and
#            SENSORS.KIND (what a skewed column used in WHERE clauses normally gets) and none elsewhere.
#   DAY2   : nothing in the data changes. The same stats gather invalidates the cursor; the statistics before and
#            after are asserted identical (rows, distinct values, histograms). The first execution is HQ. Asserted:
#            the plan resolves to HASH JOIN (a different plan hash value), TO_NUMBER runs on every row of READINGS
#            during the full scan, and HQ fails with ORA-01722. Then S007, which worked on day 1, fails too, and so
#            does S042: the cursor keeps the hash join.
#            Day 3: the next gather invalidates it again, a small site runs first, and everything works again.
#   NOHIST : the same day 2 without the histograms. Asserted: HQ fails on the hash join, and Oracle marks the cursor
#            for reoptimization (its estimate of HQ's sensors was far off); the next execution, S007, gets a new
#            child cursor with nested loops and works. One failure instead of every one.
#   NOINDEX: no index on READINGS.SENSOR_ID (a migration that hasn't built it yet, or one dropped as unused).
#            Asserted: even the small site gets HASH JOIN and ORA-01722.
#   MESSAGE: the 26ai message names the column and the value. Asserted: it shows VAL and a STATUS value, and
#            VALIDATE_CONVERSION finds exactly 3 bad values (50,000 rows), all from STATUS sensors.
#   GUARDS : things that look like they fix it, each run with HQ first. Asserted: an inline view with the filter
#            inside, the same view with NO_MERGE, and an implicit conversion (VAL = 150) all run on a HASH JOIN and
#            still fail with ORA-01722; VAL = '150' (a string compare) works.
#   FIX    : fixes that don't depend on evaluation order, each run with HQ first, on the HASH JOIN plan that failed.
#            Asserted: HQ 54450 (and S007 495 after it) for TO_NUMBER(... DEFAULT NULL ON CONVERSION ERROR) and for
#            a CASE on the sensor's kind.
#   NLS    : a session with a comma decimal separator (NLS_TERRITORY = GERMANY). Asserted: plain TO_NUMBER fails on
#            a TEMP value like '100.5' (no STATUS row needed); DEFAULT NULL ON CONVERSION ERROR raises nothing and
#            returns 26950 instead of 54450 (the decimals became NULL); an explicit NLS_NUMERIC_CHARACTERS returns
#            54450; a virtual column with the explicit format returns 54450 in both sessions.
#
#   ./run.sh up        # start the database (first run pulls the image)
#   ./run.sh setup     # create the schema (resets the lab; safe to rerun)
#   ./run.sh day1      # small site first: nested loops, both sites work
#   ./run.sh day2      # same data, big site first: hash join, every site fails; day 3 it "fixes itself"
#   ./run.sh nohist    # day 2 without histograms: one failure, then statistics feedback recovers
#   ./run.sh noindex   # without the index, every site fails
#   ./run.sh message   # what the 26ai message tells you, and finding the bad rows
#   ./run.sh guards    # inline view, NO_MERGE, implicit conversion: none of them protect
#   ./run.sh fix       # DEFAULT NULL ON CONVERSION ERROR, CASE: both work on the plan that failed
#   ./run.sh nls       # comma decimal separator: an error, a silent wrong answer, and the explicit fix
#   ./run.sh all       # day1 -> day2 -> nohist -> noindex -> message -> guards -> fix -> nls (each from setup)
#   ./run.sh sql       # SQL*Plus as SYSDBA
#   ./run.sh down / destroy
set -euo pipefail
cd "$(dirname "$0")"

C=ora-invalid-number-lab
export LAB_PORT="${LAB_PORT:-1521}"
APP="app/App_Passw0rd1@localhost:1521/FREEPDB1"
TAG="sensor-report"

die() { echo "!! FAIL: $*" >&2; exit 1; }
run_sys() { docker exec -i "$C" sqlplus -s -L "/ as sysdba"; }
pdb_sql() { { printf 'alter session set container = FREEPDB1;\n'; cat; printf '\nexit\n'; } | run_sys; }
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

# The plan each execution used is read in the same session, right after it (DBMS_XPLAN.DISPLAY_CURSOR of the last
# statement, active rows only), and printed as "PLAN=<HASH JOIN|NESTED LOOPS> <plan hash value>".
PLANQ="select 'PLAN=' || case when sum(case when plan_table_output like '%HASH JOIN%' then 1 end) > 0 then 'HASH JOIN'
  when sum(case when plan_table_output like '%NESTED LOOPS%' then 1 end) > 0 then 'NESTED LOOPS' else 'unknown' end
  || ' ' || max(regexp_substr(plan_table_output, 'Plan hash value: ([0-9]+)', 1, 1, null, 1))
from table(dbms_xplan.display_cursor(format => 'BASIC'));"
# raw <site> <statement using :site> [session-setup]: run as APP; prints the count or the error lines, then PLAN=...
raw() {
  printf "set feedback off heading off pages 0 lines 200 serveroutput off\n%s\nvariable site varchar2(10)\nexec :site := '%s'\n%s\n%s\nexit\n" \
    "${3:-}" "$1" "$2" "$PLANQ" | app_sql | grep -E '^ *[0-9]+ *$|^ORA-|^PLAN=' | sed 's/^ *//; s/ *$//'
}
# report <site> [predicate] [tag] [session-setup]: the standard report with that predicate
report() {
  raw "$1" "select /* ${3:-$TAG} */ count(*) from readings r join sensors s on s.sensor_id = r.sensor_id where s.site = :site and s.kind = 'TEMP' and ${2:-to_number(r.val) > 150};" "${4:-}"
}
first() { printf '%s\n' "$1" | grep -v '^PLAN=' | head -1 | grep -oE '^[0-9]+$|^ORA-[0-9]+' || true; }
plan() { printf '%s\n' "$1" | grep '^PLAN=' | head -1 | sed 's/^PLAN=//'; }
show() { printf '%s\n' "$1" | grep -v '^PLAN=' | sed 's/^/     /'; }
expect() {  # expect <label> <got> <want>
  [ "$2" = "$3" ] || die "$1: expected $3, got $2"
}

# gather [nohist]: the lab's one statistics call (identical every time). nohist: no histograms at all.
gather() {
  local m="FOR ALL COLUMNS SIZE 1 FOR COLUMNS SITE SIZE 254, KIND SIZE 254"
  [ "${1:-}" = nohist ] && m="FOR ALL COLUMNS SIZE 1"
  pdb_sql >/dev/null <<EOF
whenever sqlerror exit failure
exec dbms_stats.gather_table_stats('APP', 'SENSORS', method_opt => '$m', no_invalidate => false)
exec dbms_stats.gather_table_stats('APP', 'READINGS', method_opt => 'FOR ALL COLUMNS SIZE 1', no_invalidate => false)
EOF
}
# stats: READINGS rows / SENSORS.SITE distinct values / the columns that have a histogram
STATSQ="select (select num_rows from dba_tables where owner = 'APP' and table_name = 'READINGS') || '/' ||
  (select num_distinct from dba_tab_col_statistics where owner = 'APP' and table_name = 'SENSORS' and column_name = 'SITE') || '/' ||
  nvl((select listagg(column_name || ':' || histogram, ',') within group (order by column_name)
   from dba_tab_col_statistics where owner = 'APP' and histogram <> 'NONE'), 'none') from dual;"

cmd_up() { docker compose up -d; wait_healthy; }

cmd_setup() {
  wait_healthy
  pdb_sql >/dev/null <<'EOF'
whenever sqlerror continue
begin for s in (select sid, serial# from v$session where username = 'APP') loop
  execute immediate 'alter system kill session ''' || s.sid || ',' || s.serial# || ''' immediate'; end loop; end;
/
drop user app cascade;
whenever sqlerror exit failure
create user app identified by App_Passw0rd1 default tablespace users quota unlimited on users;
grant create session, create table, create view to app;
-- for DBMS_XPLAN.DISPLAY_CURSOR of the session's own last statement
grant select on v_$session to app;
grant select on v_$sql to app;
grant select on v_$sql_plan to app;
grant select on v_$sql_plan_statistics_all to app;
create table app.sensors (sensor_id number primary key, site varchar2(10) not null, kind varchar2(10) not null);
insert into app.sensors
  select level, case when level > 500 then 'HQ' else 'S' || lpad(mod(level, 100), 3, '0') end,
         case when mod(level, 10) = 0 then 'STATUS' else 'TEMP' end
  from dual connect by level <= 1000;
create table app.readings (reading_id number primary key,
  sensor_id number not null references app.sensors, val varchar2(20));
insert into app.readings
  select level, ceil(level / 500),
         case when mod(ceil(level / 500), 10) = 0
              then case mod(level, 3) when 0 then 'OK' when 1 then 'ALARM' else 'n/a' end
              else to_char(mod(level, 400) / 2) end
  from dual connect by level <= 500000;
commit;
create index app.readings_sensor_ix on app.readings (sensor_id);
EOF
  gather "${1:-}"
  pdb_sql >/dev/null <<'EOF'
alter system flush shared_pool;
EOF
}

cmd_day1() {
  cmd_setup
  echo ">> DAY 1: the first execution after the hard parse is a small site"
  local a b p
  a=$(report S007); b=$(report HQ); p=$(plan "$b")
  echo "   S007 (5 sensors, first): $(first "$a")   [$(plan "$a")]"
  echo "   HQ (500 sensors, same cursor): $(first "$b")   [$p]"
  expect "S007 on day 1" "$(first "$a")" 495
  expect "HQ on day 1" "$(first "$b")" 54450
  expect "S007 plan on day 1" "$(plan "$a")" "$p"
  [ "${p% *}" = "NESTED LOOPS" ] || die "expected NESTED LOOPS on day 1, got $p"
  echo "   -> TO_NUMBER only runs on readings of the site's TEMP sensors, fetched through the index. Both work."
  DAY1_PLAN=$p
}

cmd_day2() {
  [ -n "${DAY1_PLAN:-}" ] || cmd_day1
  echo ">> DAY 2: no data changes; the nightly stats gather invalidates the cursor; HQ runs first"
  local n0 n1 a b p
  n0=$(pdb_val "$STATSQ")
  gather
  n1=$(pdb_val "$STATSQ")
  echo "   statistics before the gather: $n0"
  echo "   statistics after the gather:  $n1   (READINGS rows / SENSORS.SITE distinct values / histograms)"
  expect "stats after the gather" "$n1" "$n0"
  local c
  a=$(report HQ); b=$(report S007); c=$(report S042); p=$(plan "$a")
  echo "   HQ (first):   [$p]"; show "$a"
  echo "   S007 (worked yesterday, same cursor): $(first "$b")   [$(plan "$b")]"
  echo "   S042 (another small site): $(first "$c")   [$(plan "$c")]"
  echo "   day 1 plan: $DAY1_PLAN"
  expect "HQ on day 2" "$(first "$a")" ORA-01722
  expect "S007 on day 2" "$(first "$b")" ORA-01722
  expect "S042 on day 2" "$(first "$c")" ORA-01722
  [ "${p% *}" = "HASH JOIN" ] || die "expected HASH JOIN on day 2, got $p"
  [ "${p#* * }" != "${DAY1_PLAN#* * }" ] || die "expected a different plan hash value from day 1 ($DAY1_PLAN), got $p"
  expect "S007 plan on day 2" "$(plan "$b")" "$p"
  expect "S042 plan on day 2" "$(plan "$c")" "$p"
  echo "   -> the full scan of READINGS applies TO_NUMBER to every row, STATUS sensors' text included."
  echo "   -> the estimate for HQ was right (the histogram), so nothing marks the cursor for reoptimization:"
  echo "      it keeps the hash join, and every site fails."
  echo "   >>> adaptive plan, both branches (rows marked - are inactive):"
  pdb_sql <<EOF | grep -E '^\||^ +[0-9]+ - |Note|adaptive' | sed 's/^/     /'
set pages 0 feedback off heading off lines 200
select plan_table_output from table(dbms_xplan.display_cursor(
  (select sql_id from v\$sql where sql_text like 'select /* $TAG */%' and parsing_schema_name = 'APP' and object_status = 'VALID'
   and is_obsolete = 'N' order by last_active_time desc fetch first 1 row only), null, 'BASIC +PREDICATE +NOTE +ADAPTIVE'));
EOF
  echo ">> DAY 3: the next stats gather invalidates the cursor again; this time a small site runs first"
  gather
  a=$(report S042); b=$(report HQ); p=$(plan "$b")
  echo "   S042 (first): $(first "$a")   [$(plan "$a")],  HQ: $(first "$b")   [$p]"
  expect "S042 on day 3" "$(first "$a")" 495
  expect "HQ on day 3" "$(first "$b")" 54450
  [ "${p% *}" = "NESTED LOOPS" ] || die "expected NESTED LOOPS on day 3, got $p"
  echo "   -> it \"fixed itself\". Nothing was fixed: the bad rows are still there, waiting for the next hard parse."
}

cmd_nohist() {
  cmd_setup nohist
  echo ">> NOHIST: the same day 2, but no histograms anywhere (the optimizer guesses ~10 sensors for any site)"
  local a b p ro
  a=$(report S007); b=$(report HQ)
  expect "S007 first, no histograms" "$(first "$a")" 495
  gather nohist
  a=$(report HQ); p=$(plan "$a")
  ro=$(pdb_val "select listagg(child_number || ':' || is_reoptimizable, ',') within group (order by child_number) from v\$sql where sql_text like 'select /* $TAG */%' and parsing_schema_name = 'APP' and object_status = 'VALID' and is_obsolete = 'N';")
  b=$(report S007)
  echo "   HQ (first): $(first "$a")   [$p]   cursor child:reoptimizable = $ro"
  echo "   S007 next: $(first "$b")   [$(plan "$b")]"
  expect "HQ first, no histograms" "$(first "$a")" ORA-01722
  [ "${p% *}" = "HASH JOIN" ] || die "expected HASH JOIN for HQ without histograms, got $p"
  expect "reoptimizable after HQ's failed execution" "$ro" "0:Y"
  expect "S007 after HQ, no histograms" "$(first "$b")" 495
  [ "$(plan "$b" | cut -d' ' -f1-2)" = "NESTED LOOPS" ] || die "expected a NESTED LOOPS child for S007, got $(plan "$b")"
  echo "   -> HQ's 450 sensors against an estimate of ~10: statistics feedback gave the next execution a new child."
  echo "      With the histogram (day 2) the estimate was right and nothing was reoptimized."
}

cmd_noindex() {
  cmd_setup
  echo ">> NOINDEX: READINGS.SENSOR_ID has no index (not built yet after a migration, or dropped as unused)"
  pdb_sql >/dev/null <<'EOF'
whenever sqlerror exit failure
drop index app.readings_sensor_ix;
EOF
  local a p
  a=$(report S007 "to_number(r.val) > 150" noindex-report); p=$(plan "$a")
  echo "   S007 (first, small site):"; show "$a"
  echo "   plan: $p"
  expect "S007 without the index" "$(first "$a")" ORA-01722
  [ "${p% *}" = "HASH JOIN" ] || die "expected HASH JOIN without the index, got $p"
}

cmd_message() {
  cmd_setup
  echo ">> MESSAGE: what 26ai tells you"
  local a bad sensors
  a=$(report HQ)
  show "$a"
  printf '%s\n' "$a" | grep -q 'to a number: VAL' || die "expected the message to name VAL"
  printf '%s\n' "$a" | grep -qE "invalid string value: (OK|ALARM|n/a)" || die "expected a STATUS value in ORA-03302"
  echo "   >>> the bad values: validate_conversion(val as number) = 0"
  pdb_sql <<'EOF' | grep -v '^$' | grep -v '^Session' | sed 's/^/     /'
set pages 100 feedback off lines 120
col val format a10
select r.val, s.kind, count(*) rows_
from app.readings r join app.sensors s on s.sensor_id = r.sensor_id
where validate_conversion(r.val as number) = 0 group by r.val, s.kind order by 1;
EOF
  bad=$(pdb_val "select count(distinct val)||'/'||count(*) from app.readings where validate_conversion(val as number) = 0;")
  sensors=$(pdb_val "select listagg(distinct s.kind) from app.readings r join app.sensors s on s.sensor_id = r.sensor_id where validate_conversion(r.val as number) = 0;")
  expect "bad values / rows" "$bad" 3/50000
  expect "kind of the sensors with bad values" "$sensors" STATUS
}

cmd_guards() {
  cmd_setup
  echo ">> GUARDS: each runs with HQ first"
  local a
  a=$(raw HQ "select /* g-view */ count(*) from (select r.val from readings r join sensors s on s.sensor_id = r.sensor_id where s.site = :site and s.kind = 'TEMP') where to_number(val) > 150;")
  echo "   filter in an inline view, TO_NUMBER outside: $(first "$a")"; expect "inline view" "$(first "$a")" ORA-01722; expect "inline view plan" "$(plan "$a" | cut -d' ' -f1-2)" "HASH JOIN"
  a=$(raw HQ "select /* g-nomerge */ count(*) from (select /*+ no_merge */ r.val from readings r join sensors s on s.sensor_id = r.sensor_id where s.site = :site and s.kind = 'TEMP') where to_number(val) > 150;")
  echo "   the same view with NO_MERGE: $(first "$a")"; expect "NO_MERGE view" "$(first "$a")" ORA-01722; expect "NO_MERGE plan" "$(plan "$a" | cut -d' ' -f1-2)" "HASH JOIN"
  a=$(report HQ "r.val = 150" g-implicit)
  echo "   VAL = 150 (no TO_NUMBER in the text; Oracle adds one to the column): $(first "$a")"; expect "implicit" "$(first "$a")" ORA-01722; expect "implicit plan" "$(plan "$a" | cut -d' ' -f1-2)" "HASH JOIN"
  a=$(report HQ "r.val = '150'" g-string)
  echo "   VAL = '150' (string compare): $(first "$a")"
  [[ "$(first "$a")" =~ ^[0-9]+$ ]] || die "expected a count for VAL = '150', got $a"
  echo "   >>> the NO_MERGE plan: the view stays, the filter still goes into the scan"
  pdb_sql <<'EOF' | grep -E '^\||^ +[0-9]+ - ' | sed 's/^/     /'
set pages 0 feedback off heading off lines 200
select plan_table_output from table(dbms_xplan.display_cursor(
  (select sql_id from v$sql where sql_text like 'select /* g-nomerge */%' and parsing_schema_name = 'APP'
   order by last_active_time desc fetch first 1 row only), null, 'BASIC +PREDICATE'));
EOF
}

fix_one() {  # fix_one <label> <predicate> <tag> [session-setup] [want-HQ]: HQ first (gets the HASH JOIN), then S007
  local a b p
  a=$(report HQ "$2" "$3" "${4:-}"); p=$(plan "$a"); b=$(report S007 "$2" "$3" "${4:-}")
  echo "   $1: HQ $(first "$a") [$p], then S007 $(first "$b")"
  [ "${p% *}" = "HASH JOIN" ] || die "$1: expected HQ on the HASH JOIN plan, got $p"
  expect "$1 HQ" "$(first "$a")" "${5:-54450}"
  if [ -z "${5:-}" ]; then expect "$1 S007" "$(first "$b")" 495; fi
}

cmd_fix() {
  cmd_setup
  echo ">> FIX: each runs with HQ first, so the cursor gets the plan that failed"
  fix_one "TO_NUMBER(r.val DEFAULT NULL ON CONVERSION ERROR)" "to_number(r.val default null on conversion error) > 150" f-default
  fix_one "CASE WHEN s.kind = 'TEMP' THEN TO_NUMBER(r.val) END" "case when s.kind = 'TEMP' then to_number(r.val) end > 150" f-case
  echo "   >>> the CASE plan: the conversion moved to the join, after the sensor filter"
  printf "set feedback off heading off pages 0 lines 200 serveroutput off\nvariable site varchar2(10)\nexec :site := 'HQ'\n%s\n%s\nexit\n" \
    "select /* f-case-plan */ count(*) from readings r join sensors s on s.sensor_id = r.sensor_id where s.site = :site and s.kind = 'TEMP' and case when s.kind = 'TEMP' then to_number(r.val) end > 150;" \
    "select plan_table_output from table(dbms_xplan.display_cursor(format => 'BASIC +PREDICATE'));" \
    | app_sql | grep -E '^\||^ +[0-9]+ - |^ +filter|^\s+>' | sed 's/^/     /'
}

cmd_nls() {
  cmd_setup
  echo ">> NLS: a session with a comma decimal separator (NLS_TERRITORY = GERMANY); HQ first in each"
  local de="alter session set nls_territory = GERMANY;" a
  a=$(report S007 "to_number(r.val) > 150" n-plain "$de")
  echo "   plain TO_NUMBER, small site, nested loops (no STATUS row involved):"; show "$a"
  expect "plain TO_NUMBER under GERMANY" "$(first "$a")" ORA-01722
  printf '%s\n' "$a" | grep -qE "invalid string value: [0-9]+\.5" || die "expected a decimal value in ORA-03302"
  fix_one "DEFAULT NULL ON CONVERSION ERROR, no error, wrong count" \
    "to_number(r.val default null on conversion error) > 150" n-default "$de" 26950
  echo "     -> every '150.5'-style value became NULL and dropped out. Nothing was raised."
  fix_one "TO_NUMBER with explicit NLS_NUMERIC_CHARACTERS" \
    "to_number(r.val default null on conversion error, '999999D9', 'NLS_NUMERIC_CHARACTERS = ''.,''') > 150" n-explicit "$de"
  pdb_sql >/dev/null <<'EOF'
whenever sqlerror exit failure
alter table app.readings add (val_num number generated always as
  (to_number(val default null on conversion error, '999999D9', 'NLS_NUMERIC_CHARACTERS = ''.,''')) virtual);
EOF
  fix_one "virtual column VAL_NUM (explicit format), GERMANY session" "r.val_num > 150" n-virtual-de "$de"
  fix_one "virtual column VAL_NUM (explicit format), default session" "r.val_num > 150" n-virtual
}

case "${1:-}" in
  up) cmd_up ;;
  setup) cmd_setup; echo "Schema ready." ;;
  day1) cmd_day1 ;; day2) cmd_day2 ;; nohist) cmd_nohist ;; noindex) cmd_noindex ;; message) cmd_message ;; guards) cmd_guards ;; fix) cmd_fix ;; nls) cmd_nls ;;
  all) cmd_day1; cmd_day2; cmd_nohist; cmd_noindex; cmd_message; cmd_guards; cmd_fix; cmd_nls; cmd_setup; echo ">> All checks passed." ;;
  sql) docker exec -it "$C" sqlplus / as sysdba ;;
  down) docker compose down ;;
  destroy) docker compose down -v ;;
  *) sed -n '2,50p' "$0"; exit 1 ;;
esac
