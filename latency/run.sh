#!/usr/bin/env bash
# Oracle interconnect-latency lab — driver. Everything runs INSIDE containers via `docker exec`,
# so you don't need an Oracle client on your machine. Just Docker. Companion to the post
# "OCI vs Oracle Database@Azure: Where Should Your Oracle Database Live?".
#
# The experiment: the same two workloads — a CHATTY one (1,000 single-row statements, ~1,000
# SQL*Net round trips) and a BATCHED one (the same 1,000 rows in one statement, a handful of round
# trips) — run against the same database while `tc netem` injects the latency of three homes:
#
#   0ms   same datacenter  (Database@Azure next to your Azure apps / app in OCI next to OCI DB)
#   2ms   the OCI-Azure Interconnect between paired regions
#   10ms  a generic cross-region / cross-cloud path
#
# The chatty workload pays (round trips x delay) every time; the batched one barely notices.
# That multiplication is the latency tiebreaker in the blog post — here you can measure it.
#
#   ./run.sh up                  # start database + app containers (first run pulls the image)
#   ./run.sh setup               # schema, grants, tc install, connectivity check
#   ./run.sh drill-baseline      # 0ms:  chatty vs batched, record the baseline
#   ./run.sh drill-interconnect  # 2ms:  the interconnect penalty, measured
#   ./run.sh drill-wan           # 10ms: the cross-region penalty, measured
#   ./run.sh all                 # setup + all three drills + summary table
#   ./run.sh sql                 # SQL*Plus from the APP container (through the injected latency)
#   ./run.sh down                # stop & remove containers (keeps the data volume)
#   ./run.sh destroy             # stop & remove containers AND the data volume
set -euo pipefail
cd "$(dirname "$0")"

C=ora-latency-lab      # database container
APP=ora-latency-app    # application container (sqlplus lives here)
export LAB_PORT="${LAB_PORT:-1521}"
CONN='labuser/Lab_Passw0rd1@//oracle:1521/FREEPDB1'
ROWS=1000
STATE=latency-state.env
REPORT=latency-report.txt

die() { echo "!! FAIL: $*" >&2; exit 1; }
run_sys() { docker exec -i "$C" sqlplus -s -L "/ as sysdba"; }
run_app() { docker exec -i "$APP" sqlplus -s -L "$CONN"; }
now_ms() { date +%s%3N; }

wait_healthy() {
  echo "Waiting for the database to be ready..."
  for i in $(seq 1 90); do
    if docker exec "$C" healthcheck.sh >/dev/null 2>&1; then echo "Database is ready."; return 0; fi
    sleep 5
  done
  die "timed out waiting for the database"
}

# --- latency control -------------------------------------------------------------------------
# netem on the app container's interface delays its egress packets, so every request the app
# sends to the database arrives <delay> later: one extra <delay> per round trip.
set_delay() {
  docker exec -u root "$APP" tc qdisc replace dev eth0 root netem delay "${1}ms"
  echo ">> app-to-DB path now carries ${1}ms of injected latency"
}
clear_delay() { docker exec -u root "$APP" tc qdisc del dev eth0 root 2>/dev/null || true; }

# --- workloads -------------------------------------------------------------------------------
# Chatty: N separate single-row statements from the client = ~N round trips. This is the shape of
# an ORM doing row-by-row work, or an app making sequential calls per user action.
gen_chatty() {
  echo "set termout off feedback off heading off pagesize 0 arraysize 10"
  echo "whenever sqlerror exit failure"
  for i in $(seq 1 "$ROWS"); do
    echo "select val from orders_demo where id = $i;"
  done
  echo "set termout on"
  echo "select 'ROUNDTRIPS='||value from v\$mystat m join v\$statname n on n.statistic# = m.statistic# where n.name = 'SQL*Net roundtrips to/from client';"
}

