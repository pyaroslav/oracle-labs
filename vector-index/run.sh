#!/usr/bin/env bash
# Oracle AI Vector Search index lab — driver. Everything runs INSIDE the container via `docker exec`, so you only
# need Docker. Companion to the "26ai in practice" post on HNSW vs IVF vector indexes and the vector memory pool.
#
#   SETUP    : APP.DOCS (100,000 clustered VECTOR(128, FLOAT32)), APP.RND (100,000 uniform random), 20 query vectors
#              for each (scripts/app.sql, fixed seeds, no model). Puts VECTOR_MEMORY_SIZE (CDB and PDB) and the PDB's
#              SGA_TARGET back to their defaults, restarting the instance only if one of them isn't.
#   DEFAULT  : the image as shipped. Asserted: VECTOR_MEMORY_SIZE = 0; CREATE ... INMEMORY NEIGHBOR GRAPH (HNSW)
#              fails with ORA-51962; raising the pool online fails (ORA-51950 in the CDB, ORA-51955 in the PDB); an
#              IVF index (NEIGHBOR PARTITIONS) builds and a FETCH APPROX query uses it (its centroid partitions).
#   SIZING   : VECTOR_MEMORY_SIZE = 256M in the spfile + restart. Asserted: the buffer cache shrinks (the pool comes out of SGA_TARGET);
#              with the PDB limit at the docs' formula (1.3 x vectors x dims x 4 bytes = 63.5 MiB -> 64M) the HNSW
#              build fails with ORA-51962; at 90M, more than the finished index needs, it still fails; at 128M it
#              builds and the finished index uses 80-90 MiB. DBMS_VECTOR.INDEX_VECTOR_MEMORY_ADVISOR says 96.7 MiB,
#              which is about what the build needs (it failed at 95M and worked at 100M here); the CDB pool can now be raised
#              online but not lowered below its startup size (ORA-51953); a second vector index on the same column
#              fails with ORA-01408.
#   ACCURACY : exact top 10 (FETCH EXACT, a full scan) vs the HNSW index. Asserted: on clustered data the default
#              approximate search finds >= 99% of the exact top 10; on uniform random vectors it finds less than the
#              default target accuracy of 90%; a plain FETCH FIRST (no APPROX, no EXACT) uses the HNSW index and gets
#              exactly the same recall as FETCH APPROX; TARGET ACCURACY 100 finds more; a query
#              with a different distance metric from the index (EUCLIDEAN vs COSINE) does a full scan.
#   RESTART  : DML and restarts with the pool at 256M. Asserted: an insert, update and delete show up in the next
#              approximate search at once (uncommitted, in the same session) while V$VECTOR_INDEX.NUM_VECTORS stays
#              100,000; after a restart the index is reloaded and used again. Then the spfile pool is lowered to 64M
#              (smaller than the index) and the instance restarted: the index stays VALID, NUM_VECTORS is 0, every
#              approximate query silently runs as a full scan, nothing in the alert log; raising the pool online
#              doesn't reload it; DBMS_VECTOR.REBUILD_INDEX fails with ORA-51962 and the index is gone; CREATE fails
#              the same way until the PDB's VECTOR_MEMORY_SIZE is set again.
#   AUTOGROW : VECTOR_MEMORY_SIZE = 1 (the documented automatic growth mode) + restart. Asserted: the PDB can't set
#              its own limit (ORA-51999); HNSW fails with ORA-51995 while the PDB's SGA_TARGET is 0; with PDB
#              SGA_TARGET = 512M it builds, the pool grows, and after a restart the index is reloaded and used.
#
#   ./run.sh up        # start the database (first run pulls the image)
#   ./run.sh setup     # schema + default memory settings (resets the lab; safe to rerun)
#   ./run.sh default   # out of the box: HNSW fails, the pool can't be raised online, IVF works
#   ./run.sh sizing    # spfile + restart; formula vs advisor vs what the build needed
#   ./run.sh accuracy  # recall of approximate search; FETCH FIRST without APPROX; metric mismatch
#   ./run.sh restart   # DML, restart, and a pool that's too small after a restart
#   ./run.sh autogrow  # VECTOR_MEMORY_SIZE = 1 and the PDB SGA_TARGET it needs
#   ./run.sh all       # default -> sizing -> accuracy -> restart -> autogrow (each from setup), then setup
#   ./run.sh sql       # SQL*Plus as SYSDBA
#   ./run.sh down / destroy
set -euo pipefail
cd "$(dirname "$0")"

