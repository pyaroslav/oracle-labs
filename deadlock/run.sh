#!/usr/bin/env bash
# Oracle deadlock lab — driver. Everything runs INSIDE the container via `docker exec`, so you
# don't need an Oracle client on your machine. Just Docker. Companion to the post on ORA-00060.
#
#   ./run.sh up             # start the database (first run pulls the image + creates the DB)
#   ./run.sh setup          # build the two-row table the deadlock needs
#   ./run.sh drill-deadlock # induce ORA-00060 (two cross-locking sessions) + print the deadlock graph
#   ./run.sh drill-fixed    # same workload, consistent lock order -> NO deadlock (the fix)
#   ./run.sh all            # setup + both drills
#   ./run.sh sql            # SYSDBA SQL*Plus session inside the container
#   ./run.sh down           # stop & remove the container (keeps the data volume)
#   ./run.sh destroy        # stop & remove the container AND the data volume
set -euo pipefail
cd "$(dirname "$0")"

C=ora-deadlock-lab
ADR=/opt/oracle/diag/rdbms/free/FREE
ALERT="$ADR/trace/alert_FREE.log"
export LAB_PORT="${LAB_PORT:-1521}"
run_sql() { docker exec -i "$C" sqlplus -s -L "/ as sysdba"; }

wait_healthy() {
  echo "Waiting for the database to be ready..."
  for i in $(seq 1 90); do
    if docker exec "$C" healthcheck.sh >/dev/null 2>&1; then echo "Database is ready."; return 0; fi
    sleep 5
  done
  echo "Timed out waiting for the database." >&2; exit 1
}

cmd_up()    { docker compose up -d; wait_healthy; }
cmd_setup() { wait_healthy; echo ">> Building the two-row table labuser.dl_acct..."; run_sql < scripts/01-setup.sql; }

# Print the "Deadlock graph" from the trace the alert log points at (no adrci needed).
show_deadlock_graph() {
  echo ">> Locating the deadlock trace from the alert log..."
  local trc
  trc=$(docker exec "$C" bash -lc \
        "grep 'ORA-00060' '$ALERT' 2>/dev/null | tail -1 | grep -oE '/opt/oracle/diag/[^ ]+/FREE_ora_[0-9]+\\.trc'" || true)
  if [ -z "$trc" ]; then
    trc=$(docker exec "$C" bash -lc "grep -l 'Deadlock graph' $ADR/trace/*.trc 2>/dev/null | tail -1" || true)
  fi
  if [ -z "$trc" ]; then echo "   (trace not found; try ./run.sh sql then @scripts/show-graph.sql)"; return 0; fi
  echo ">> Deadlock trace: $trc"
  echo "===================== DEADLOCK GRAPH ====================="
  docker exec "$C" bash -lc "sed -n '/Deadlock graph/,/Rows waited/p' '$trc'" || true
  echo "================= THE TWO SQL STATEMENTS ================="
  docker exec "$C" bash -lc "grep -iE 'current SQL|update labuser' '$trc' | head" || true
  echo "========================================================="
}

cmd_deadlock() {
  wait_healthy
  echo ">> DRILL: deadlock — inducing ORA-00060 (two sessions lock the two rows in opposite order)"
  docker cp scripts/deadlock-A.sql "$C":/tmp/deadlock-A.sql >/dev/null
  docker cp scripts/deadlock-B.sql "$C":/tmp/deadlock-B.sql >/dev/null
  : > outA.txt ; : > outB.txt
  ( docker exec -i "$C" sqlplus -s -L "/ as sysdba" @/tmp/deadlock-A.sql ) > outA.txt 2>&1 &
  local PA=$!
  sleep 2                                              # stagger so A locks id=1 before B reaches it
  ( docker exec -i "$C" sqlplus -s -L "/ as sysdba" @/tmp/deadlock-B.sql ) > outB.txt 2>&1 &
  local PB=$!
  wait "$PA" || true; wait "$PB" || true
  echo "------------------------ SESSION A ------------------------"; cat outA.txt
  echo "------------------------ SESSION B ------------------------"; cat outB.txt
  if grep -q "ORA-00060" outA.txt outB.txt; then
    echo "=========================================================="
    echo " PASS: ORA-00060 was raised to the deadlock victim — the"
    echo "       intended result. Oracle rolled back ONE statement;"
    echo "       the other session proceeded and committed."
    echo "=========================================================="
    show_deadlock_graph
    return 0
  fi
  echo "FAIL: no ORA-00060 — sessions did not deadlock. Re-run, or widen the sleeps." >&2
  return 1
}

cmd_fixed() {
  wait_healthy
  echo ">> DRILL: fixed — both sessions lock in the SAME order (id=1 then id=2) => no cycle"
  docker cp scripts/fixed-A.sql "$C":/tmp/fixed-A.sql >/dev/null
  docker cp scripts/fixed-B.sql "$C":/tmp/fixed-B.sql >/dev/null
  : > foutA.txt ; : > foutB.txt
  ( docker exec -i "$C" sqlplus -s -L "/ as sysdba" @/tmp/fixed-A.sql ) > foutA.txt 2>&1 &
  local PA=$!
  sleep 2
  ( docker exec -i "$C" sqlplus -s -L "/ as sysdba" @/tmp/fixed-B.sql ) > foutB.txt 2>&1 &
  local PB=$!
  wait "$PA" || true; wait "$PB" || true
  echo "-------------------------- FIX A --------------------------"; cat foutA.txt
  echo "-------------------------- FIX B --------------------------"; cat foutB.txt
  if grep -q "ORA-00060" foutA.txt foutB.txt; then
    echo "FAIL: a deadlock occurred despite consistent ordering." >&2; return 1
  fi
  echo ">> PASS: both sessions committed, no ORA-00060 — consistent lock order prevents the cycle."
  return 0
}

cmd_all()    { cmd_setup; cmd_deadlock; cmd_fixed; echo ">> ALL DRILLS COMPLETE"; }
cmd_sql()    { docker exec -it "$C" sqlplus "/ as sysdba"; }
cmd_down()   { docker compose down; }
cmd_destroy(){ docker compose down -v; }

case "${1:-}" in
  up) cmd_up ;;
  setup) cmd_setup ;;
  drill-deadlock) cmd_deadlock ;;
  drill-fixed) cmd_fixed ;;
  all) cmd_all ;;
  sql) cmd_sql ;;
  down) cmd_down ;;
  destroy) cmd_destroy ;;
  *) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