# Batched: the same N rows in ONE statement with a real array size = a handful of round trips.
gen_batch() {
  echo "set termout off feedback off heading off pagesize 0 arraysize 500"
  echo "whenever sqlerror exit failure"
  echo "select val from orders_demo;"
  echo "set termout on"
  echo "select 'ROUNDTRIPS='||value from v\$mystat m join v\$statname n on n.statistic# = m.statistic# where n.name = 'SQL*Net roundtrips to/from client';"
}

# run_workload <chatty|batch> -> sets WL_MS and WL_RT
run_workload() {
  local out t0 t1
  t0=$(now_ms)
  out=$("gen_$1" | run_app) || die "workload $1 failed: $out"
  t1=$(now_ms)
  WL_MS=$((t1 - t0))
  WL_RT=$(echo "$out" | grep 'ROUNDTRIPS=' | tail -1 | cut -d= -f2 | tr -dc '0-9')
  [ -n "$WL_RT" ] || die "could not read round-trip count from workload $1"
}

record() { echo "$1=$2" >> "$STATE"; }
need() {
  # shellcheck disable=SC1090
  [ -f "$STATE" ] && source "$STATE"
  [ -n "${!1:-}" ] || die "missing $1 — run ./run.sh drill-baseline first"
}

# --- commands --------------------------------------------------------------------------------
cmd_up() { docker compose up -d; wait_healthy; }

cmd_setup() {
  wait_healthy
  echo ">> Creating the demo table ($ROWS rows) and grants..."
  run_sys <<SQL
alter session set container = FREEPDB1;
begin execute immediate 'drop table labuser.orders_demo purge'; exception when others then null; end;
/
create table labuser.orders_demo (id number primary key, val number);
insert into labuser.orders_demo select level, level * 7 from dual connect by level <= $ROWS;
commit;
grant select on v_\$mystat   to labuser;
grant select on v_\$statname to labuser;
exit
SQL
  echo ">> Installing tc (iproute) in the app container..."
  docker exec -u root "$APP" bash -c 'command -v tc >/dev/null 2>&1 || microdnf install -y iproute-tc >/dev/null'
  docker exec -u root "$APP" tc -V >/dev/null || die "tc is not available in the app container"
  clear_delay
  echo ">> Connectivity check from the app container..."
  echo "select 'APP_CONNECT_OK' from dual;" | run_app | grep -q APP_CONNECT_OK || die "app container cannot reach the database"
  rm -f "$STATE" "$REPORT"
  echo ">> Setup complete."
}

cmd_baseline() {
  clear_delay
  echo ">> DRILL: baseline (0ms — same datacenter)"
  run_workload chatty;  CH0=$WL_MS; RT_CH=$WL_RT
  run_workload batch;   BA0=$WL_MS; RT_BA=$WL_RT
  echo "   chatty : ${CH0} ms, ${RT_CH} round trips"
  echo "   batched: ${BA0} ms, ${RT_BA} round trips"
  # Honest checks: the workloads must actually have the network shapes we claim.
  [ "$RT_CH" -ge 900 ] || die "chatty workload made only $RT_CH round trips (expected ~$ROWS) — not chatty"
  [ "$RT_BA" -le 60 ]  || die "batched workload made $RT_BA round trips (expected a handful) — not batched"
  rm -f "$STATE"
  record CH0 "$CH0"; record BA0 "$BA0"; record RT_CH "$RT_CH"; record RT_BA "$RT_BA"
  printf '%-22s %-10s %10s %14s\n' "scenario" "workload" "elapsed_ms" "round_trips"  > "$REPORT"
  printf '%-22s %-10s %10s %14s\n' "0ms same-datacenter" "chatty"  "$CH0" "$RT_CH" >> "$REPORT"
  printf '%-22s %-10s %10s %14s\n' "0ms same-datacenter" "batched" "$BA0" "$RT_BA" >> "$REPORT"
  echo ">> PASS: workload shapes verified (chatty=$RT_CH rt, batched=$RT_BA rt)"
}