C=ora-vector-index-lab
export LAB_PORT="${LAB_PORT:-1521}"
HNSW="organization inmemory neighbor graph distance cosine"
IVF="organization neighbor partitions distance cosine"

die() { echo "!! FAIL: $*" >&2; exit 1; }
ok()  { echo "   OK: $*"; }
run_sys() { docker exec -i "$C" sqlplus -s -L "/ as sysdba"; }
cdb_sql() { { printf 'set lines 220 pages 200\n'; cat; printf '\nexit\n'; } | run_sys; }
pdb_sql() { { printf 'set lines 220 pages 200\nalter session set container = FREEPDB1;\n'; cat; printf '\nexit\n'; } | run_sys; }
val() { printf 'set pages 0 feedback off heading off\n%s\n' "$2" | "$1" | tr -d '\r' | sed 's/^[ \t]*//;s/[ \t]*$//' \
  | grep -v '^$' | grep -v '^Session' | head -1 || true; }
cdb_val() { val cdb_sql "$1"; }
pdb_val() { val pdb_sql "$1"; }
# try <cdb_sql|pdb_sql> <statement>: prints OK or the first ORA- error code
try() { local out; out=$(printf '%s\n' "$2" | "$1" 2>&1 || true)
  if grep -qE 'ORA-[0-9]+' <<<"$out"; then grep -oE 'ORA-[0-9]+: .*' <<<"$out" | grep -v '^ORA-02097' | head -1; else echo OK; fi; }
expect() { [[ "$2" == "$3"* ]] || die "$1: expected $3, got: $2"; ok "$1: ${2:0:150}"; }

wait_healthy() {
  echo "Waiting for the database to be ready..."
  for _ in $(seq 1 90); do
    if docker exec "$C" healthcheck.sh >/dev/null 2>&1; then echo "Database is ready."; return 0; fi
    sleep 5
  done
  die "timed out waiting for the database"
}

restart_db() {
  echo "   ... shutdown immediate / startup"
  cdb_sql <<'EOF' | grep -E 'Vector Memory Area|ORA-' | sed 's/^/     /' || true
shutdown immediate
startup
EOF
  wait_healthy >/dev/null
  [ "$(cdb_val "select open_mode from v\$pdbs where name = 'FREEPDB1';")" = "READ WRITE" ] || die "FREEPDB1 not open"
}

# spfile_pool <value>: VECTOR_MEMORY_SIZE in the CDB spfile, then restart
spfile_pool() { cdb_sql >/dev/null <<<"alter system set vector_memory_size = $1 scope = spfile;"; restart_db; }

num_vectors() { pdb_val "select nvl(max(num_vectors), -1) from v\$vector_index where owner = 'APP' and index_name = '$1';"; }
pool_used() { pdb_val "select round(sum(used_bytes) / 1048576, 1) from v\$vector_memory_pool where con_id = sys_context('userenv', 'con_id');"; }
hnsw() { try pdb_sql "create vector index app.$1 on app.$2 (emb) $HNSW;"; }

# plan_of <table> <fetch clause> [metric]: the access path of a top-10 query for query vector 3
plan_of() {
  local q=queries tag out i; [ "$1" = rnd ] && q=rnd_queries
  for i in 1 2 3; do
    tag="plan-$RANDOM$RANDOM"
    out=$(pdb_sql <<EOF | grep -oE 'VECTOR INDEX [A-Z ]+SCAN|IVF_FLAT_CENTROID_PARTITIONS|TABLE ACCESS FULL[^|]*\| (DOCS|RND)[[:space:]]' | head -1 | sed 's/[[:space:]]*|[[:space:]]*/ /;s/[[:space:]]*$//' || true
set serveroutput off pages 0 heading off feedback off
select /* $tag */ count(*) from (select id from app.$1 order by vector_distance(emb, (select emb from app.$q where qid = 3), ${3:-cosine}) $2);
select p.plan_table_output from (select max(sql_id) keep (dense_rank last order by last_active_time) sql_id, max(child_number) keep (dense_rank last order by last_active_time) child
  from v\$sql where sql_text like 'select /* $tag */%') s, table(dbms_xplan.display_cursor(s.sql_id, s.child, 'BASIC')) p;
EOF
)
    [ -n "$out" ] && break
  done
  echo "$out"
}
# top1 <fetch clause> <query id>: id of the nearest DOCS row for that query vector
top1() { pdb_val "select id from app.docs order by vector_distance(emb, (select emb from app.queries where qid = $2), cosine) $1;"; }
recall() { pdb_val "select app.recall10('$1', '$2', '$3') from dual;"; }

