#!/usr/bin/env bash
# Oracle -> Kafka CDC lab (Debezium Oracle connector, LogMiner) — driver. Everything runs via `docker exec`, so you
# only need Docker (and python3 on the host to summarise the change events).
# Three containers: Oracle Database Free (currently 26ai), a single-node Kafka (KRaft) and Kafka Connect with the
# Debezium Oracle connector (3.7.1.Final). Every drill registers its own connector with the DEFAULT settings except the
# ones it names, takes the initial snapshot, makes changes in Oracle, and asserts what arrives in Kafka.
#
#   SETUP    : ARCHIVELOG + database-level minimal supplemental logging, the connector's LogMiner user c##dbzuser
#              (the grants from the Debezium documentation), and APP with three identical tables that differ only in
#              table-level supplemental logging: ORDERS (ALL) COLUMNS, ORDERS_PK (PRIMARY KEY) COLUMNS, ORDERS_MIN none.
#              Columns: ID NUMBER(10) PK, CUSTOMER, AMOUNT NUMBER(10,2), QTY NUMBER, STATUS, NOTE CLOB.
#              Kafka and Connect are recreated empty.
#
#   -- "The connector says RUNNING. The data is wrong." ------------------------------------------------------------
#   SUPPLOG  : the same UPDATE of STATUS on each table. Asserted: ORDERS -> the real key, every column in `after`;
#              ORDERS_PK -> the real key, but the unchanged columns are null ('' if NOT NULL); ORDERS_MIN -> key ID=0 and
#              CUSTOMER '' (NOT NULL columns get a default): an event for a row that doesn't exist. The connector stays
#              RUNNING; the only signal is one WARN per table in the Connect log when streaming starts.
#   LOB      : lob.enabled=false (the default), 8,000-character CLOBs. Asserted: an UPDATE of a CLOB that had a value
#              produces NO event (a later marker update does arrive); an UPDATE of a null CLOB arrives with NOTE null;
#              an INSERT arrives with NOTE null; a 5-character CLOB arrives (an insert, then an update). With
#              lob.enabled=true the update and an insert arrive with all 8,000 characters, one event each.
#   PLACEHLD : an UPDATE that doesn't touch the CLOB. Asserted (both lob settings): `after.NOTE` is the literal string
#              __debezium_unavailable_value.
#   NUMBERS  : decimal.handling.mode=precise (the default) with the JSON converter's schemas off. Asserted: AMOUNT
#              100.50 arrives as the base64 string "J0I=" and the unconstrained QTY as a {scale,value} object;
#              with decimal.handling.mode=string they arrive as "100.50"-style strings.
#
#   -- "Debezium restarts fine until the archived logs are gone." ---------------------------------------------------
#   PINNED   : a session updates a row and sits idle with the transaction open. Asserted: committed changes keep
#              arriving (offset commit_scn moves past it) but offset scn -- where a restart and every LogMiner session
#              begin -- stays just before the open transaction's START_SCN; it moves once the transaction ends.
#   PURGE    : the same, then RMAN 'delete archivelog all'. Asserted: at the next log switch the task FAILS with
#              "None of the log files contain offset SCN: <scn>" (the message suggests a slow archiver); a change
#              committed after the purge is not delivered; a restart fails with "no longer available on the server";
#              snapshot.mode=when_needed recovers with a NEW snapshot (every row sent again as op=r).
#   SAFEPURGE: the same, but delete only archived logs whose NEXT_CHANGE# <= the offset scn. Asserted: a task restart
#              resumes with no new snapshot and later changes arrive.
#   RETENTION: log.mining.transaction.retention.ms=30000 and a 60-second transaction that COMMITS. Asserted: the row
#              is in Oracle and never reaches Kafka (Debezium logs "is being abandoned").
#   SYSDDL   : ADD COLUMN on a captured table. Asserted: by the owner and by a deploy account with ALTER ANY TABLE,
#              the next insert arrives; by SYSTEM, the next insert fails with DmlParserException and stops the task,
#              and a restart fails the same way; a new connector runs; by SYS, the same failure. With
#              log.mining.schema_changes.username.exclude.list (default SYS,SYSTEM) set to another user, still FAILED.
#
#   ./run.sh up          # start the three containers (first run pulls ~7 GB of images)
#   ./run.sh setup       # ARCHIVELOG, users, tables; empty Kafka + Connect (resets the lab; safe to rerun)
#   ./run.sh supplog     # table-level supplemental logging: ALL vs PRIMARY KEY vs none
#   ./run.sh lob         # large CLOBs with lob.enabled false, then true
#   ./run.sh placeholder # an unchanged CLOB in an update event
#   ./run.sh numbers     # NUMBER(10,2) and NUMBER on the wire, precise vs string
#   ./run.sh pinned      # an idle open transaction holds the restart position back
#   ./run.sh purge       # delete the archived logs: failure at the next log switch, recovery by re-snapshot
#   ./run.sh safepurge   # delete only what is below the connector's offset scn: restart works
#   ./run.sh retention   # transaction retention silently drops a committed long transaction
#   ./run.sh sysddl      # DDL as the owner / a deploy account works; as SYSTEM or SYS it stops the connector
#   ./run.sh all         # every drill, each from setup
#   ./run.sh sql         # SQL*Plus as SYSDBA
#   ./run.sh down / destroy
set -euo pipefail
cd "$(dirname "$0")"