cmd_interconnect() {
  need CH0
  set_delay 2
  echo ">> DRILL: interconnect (2ms — paired-region OCI-Azure link)"
  run_workload chatty;  CH2=$WL_MS
  run_workload batch;   BA2=$WL_MS
  clear_delay
  local d_ch=$((CH2 - CH0)) d_ba=$((BA2 - BA0))
  echo "   chatty : ${CH2} ms (+${d_ch} ms vs baseline)"
  echo "   batched: ${BA2} ms (+${d_ba} ms vs baseline)"
  awk -v d="$d_ch" -v rt="$RT_CH" 'BEGIN{printf "   per round trip: %.2f ms of the injected 2ms recovered by the math\n", d/rt}'
  # Honest checks: chatty must pay roughly (round trips x 2ms); batched must not.
  [ "$d_ch" -ge 1200 ] || die "chatty paid only ${d_ch}ms under 2ms latency (expected >= ~2000ms) — injection not working"
  [ "$d_ba" -le 800 ]  || die "batched paid ${d_ba}ms under 2ms latency (expected near zero) — something is wrong"
  record CH2 "$CH2"; record BA2 "$BA2"
  printf '%-22s %-10s %10s %14s\n' "2ms interconnect" "chatty"  "$CH2" "$RT_CH" >> "$REPORT"
  printf '%-22s %-10s %10s %14s\n' "2ms interconnect" "batched" "$BA2" "$RT_BA" >> "$REPORT"
  echo ">> PASS: chatty paid the interconnect tax (+${d_ch}ms); batched shrugged (+${d_ba}ms)"
}

cmd_wan() {
  need CH0
  set_delay 10
  echo ">> DRILL: cross-region (10ms — the path nobody should put chatty OLTP on)"
  run_workload chatty;  CH10=$WL_MS
  run_workload batch;   BA10=$WL_MS
  clear_delay
  local d_ch=$((CH10 - CH0)) d_ba=$((BA10 - BA0))
  echo "   chatty : ${CH10} ms (+${d_ch} ms vs baseline)"
  echo "   batched: ${BA10} ms (+${d_ba} ms vs baseline)"
  [ "$d_ch" -ge 6000 ] || die "chatty paid only ${d_ch}ms under 10ms latency (expected >= ~10000ms)"
  [ "$d_ba" -le 1500 ] || die "batched paid ${d_ba}ms under 10ms latency (expected near zero)"
  printf '%-22s %-10s %10s %14s\n' "10ms cross-region" "chatty"  "$CH10" "$RT_CH" >> "$REPORT"
  printf '%-22s %-10s %10s %14s\n' "10ms cross-region" "batched" "$BA10" "$RT_BA" >> "$REPORT"
  echo ">> PASS: cross-region multiplied the chatty workload (+${d_ch}ms); batched still fine (+${d_ba}ms)"
}

cmd_all() {
  cmd_setup
  cmd_baseline
  cmd_interconnect
  cmd_wan
  echo
  echo "================= LATENCY x CHATTINESS — THE NUMBERS ================="
  cat "$REPORT"
  echo "======================================================================"
  echo "Same database. Same rows. The only difference is round trips x latency."
  echo ">> ALL DRILLS COMPLETE"
}

cmd_sql()     { docker exec -it "$APP" sqlplus "$CONN"; }
cmd_down()    { clear_delay 2>/dev/null || true; docker compose down; }
cmd_destroy() { docker compose down -v; }

case "${1:-}" in
  up) cmd_up ;;
  setup) cmd_setup ;;
  drill-baseline) cmd_baseline ;;
  drill-interconnect) cmd_interconnect ;;
  drill-wan) cmd_wan ;;
  all) cmd_all ;;
  sql) cmd_sql ;;
  down) cmd_down ;;
  destroy) cmd_destroy ;;
  *) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