cmd_up() { docker compose up -d; wait_healthy; }

cmd_setup() {
  wait_healthy
  echo ">> SETUP"
  local cdbv pdbv pdbsga
  cdbv=$(cdb_val "select value from v\$parameter where name = 'vector_memory_size';")
  pdbv=$(pdb_val "select value from v\$parameter where name = 'vector_memory_size';")
  pdbsga=$(pdb_val "select value from v\$parameter where name = 'sga_target';")
  pdb_sql >/dev/null <<'EOF' || true
alter system reset vector_memory_size scope = spfile;
alter system reset sga_target scope = spfile;
EOF
  cdb_sql >/dev/null <<<"alter system reset vector_memory_size scope = spfile;" || true
  if [ "$cdbv" != 0 ] || [ "$pdbv" != 0 ] || [ "$pdbsga" != 0 ]; then restart_db; fi
  if [ "$(pdb_val "select count(*) from dba_tables where owner = 'APP' and table_name in ('DOCS', 'RND');")" = 2 ] &&
     [ "$(pdb_val "select (select count(*) from app.docs) + (select count(*) from app.rnd) from dual;")" = 200000 ]; then
    pdb_sql >/dev/null <<'EOF'
begin
  for i in (select owner, index_name from dba_indexes where owner = 'APP' and index_type = 'VECTOR') loop
    execute immediate 'drop index ' || i.owner || '.' || i.index_name;
  end loop;
end;
/
EOF
  else
    echo "   ... loading 200,000 vectors"
    pdb_sql < scripts/app.sql >/dev/null || die "schema load failed"
  fi
  [ "$(pdb_val "select count(*) from app.docs;")" = 100000 ] || die "APP.DOCS not loaded"
  [ "$(cdb_val "select value from v\$parameter where name = 'vector_memory_size';")" = 0 ] || die "vector_memory_size not 0"
  echo "   schema ready: APP.DOCS 100000 clustered, APP.RND 100000 uniform, VECTOR(128, FLOAT32), no vector index"
}

cmd_default() {
  cmd_setup
  echo ">> DEFAULT: the image as shipped"
  expect "CDB vector_memory_size" "$(cdb_val "select value from v\$parameter where name = 'vector_memory_size';")" 0
  expect "PDB vector_memory_size" "$(pdb_val "select value from v\$parameter where name = 'vector_memory_size';")" 0
  expect "HNSW index (INMEMORY NEIGHBOR GRAPH)" "$(hnsw docs_hnsw docs)" "ORA-51962"
  expect "raise the pool online, CDB" "$(try cdb_sql "alter system set vector_memory_size = 256M;")" "ORA-51950"
  expect "raise the pool online, PDB" "$(try pdb_sql "alter system set vector_memory_size = 128M;")" "ORA-51955"
  expect "IVF index (NEIGHBOR PARTITIONS)" "$(try pdb_sql "create vector index app.docs_ivf on app.docs (emb) $IVF;")" OK
  expect "FETCH APPROX FIRST 10 with the IVF index" "$(plan_of docs "fetch approx first 10 rows only")" "IVF_FLAT_CENTROID_PARTITIONS"
  echo "   recall of the IVF index, clustered data: $(recall docs queries "fetch approx first 10 rows only")%"
}