C=ora-debezium-cdc-lab
K=kafka-debezium-cdc-lab
W=connect-debezium-cdc-lab
export LAB_PORT="${LAB_PORT:-1521}"
APP="app/App_Passw0rd1@localhost:1521/FREEPDB1"
PH="__debezium_unavailable_value"

die() { echo "!! FAIL: $*" >&2; exit 1; }
ok()  { echo "   OK: $*"; }
run_sys() { docker exec -i "$C" sqlplus -s -L "/ as sysdba"; }
pdb_sql() { { printf 'alter session set container = FREEPDB1;\n'; cat; printf '\nexit\n'; } | run_sys; }
app_sql() { { cat; printf '\nexit\n'; } | docker exec -i "$C" sqlplus -s -L "$APP" 2>&1 || true; }
app_val() { printf 'set heading off feedback off pages 0 lines 300\n%s\n' "$1" | app_sql | grep -v '^$' | head -1; }
sig() { printf '%s\n' "$1" | tr -d '\r' | grep -o "$2=[^ ]*" | head -1 | cut -d= -f2- || true; }

wait_healthy() {
  echo "Waiting for the database to be ready..."
  for _ in $(seq 1 90); do
    if docker exec "$C" healthcheck.sh >/dev/null 2>&1; then echo "Database is ready."; return 0; fi
    sleep 5
  done
  die "timed out waiting for the database"
}