cmd_sizing() {
  cmd_setup
  echo ">> SIZING: VECTOR_MEMORY_SIZE = 256M in the spfile, then restart"
  local bc0 bc1 adv used
  bc0=$(cdb_val "select round(bytes / 1048576) from v\$sgainfo where name = 'Buffer Cache Size';")
  spfile_pool 256M
  bc1=$(cdb_val "select round(bytes / 1048576) from v\$sgainfo where name = 'Buffer Cache Size';")
  [ "$bc1" -lt "$bc0" ] || die "buffer cache didn't shrink ($bc0 -> $bc1 MB)"
  ok "buffer cache ${bc0} MB -> ${bc1} MB (SGA_TARGET unchanged): the pool comes out of the SGA"
  echo "   docs formula 1.3 x 100000 x 128 x 4 bytes = $(pdb_val "select round(1.3 * 100000 * 128 * 4 / 1048576, 1) from dual;") MiB"
  adv=$(pdb_sql <<'EOF' | grep -oE '"required_memory":[0-9]+' | cut -d: -f2
set serveroutput on
declare r clob; begin
  dbms_vector.index_vector_memory_advisor(index_type => 'HNSW', num_vectors => 100000, dim_count => 128,
    dim_type => 'FLOAT32', response_json => r);
  dbms_output.put_line(r);
end;
/
EOF
)
  [ -n "$adv" ] || die "advisor returned nothing"
  echo "   DBMS_VECTOR.INDEX_VECTOR_MEMORY_ADVISOR: $adv bytes = $(awk "BEGIN{printf \"%.1f\", $adv/1048576}") MiB"
  try pdb_sql "alter system set vector_memory_size = 64M;" >/dev/null
  expect "PDB limit 64M (the formula), HNSW" "$(hnsw docs_hnsw docs)" "ORA-51962"
  try pdb_sql "alter system set vector_memory_size = 90M;" >/dev/null
  expect "PDB limit 90M (more than the finished index), HNSW" "$(hnsw docs_hnsw docs)" "ORA-51962"
  try pdb_sql "alter system set vector_memory_size = 128M;" >/dev/null
  expect "PDB limit 128M, HNSW" "$(hnsw docs_hnsw docs)" OK
  used=$(pool_used)
  awk "BEGIN{exit !($used >= 80 && $used <= 90)}" || die "pool used $used MiB, expected 80-90"
  ok "the finished index uses $used MiB of the pool (formula 63.5 MiB; the build needed more than 90M)"
  expect "FETCH APPROX FIRST 10" "$(plan_of docs "fetch approx first 10 rows only")" "VECTOR INDEX HNSW SCAN"
  expect "raise the CDB pool online 256M -> 320M" "$(try cdb_sql "alter system set vector_memory_size = 320M;")" OK
  expect "lower it below the startup size" "$(try cdb_sql "alter system set vector_memory_size = 128M;")" "ORA-51953"
  expect "an IVF index on the same column" "$(try pdb_sql "create vector index app.docs_ivf on app.docs (emb) $IVF;")" "ORA-01408"
}

cmd_accuracy() {
  cmd_setup
  echo ">> ACCURACY: exact top 10 vs the HNSW index"
  spfile_pool 384M
  try pdb_sql "alter system set vector_memory_size = 320M;" >/dev/null
  expect "HNSW on APP.DOCS (clustered)" "$(hnsw docs_hnsw docs)" OK
  expect "HNSW on APP.RND (uniform random)" "$(hnsw rnd_hnsw rnd)" OK
  local c r_def r_plain r_95 r_100
  c=$(recall docs queries "fetch approx first 10 rows only")
  awk "BEGIN{exit !($c >= 99)}" || die "clustered recall $c%"
  ok "clustered, FETCH APPROX FIRST 10 (default target accuracy 90): $c% of the exact top 10"
  r_def=$(recall rnd rnd_queries "fetch approx first 10 rows only")
  awk "BEGIN{exit !($r_def < 90)}" || die "uniform recall $r_def%, expected < 90"
  ok "uniform, FETCH APPROX FIRST 10 (default target accuracy 90): $r_def%"
  r_plain=$(recall rnd rnd_queries "fetch first 10 rows only")
  [ "$r_plain" = "$r_def" ] || die "plain FETCH FIRST recall $r_plain% vs approx $r_def%"
  ok "uniform, plain FETCH FIRST 10 (no APPROX, no EXACT): $r_plain%, the same as FETCH APPROX"
  expect "plain FETCH FIRST 10" "$(plan_of rnd "fetch first 10 rows only")" "VECTOR INDEX HNSW SCAN"
  expect "FETCH EXACT FIRST 10" "$(plan_of rnd "fetch exact first 10 rows only")" "TABLE ACCESS FULL"
  r_95=$(recall rnd rnd_queries "fetch approx first 10 rows only with target accuracy 95")
  echo "   uniform, WITH TARGET ACCURACY 95: $r_95%"
  r_100=$(recall rnd rnd_queries "fetch approx first 10 rows only with target accuracy 100")
  awk "BEGIN{exit !($r_100 > $r_def)}" || die "target accuracy 100 recall $r_100%"
  ok "uniform, WITH TARGET ACCURACY 100: $r_100% (more than the default; 100 would mean every exact row)"
  expect "EUCLIDEAN query on a COSINE index" "$(plan_of docs "fetch approx first 10 rows only" euclidean)" "TABLE ACCESS FULL"
}

cmd_restart() {
  cmd_setup
  echo ">> RESTART: DML and restarts, pool 256M"
  spfile_pool 256M
  try pdb_sql "alter system set vector_memory_size = 200M;" >/dev/null
  expect "HNSW on APP.DOCS" "$(hnsw docs_hnsw docs)" OK
  local out
  out=$(pdb_sql <<'EOF'
set pages 0 heading off feedback off
insert into app.docs select 1000003, 0, emb from app.queries where qid = 3;
select 'UNCOMMITTED=' || id from app.docs order by vector_distance(emb, (select emb from app.queries where qid = 3), cosine) fetch approx first 1 rows only;
commit;
update app.docs set emb = (select emb from app.queries where qid = 5) where id = 1000003;
commit;
select 'UPDATED=' || id from app.docs order by vector_distance(emb, (select emb from app.queries where qid = 5), cosine) fetch approx first 1 rows only;
delete app.docs where id = 1000003;
commit;
select 'DELETED=' || id from app.docs order by vector_distance(emb, (select emb from app.queries where qid = 5), cosine) fetch approx first 1 rows only;
EOF
)
  expect "insert, uncommitted, same session: nearest row" "$(grep -oE 'UNCOMMITTED=[0-9]+' <<<"$out")" "UNCOMMITTED=1000003"
  expect "update committed: nearest row to the new vector" "$(grep -oE 'UPDATED=[0-9]+' <<<"$out")" "UPDATED=1000003"
  [ "$(grep -oE 'DELETED=[0-9]+' <<<"$out")" != "DELETED=1000003" ] || die "deleted row still returned"
  ok "delete committed: the row is no longer returned ($(grep -oE 'DELETED=[0-9]+' <<<"$out"))"
  expect "V\$VECTOR_INDEX.NUM_VECTORS after the DML" "$(num_vectors DOCS_HNSW)" 100000
  restart_db
  echo "   first query after the restart: $(plan_of docs "fetch approx first 10 rows only") (pool $(pool_used) MiB used)"
  local i
  for i in $(seq 1 24); do [ "$(num_vectors DOCS_HNSW)" = 100000 ] && break; sleep 5; done
  expect "after the restart, NUM_VECTORS" "$(num_vectors DOCS_HNSW)" 100000
  expect "after the reload, FETCH APPROX" "$(plan_of docs "fetch approx first 10 rows only")" "VECTOR INDEX HNSW SCAN"

  echo ">> RESTART with the spfile pool lowered to 64M (smaller than the 81 MiB index)"
  spfile_pool 64M
  sleep 60
  expect "index status" "$(pdb_val "select status from dba_indexes where owner = 'APP' and index_name = 'DOCS_HNSW';")" VALID
  expect "NUM_VECTORS, 60 s after open" "$(num_vectors DOCS_HNSW)" 0
  expect "FETCH APPROX FIRST 10" "$(plan_of docs "fetch approx first 10 rows only")" "TABLE ACCESS FULL"
  [ "$(top1 "fetch approx first 1 rows only" 3)" = "$(top1 "fetch exact first 1 rows only" 3)" ] || die "wrong result"
  ok "results are still correct (exact): only the speed changed"
  local alerts
  alerts=$(docker exec "$C" bash -c 'L=$(ls /opt/oracle/diag/rdbms/free/FREE/trace/alert_FREE.log); n=$(grep -n "Starting ORACLE instance" $L | tail -1 | cut -d: -f1); tail -n +$n $L' \
    | grep -ciE 'ORA-5[0-9]{4}|hnsw|vector index' || true)
  expect "alert log lines about the vector index since startup" "$alerts" 0
  expect "raise the CDB pool online to 256M" "$(try cdb_sql "alter system set vector_memory_size = 256M;")" OK
  sleep 30
  expect "30 s later, NUM_VECTORS" "$(num_vectors DOCS_HNSW)" 0
  expect "DBMS_VECTOR.REBUILD_INDEX" \
    "$(try pdb_sql "exec dbms_vector.rebuild_index(idx_name => 'DOCS_HNSW', idx_owner => 'APP')")" "ORA-51962"
  expect "DOCS_HNSW in DBA_INDEXES after the failed rebuild" \
    "$(pdb_val "select count(*) from dba_indexes where owner = 'APP' and index_name = 'DOCS_HNSW';")" 0
  echo "   PDB vector_memory_size shows $(pdb_val "select display_value from v\$parameter where name = 'vector_memory_size';")"
  expect "CREATE again, PDB limit not touched" "$(hnsw docs_hnsw docs)" "ORA-51962"
  try pdb_sql "alter system set vector_memory_size = 200M;" >/dev/null
  expect "PDB limit set again, CREATE" "$(hnsw docs_hnsw docs)" OK
  expect "FETCH APPROX FIRST 10" "$(plan_of docs "fetch approx first 10 rows only")" "VECTOR INDEX HNSW SCAN"
}