rest() { # rest <METHOD> <path> [json]
  if [ $# -ge 3 ]; then
    docker exec -i "$W" curl -s -X "$1" -H 'Content-Type: application/json' "localhost:8083$2" -d @- <<<"$3"
  else
    docker exec "$W" curl -s -X "$1" "localhost:8083$2"
  fi
}

wait_connect() {
  for _ in $(seq 1 60); do
    if rest GET / 2>/dev/null | grep -q '"version"'; then return 0; fi
    sleep 3
  done
  die "Kafka Connect REST API did not come up"
}

task_state() { rest GET "/connectors/$1/status" | grep -o '"tasks":\[{"id":0,"state":"[A-Z]*"' | grep -o '[A-Z]*"$' | tr -d '"' || true; }
task_trace() { rest GET "/connectors/$1/status" | python3 -c 'import sys,json; d=json.load(sys.stdin); print((d.get("tasks") or [{}])[0].get("trace","").splitlines()[0] if (d.get("tasks") or [{}])[0].get("trace") else "")' 2>/dev/null || true; }
wait_task() { # wait_task <name> <STATE> [seconds]
  local s=""
  for _ in $(seq 1 "$(( ${3:-90} / 3 ))"); do
    s=$(task_state "$1"); [ "$s" = "$2" ] && return 0
    sleep 3
  done
  die "connector $1: expected task state $2, got '${s:-none}' $(task_trace "$1")"
}

# register <name> <table.include.list> [extra "key":"value" pairs]: the documented minimum config + the extras.
register() {
  local n=$1 t=$2 x=${3:-}
  rest POST /connectors "{\"name\":\"$n\",\"config\":{
    \"connector.class\":\"io.debezium.connector.oracle.OracleConnector\",\"tasks.max\":\"1\",
    \"database.hostname\":\"oracle\",\"database.port\":\"1521\",\"database.user\":\"c##dbzuser\",
    \"database.password\":\"dbz\",\"database.dbname\":\"FREE\",\"database.pdb.name\":\"FREEPDB1\",
    \"topic.prefix\":\"$n\",\"table.include.list\":\"$t\",
    \"schema.history.internal.kafka.bootstrap.servers\":\"kafka:9092\",
    \"schema.history.internal.kafka.topic\":\"$n.history\"${x:+,$x}}}" >/dev/null
  wait_task "$n" RUNNING
}

# events <topic> <min events> [seconds]: every event on the topic so far, summarised by scripts/ev.py, one per line.
# Polls until at least <min> events have arrived (CDC is asynchronous; no fixed sleeps).
events() {
  local out="" n=0
  for _ in $(seq 1 "$(( ${3:-60} / 5 ))"); do
    out=$(docker exec "$K" /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server kafka:9092 --topic "$1" \
      --from-beginning --timeout-ms 5000 --property print.key=true --property key.separator='|' 2>/dev/null \
      | python3 scripts/ev.py || true)
    n=$(printf '%s' "$out" | grep -c '^op=' || true)
    [ "$n" -ge "$2" ] && break
  done
  printf '%s\n' "$out"
}
count() { printf '%s\n' "$1" | grep -c -- "$2" || true; }

cmd_up() { docker compose up -d; wait_healthy; wait_connect; }

cmd_setup() {
  wait_healthy
  echo ">> ARCHIVELOG + minimal supplemental logging (bounces the instance the first time)..."
  local m
  m=$(run_sys < scripts/archivelog.sql 2>&1 || true)
  [ "$(sig "$m" LOGMODE)" = "ARCHIVELOG" ] || die "expected ARCHIVELOG mode: $m"
  [ "$(sig "$m" SUPMIN)" = "YES" ] || die "expected minimal supplemental logging"
  echo ">> The connector's LogMiner user and the APP tables..."
  run_sys < scripts/dbzuser.sql >/dev/null 2>&1 || true
  m=$(run_sys < scripts/app.sql 2>&1 || true)
  [ "$(sig "$m" TABLES)" = "3" ] || die "expected 3 APP tables: $m"
  echo "   $(sig "$m" LOGGROUPS)"
  echo ">> Fresh, empty Kafka and Kafka Connect..."
  docker compose up -d --force-recreate kafka connect >/dev/null 2>&1
  wait_connect
  echo ">> Setup complete."
}

big() { printf "to_clob(rpad('%s',4000,'%s')) || to_clob(rpad('%s',4000,'%s'))" "$1" "$1" "$1" "$1"; }

# ---------------------------------------------------------------------------------------------------------- SUPPLOG
cmd_supplog() {
  echo "== SUPPLOG: the same UPDATE on three tables that differ only in table-level supplemental logging =="
  register supplog "APP.ORDERS,APP.ORDERS_PK,APP.ORDERS_MIN"
  events supplog.APP.ORDERS_MIN 2 >/dev/null
  app_sql >/dev/null <<'SQL'
update orders     set status = 'PAID' where id = 1;
update orders_pk  set status = 'PAID' where id = 1;
update orders_min set status = 'PAID' where id = 1;
commit;
SQL
  local e t
  for t in ORDERS ORDERS_PK ORDERS_MIN; do
    e=$(events "supplog.APP.$t" 3 | grep '^op=u' || true)
    echo "   $t: ${e:-<no update event>}"
    eval "U_$t=\"\$e\""
  done
  # shellcheck disable=SC2154
  { printf '%s' "$U_ORDERS" | grep -q 'key=1 id=1 cust=ACME status=PAID amount="J0I="'; } \
    || die "ORDERS: expected the full row with the real key"
  ok "ORDERS (ALL) COLUMNS: key 1, CUSTOMER ACME, AMOUNT present"
  { printf '%s' "$U_ORDERS_PK" | grep -q 'key=1 id=1 cust= status=PAID amount=null'; } \
    || die "ORDERS_PK: expected the real key and null unchanged columns"
  ok "ORDERS_PK (PRIMARY KEY) COLUMNS: key 1, but CUSTOMER '' (NOT NULL, so an empty string) and AMOUNT null"
  { printf '%s' "$U_ORDERS_MIN" | grep -q 'key=0 id=0 cust= status=PAID amount=null'; } \
    || die "ORDERS_MIN: expected key 0 and null columns"
  ok "ORDERS_MIN (no table-level logging): key 0 (ID is NOT NULL: 0), CUSTOMER '', AMOUNT null -- an update for a row that doesn't exist"
  [ "$(task_state supplog)" = "RUNNING" ] || die "expected the connector to still be RUNNING"
  ok "the connector is RUNNING; its status says nothing is wrong"
  local w
  w=$(docker logs "$W" 2>&1 | grep -c "not configured with supplemental logging \"(ALL) COLUMNS\"" || true)
  [ "${w:-0}" -ge 2 ] || die "expected Debezium's WARN for ORDERS_PK and ORDERS_MIN in the Connect log"
  ok "the only signal: one WARN per table in the Connect log when streaming starts (\"only explicitly changed columns will be captured\")"
}

# -------------------------------------------------------------------------------------------------------------- LOB
cmd_lob() {
  echo "== LOB: 8,000-character CLOBs with lob.enabled=false (the default), then true =="
  register lobdef "APP.ORDERS"
  events lobdef.APP.ORDERS 2 >/dev/null
  app_sql >/dev/null <<SQL
update orders set note = $(big a) where id = 1;
commit;
update orders set note = $(big b) where id = 2;
commit;
insert into orders values (3, 'INITECH', 75.25, 1, 'NEW', $(big c));
commit;
insert into orders values (4, 'UMBRELLA', 10.00, 1, 'NEW', 'hello');
commit;
update orders set status = 'MARKER' where id = 4;
commit;
SQL
  local e
  e=$(events lobdef.APP.ORDERS 7)
  printf '%s\n' "$e" | sed -n '3,$p' | sed 's/^/   /'
  [ "$(count "$e" 'status=MARKER')" -ge 1 ] || die "the marker update did not arrive"
  [ "$(count "$e" 'op=u key=1 ')" = "0" ] || die "expected NO event for row 1's 8,000-character update"
  ok "row 1 (CLOB 'first order' -> 8,000 characters): no event at all; the later marker did arrive"
  [ "$(count "$e" 'op=u key=2 .*note=null')" = "1" ] || die "expected row 2's update with NOTE null"
  ok "row 2 (CLOB null -> 8,000 characters): an update event with NOTE null"
  [ "$(count "$e" 'op=c key=3 .*note=null')" = "1" ] || die "expected row 3's insert with NOTE null"
  [ "$(count "$e" 'note=len:8000')" = "0" ] || die "did not expect any 8,000-character value"
  ok "row 3 (insert with 8,000 characters): arrived with NOTE null; the 8,000 characters never did"
  [ "$(count "$e" 'key=4 .*note=len:5')" -ge 1 ] || die "expected row 4's 5-character CLOB to arrive"
  ok "row 4 (insert with 'hello'): arrived, as an insert with NOTE null followed by an update -- small test data hides it"
  echo "   in Oracle, CLOB length by ID: $(app_val "select listagg(id || '=' || nvl(dbms_lob.getlength(note), 0), ' ') within group (order by id) from orders;")"

  register lobon "APP.ORDERS" '"lob.enabled":"true"'
  events lobon.APP.ORDERS 4 >/dev/null
  app_sql >/dev/null <<SQL
update orders set note = $(big d) where id = 1;
commit;
insert into orders values (5, 'HOOLI', 1, 1, 'NEW', $(big e));
commit;
SQL
  e=$(events lobon.APP.ORDERS 6)
  printf '%s\n' "$e" | grep -v 'op=r' | sed 's/^/   /'
  [ "$(count "$e" 'op=u key=1 .*note=len:8000')" = "1" ] || die "expected row 1's 8,000-character update with lob.enabled=true"
  [ "$(count "$e" 'op=c key=5 .*note=len:8000')" = "1" ] || die "expected row 5's insert with 8,000 characters"
  ok "lob.enabled=true: the update and the insert both arrive with all 8,000 characters, one event each"
}

# ---------------------------------------------------------------------------------------------------- PLACEHOLDER
cmd_placeholder() {
  echo "== PLACEHOLDER: an UPDATE that doesn't touch the CLOB =="
  local mode e
  for mode in false true; do
    register "ph$mode" "APP.ORDERS" "\"lob.enabled\":\"$mode\""
    events "ph$mode.APP.ORDERS" 2 >/dev/null
    printf "update orders set status = 'SHIP-%s' where id = 1;\ncommit;\n" "$mode" | app_sql >/dev/null
    e=$(events "ph$mode.APP.ORDERS" 3 | grep "status=SHIP-$mode" || true)
    echo "   lob.enabled=$mode: $e"
    printf '%s' "$e" | grep -q 'note=PLACEHOLDER' || die "expected after.NOTE = $PH with lob.enabled=$mode"
    ok "lob.enabled=$mode: after.NOTE is the string $PH (the row's CLOB is 'first order')"
  done
}

# -------------------------------------------------------------------------------------------------------- NUMBERS
cmd_numbers() {
  echo "== NUMBERS: NUMBER(10,2) and NUMBER with schemas off =="
  local e
  register numprecise "APP.ORDERS"
  e=$(events numprecise.APP.ORDERS 2)
  printf '%s\n' "$e" | sed 's/^/   precise: /'
  printf '%s' "$e" | grep -q 'key=1 .*amount="J0I=" qty={"scale":0,"value":"Aw=="}' \
    || die "expected AMOUNT \"J0I=\" and QTY {scale,value} for row 1"
  printf '%s' "$e" | grep -q 'key=2 .*qty={"scale":3,' || die "expected QTY scale 3 for row 2"
  ok "precise (default): AMOUNT 100.50 -> \"J0I=\" (base64 of 10050, scale not in the message); QTY 3 -> {scale 0, \"Aw==\"}"
  register numstring "APP.ORDERS" '"decimal.handling.mode":"string"'
  e=$(events numstring.APP.ORDERS 2)
  printf '%s\n' "$e" | sed 's/^/   string:  /'
  printf '%s' "$e" | grep -q 'key=1 .*amount="100.50" qty="3"' || die "expected \"100.50\" and \"3\" with string mode"
  printf '%s' "$e" | grep -q 'key=2 .*qty="1234567.891"' || die "expected \"1234567.891\" with string mode"
  ok "string: \"100.50\", \"3\", \"1234567.891\""
}

# ============================================== "Debezium restarts fine until the archived logs are gone." ======
offset() { rest GET "/connectors/$1/offsets" | grep -o "\"$2\":\"[0-9]*" | grep -o '[0-9]*$' | head -1 || true; }
switch_logs() { printf 'alter system switch logfile;\nalter system switch logfile;\nalter system archive log current;\nexit\n' | run_sys >/dev/null; }
purge_all() { docker exec -i "$C" rman target / <<<'delete noprompt archivelog all;' 2>&1 | grep -c 'deleted archived log' || true; }
cdb_val() { printf 'set heading off feedback off pages 0 lines 300\n%s\nexit\n' "$1" | run_sys | grep -v '^$' | head -1 | tr -d ' \t'; }

# hold_open: a session that updates row 2 and then sits idle (INACTIVE) with the transaction open, like a forgotten
# session in a tool or a pooled connection that never committed. end_hold rolls it back.
HOLD_PID=""
HOLD_STOP="$PWD/.hold-stop"
hold_open() {
  rm -f "$HOLD_STOP"
  ( printf "update orders set status = 'IDLE-TX' where id = 2;\n"
    for _ in $(seq 1 600); do [ -f "$HOLD_STOP" ] && break; sleep 1; done
    printf "rollback;\nexit\n" ) | docker exec -i "$C" sqlplus -s -L "$APP" >/dev/null 2>&1 &
  HOLD_PID=$!
  for _ in $(seq 1 20); do
    [ "$(cdb_val "select count(*) from v\$transaction;")" -ge 1 ] 2>/dev/null && return 0; sleep 1
  done
  die "the open transaction did not start"
}
trap 'touch "$HOLD_STOP" 2>/dev/null || true' EXIT
end_hold() { touch "$HOLD_STOP"; [ -n "$HOLD_PID" ] && wait "$HOLD_PID" 2>/dev/null || true; HOLD_PID=""; rm -f "$HOLD_STOP"; }

# pin_and_commit <connector>: with a transaction open, commit 3 changes with log switches; prints "scn commit_scn txstart"
pin_and_commit() {
  local i scn cscn txs=""
  txs=$(cdb_val "select min(start_scn) from v\$transaction;")
  for i in 1 2 3; do
    printf "update orders set amount = amount + 1 where id = 1;\ncommit;\n" | app_sql >/dev/null
    switch_logs
  done
  events "$1.APP.ORDERS" 5 >/dev/null
  for _ in $(seq 1 20); do
    cscn=$(offset "$1" commit_scn); scn=$(offset "$1" scn)
    [ -n "$cscn" ] && [ "$cscn" -gt "$txs" ] && break; sleep 2
  done
  echo "$scn $cscn $txs"
}

cmd_pinned() {
  echo "== PINNED: an idle open transaction holds the connector's restart position back =="
  register pinned "APP.ORDERS"
  events pinned.APP.ORDERS 2 >/dev/null
  hold_open
  local r scn cscn txs
  r=$(pin_and_commit pinned); read -r scn cscn txs <<<"$r"
  echo "   open transaction START_SCN=$txs; connector offset: scn=$scn (restart from here) commit_scn=$cscn (delivered up to here)"
  [ "$scn" -lt "$txs" ] && [ "$cscn" -gt "$txs" ] || die "expected scn < START_SCN < commit_scn"
  ok "every committed change was delivered (commit_scn moved past it), but scn stays before the open transaction"
  echo "   the session holding it:"
  printf "set lines 200 pages 50\ncol username format a10\ncol status format a8\nselect s.sid, s.username, s.status, t.start_scn, round((sysdate - t.start_date) * 86400) open_seconds, s.last_call_et idle_seconds from v\$transaction t join v\$session s on s.saddr = t.ses_addr;\nexit\n" \
    | run_sys | grep -v '^$' | sed 's/^/   /'
  end_hold
  for _ in $(seq 1 20); do scn=$(offset pinned scn); [ "$scn" -gt "$txs" ] && break
    printf "update orders set amount = amount + 1 where id = 1;\ncommit;\n" | app_sql >/dev/null; sleep 3; done
  [ "$scn" -gt "$txs" ] || die "expected scn to move once the transaction ended"
  ok "after the transaction rolled back, scn moved to $scn"
}

cmd_purge() {
  echo "== PURGE: archived logs deleted while a transaction is open =="
  register purge "APP.ORDERS"
  events purge.APP.ORDERS 2 >/dev/null
  hold_open
  local r scn cscn txs n e
  r=$(pin_and_commit purge); read -r scn cscn txs <<<"$r"
  echo "   connector offset scn=$scn commit_scn=$cscn; open transaction START_SCN=$txs"
  n=$(purge_all)
  echo "   RMAN 'delete archivelog all' (what a nightly job after a backup does): $n archived logs deleted"
  [ "$(task_state purge)" = "RUNNING" ] || die "expected RUNNING right after the purge"
  printf "update orders set customer = 'AFTER-PURGE' where id = 1;\ncommit;\n" | app_sql >/dev/null
  switch_logs
  wait_task purge FAILED 120
  e=$(docker logs "$W" 2>&1 | grep -m1 -o "None of the log files contain offset SCN: [0-9]*[^.]*\. This could be due to a slow archiver process[^.]*\." || true)
  echo "   at the next log switch the task FAILED:"
  echo "   $e"
  local mscn; mscn=$(printf '%s' "$e" | grep -o 'offset SCN: [0-9]*' | grep -o '[0-9]*$' || true)
  [ -n "$mscn" ] && [ "$mscn" -lt "$txs" ] && [ "$mscn" -ge "$scn" ] \
    || die "expected the SCN in the message to be the restart position, below START_SCN $txs (got '${mscn:-none}')"
  ok "the SCN it can't find ($mscn) is the restart position just before the open transaction; those logs are gone"
  [ "$(events purge.APP.ORDERS 5 10 | grep -c 'cust=AFTER-PURGE' || true)" = "0" ] || die "did not expect AFTER-PURGE to arrive"
  ok "the AFTER-PURGE change, committed in Oracle after the purge, was not delivered"
  rest POST /connectors/purge/tasks/0/restart >/dev/null
  sleep 5; wait_task purge FAILED 90
  echo "   after a task restart: FAILED -- $(task_trace purge | cut -c1-220)..."
  task_trace purge | grep -q "no longer available on the server" || die "expected the 'no longer available' error"
  ok "restarting doesn't help; the message suggests a slow archiver, the cause is a deleted log"
  end_hold
  echo "   recovery: snapshot.mode=when_needed"
  rest PUT /connectors/purge/config "$(rest GET /connectors/purge/config | python3 -c 'import sys,json; c=json.load(sys.stdin); c["snapshot.mode"]="when_needed"; print(json.dumps(c))')" >/dev/null
  rest POST /connectors/purge/tasks/0/restart >/dev/null
  sleep 5; wait_task purge RUNNING 120
  e=$(events purge.APP.ORDERS 9 120)
  [ "$(count "$e" 'op=r')" -ge 4 ] || die "expected a second snapshot (op=r again)"
  [ "$(count "$e" 'op=r .*cust=AFTER-PURGE')" = "1" ] || die "expected AFTER-PURGE to arrive in the new snapshot"
  ok "RUNNING again after a NEW snapshot: every row sent again as op=r; AFTER-PURGE arrived only as snapshot state"
}

cmd_safepurge() {
  echo "== SAFEPURGE: delete only the archived logs below the connector's offset scn =="
  register safe "APP.ORDERS"
  events safe.APP.ORDERS 2 >/dev/null
  hold_open
  local r scn cscn txs maxseq keep
  r=$(pin_and_commit safe); read -r scn cscn txs <<<"$r"
  maxseq=$(cdb_val "select nvl(max(sequence#), 0) from v\$archived_log where deleted = 'NO' and next_change# <= $scn;")
  keep=$(cdb_val "select count(*) from v\$archived_log where deleted = 'NO' and next_change# > $scn;")
  echo "   connector offset scn=$scn: deleting archived logs up to sequence $maxseq, keeping $keep that reach past it"
  if [ "${maxseq:-0}" -gt 0 ]; then
    docker exec -i "$C" rman target / <<<"delete noprompt archivelog sequence between 1 and $maxseq;" >/dev/null 2>&1 || true
  fi
  rest POST /connectors/safe/tasks/0/restart >/dev/null
  sleep 5; wait_task safe RUNNING 90
  printf "update orders set customer = 'AFTER-RESTART' where id = 1;\ncommit;\n" | app_sql >/dev/null
  local e; e=$(events safe.APP.ORDERS 6)
  [ "$(count "$e" 'cust=AFTER-RESTART')" -ge 1 ] || die "expected changes after the restart"
  [ "$(count "$e" 'op=r')" = "2" ] || die "expected no new snapshot (2 op=r events in total)"
  ok "restart resumed from scn $scn with no new snapshot; the AFTER-RESTART change arrived"
  end_hold
}

cmd_retention() {
  echo "== RETENTION: log.mining.transaction.retention.ms discards a long transaction -- even if it commits =="
  register retain "APP.ORDERS" '"log.mining.transaction.retention.ms":"30000"'
  events retain.APP.ORDERS 2 >/dev/null
  printf "insert into orders values (9, 'SLOW-BATCH', 1, 1, 'NEW', null);\nexec dbms_session.sleep(60)\ncommit;\n" | app_sql >/dev/null &
  local p=$! i e
  for i in 1 2 3 4; do sleep 12; switch_logs; printf "update orders set amount = amount + 1 where id = 1;\ncommit;\n" | app_sql >/dev/null; done
  wait "$p"
  printf "update orders set status = 'MARKER' where id = 1;\ncommit;\n" | app_sql >/dev/null
  e=$(events retain.APP.ORDERS 7)
  [ "$(count "$e" 'status=MARKER')" -ge 1 ] || die "the marker did not arrive"
  echo "   in Oracle: $(app_val "select count(*) || ' row with ID 9 (committed)' from orders where id = 9;")"
  echo "   on the topic: $(count "$e" 'key=9 ') events for ID 9"
  [ "$(count "$e" 'key=9 ')" = "0" ] || die "expected the 60-second transaction to be discarded"
  ok "the committed 60-second transaction never arrived: retention 30 s discarded it"
  docker logs "$W" 2>&1 | grep -i "abandon\|retention" | tail -1 | cut -c1-260 | sed 's/^/   log: /'
}

cmd_sysddl() {
  echo "== SYSDDL: ADD COLUMN on a captured table, by the owner, by a deploy account, by SYSTEM, by SYS =="
  printf "create user deployer identified by Dep_Passw0rd1;\ngrant create session, alter any table to deployer;\n" | pdb_sql >/dev/null 2>&1 || true
  register ddl "APP.ORDERS"
  events ddl.APP.ORDERS 2 >/dev/null
  printf "alter table orders add (region varchar2(10));\ninsert into orders (id, customer, status, region) values (10, 'OWNER-DDL', 'NEW', 'EU');\ncommit;\n" | app_sql >/dev/null
  [ "$(events ddl.APP.ORDERS 3 | grep -c 'key=10 ' || true)" -ge 1 ] || die "expected the row after the owner's DDL"
  ok "APP (the owner): the connector kept running and the next insert arrived"
  printf "alter table app.orders add (channel varchar2(10));\nexit\n" | docker exec -i "$C" sqlplus -s -L deployer/Dep_Passw0rd1@localhost:1521/FREEPDB1 >/dev/null
  printf "insert into orders (id, customer, status, channel) values (11, 'DEPLOY-DDL', 'NEW', 'WEB');\ncommit;\n" | app_sql >/dev/null
  [ "$(events ddl.APP.ORDERS 5 | grep -c 'key=11 ' || true)" -ge 1 ] || die "expected the row after the deployer's DDL"
  ok "DEPLOYER (ALTER ANY TABLE): the connector kept running and the next insert arrived"
  printf "alter table app.orders add (prio number(1));\nexit\n" | docker exec -i "$C" sqlplus -s -L system/Lab_Passw0rd1@localhost:1521/FREEPDB1 >/dev/null
  printf "insert into orders (id, customer, status, prio) values (12, 'SYSTEM-DDL', 'NEW', 1);\ncommit;\n" | app_sql >/dev/null
  wait_task ddl FAILED 90
  echo "   SYSTEM: task FAILED"
  docker logs "$W" 2>&1 | grep "Caused by" | grep -m1 -o "ArrayIndexOutOfBoundsException.*" | sed 's/^/   Caused by: /' || true
  [ "$(docker logs "$W" 2>&1 | grep -c "DmlParserException" || true)" -ge 1 ] || die "expected a DmlParserException"
  ok "SYSTEM: the next insert couldn't be parsed (DmlParserException) and the connector stopped"
  rest POST /connectors/ddl/tasks/0/restart >/dev/null; sleep 5; wait_task ddl FAILED 90
  ok "a task restart fails the same way"
  register ddlsys "APP.ORDERS"
  events ddlsys.APP.ORDERS 5 >/dev/null
  ok "a new connector, with a new snapshot, runs again"
  printf "alter table app.orders add (tier number(1));\n" | pdb_sql >/dev/null
  printf "insert into orders (id, customer, status, tier) values (13, 'SYS-DDL', 'NEW', 1);\ncommit;\n" | app_sql >/dev/null
  wait_task ddlsys FAILED 90
  ok "SYS: the same failure"
  register ddlfix "APP.ORDERS" '"log.mining.schema_changes.username.exclude.list":"NOBODY"'
  events ddlfix.APP.ORDERS 6 >/dev/null
  printf "alter table app.orders add (lvl number(1));\n" | pdb_sql >/dev/null
  printf "insert into orders (id, customer, status, lvl) values (14, 'SYS-DDL-2', 'NEW', 1);\ncommit;\n" | app_sql >/dev/null
  wait_task ddlfix FAILED 90
  ok "log.mining.schema_changes.username.exclude.list (default SYS,SYSTEM) set to another user: SYS's DDL still stops it"
}

cmd_all() {
  local d
  for d in supplog lob placeholder numbers pinned purge safepurge retention sysddl; do
    cmd_setup; "cmd_$d"
  done
  echo ">> ALL DRILLS PASSED"
}

case "${1:-}" in
  up) cmd_up ;;
  setup) cmd_setup ;;
  supplog|lob|placeholder|numbers|pinned|purge|safepurge|retention|sysddl|all) "cmd_$1" ;;
  sql) docker exec -it "$C" sqlplus / as sysdba ;;
  down) docker compose down ;;
  destroy) docker compose down -v ;;
  *) sed -n '2,70p' "$0"; exit 1 ;;
esac