cmd_autogrow() {
  cmd_setup
  echo ">> AUTOGROW: VECTOR_MEMORY_SIZE = 1 in the spfile, then restart"
  spfile_pool 1
  expect "PDB vector_memory_size" "$(pdb_val "select value from v\$parameter where name = 'vector_memory_size';")" 0
  expect "set a PDB limit" "$(try pdb_sql "alter system set vector_memory_size = 200M;")" "ORA-51999"
  expect "PDB sga_target" "$(pdb_val "select value from v\$parameter where name = 'sga_target';")" 0
  expect "HNSW with PDB SGA_TARGET = 0" "$(hnsw docs_hnsw docs)" "ORA-51995"
  try pdb_sql "alter system set sga_target = 512M;" >/dev/null
  expect "HNSW with PDB SGA_TARGET = 512M" "$(hnsw docs_hnsw docs)" OK
  ok "the CDB pool grew to $(cdb_val "select display_value from v\$parameter where name = 'vector_memory_size';") (used $(pool_used) MiB)"
  restart_db
  local i
  for i in $(seq 1 24); do [ "$(num_vectors DOCS_HNSW)" = 100000 ] && break; sleep 5; done
  expect "after the restart, NUM_VECTORS" "$(num_vectors DOCS_HNSW)" 100000
  expect "FETCH APPROX FIRST 10" "$(plan_of docs "fetch approx first 10 rows only")" "VECTOR INDEX HNSW SCAN"
}

case "${1:-}" in
  up) cmd_up ;;
  setup) cmd_setup ;;
  default) cmd_default ;; sizing) cmd_sizing ;; accuracy) cmd_accuracy ;; restart) cmd_restart ;; autogrow) cmd_autogrow ;;
  all) t0=$SECONDS; cmd_default; cmd_sizing; cmd_accuracy; cmd_restart; cmd_autogrow; cmd_setup
       echo ">> All checks passed in $((SECONDS - t0)) s." ;;
  sql) docker exec -it "$C" sqlplus / as sysdba ;;
  down) docker compose down ;;
  destroy) docker compose down -v ;;
  *) sed -n '2,40p' "$0"; exit 1 ;;
esac
