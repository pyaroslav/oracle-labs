#!/usr/bin/env bash
# Oracle wait-events lab — driver. Everything runs INSIDE the container via `docker exec`, so you
# don't need an Oracle client on your machine. Just Docker. Companion to the post
# "Oracle Wait Events, Decoded".
#
#   ./run.sh up            # start the database (first run pulls the image + creates the DB)
#   ./run.sh setup         # build the throwaway schema (four small tables, a few hundred MB)
#   ./run.sh drill-seq     # induce 'db file sequential read' -> seq-report.txt
#   ./run.sh drill-scatter # induce 'db file scattered read'  -> scatter-report.txt
#   ./run.sh drill-direct  # induce 'direct path read'        -> direct-report.txt
#   ./run.sh drill-commit  # induce 'log file sync'           -> commit-report.txt (LFS_N=10000 commits)
#   ./run.sh all           # setup + all four drills
#   ./run.sh sql           # open a SYSDBA SQL*Plus session inside the container
#   ./run.sh down          # stop & remove the container (keeps the data volume)
#   ./run.sh destroy       # stop & remove the container AND the data volume
set -euo pipefail
cd "$(dirname "$0")"

C=ora-wait-events-lab
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
cmd_setup() { wait_healthy; echo ">> Building the throwaway schema (four tables, ~410MB)..."; run_sql < scripts/01-setup.sql; }

# $1 = script, $2 = report file, $3 = the wait event this drill produces
run_drill() {
  echo ">> DRILL: $3"
  run_sql < "scripts/$1" > "$2" 2>&1
  echo ">> Saved: $(pwd)/$2 ($(wc -c < "$2") bytes)"
  echo "================= WAIT SIGNATURE: $3 ================="
  grep -iE "EVENT|TOTAL_WAITS|DELTA|physical reads|$3|log file parallel write" "$2" | head -30 || true
  echo "====================================================="
}

cmd_seq()     { run_drill seq-drill.sql     seq-report.txt     "db file sequential read"; }
cmd_scatter() { run_drill scatter-drill.sql scatter-report.txt "db file scattered read"; }
cmd_direct()  { run_drill direct-drill.sql  direct-report.txt  "direct path read"; }
# 'log file sync' needs CLIENT-side commits (one call per COMMIT, like a real app committing per
# row). A COMMIT inside a PL/SQL loop waits only ~once (PL/SQL commit-time optimization), so we
# generate an N x (INSERT; COMMIT;) script inside the container and the drill runs it via @.
LFS_N="${LFS_N:-10000}"
cmd_commit() {
  local wl=/tmp/lfs-workload.sql
  seq 1 "$LFS_N" | awk -v q="'" '{ printf "insert into labuser.lfs_demo values (%d, rpad(%sx%s,100,%sx%s));\ncommit;\n", $1, q, q, q, q }' \
    | docker exec -i "$C" bash -c "cat > $wl"
  echo ">> DRILL: log file sync"
  { echo "define lfs_n = $LFS_N"; echo "define lfs_workload = $wl"; cat scripts/commit-drill.sql; } \
    | run_sql > commit-report.txt 2>&1
  echo ">> Saved: $(pwd)/commit-report.txt ($(wc -c < commit-report.txt) bytes)"
  echo "================= WAIT SIGNATURE: log file sync ================="
  { grep -iE "EVENT|log file sync|log file parallel write|LFS_SIGNAL|Read it|round-trip|PL/SQL|BATCHING|the event" commit-report.txt || true; } | head -30
  echo "====================================================="
  # Assert the measured count: at least 90% of the N client commits must show up as LFS waits.
  local waits
  waits=$({ grep -oE 'client_waits=[0-9]+' commit-report.txt || true; } | head -1 | cut -d= -f2)
  if [ -z "$waits" ] || [ "$waits" -lt $(( LFS_N * 9 / 10 )) ]; then
    echo "FAIL: expected >= $(( LFS_N * 9 / 10 )) 'log file sync' waits for $LFS_N client commits, measured '${waits:-none}'." >&2
    exit 1
  fi
  echo ">> OK: $waits 'log file sync' waits measured for $LFS_N client-side commits."
}

cmd_all()    { cmd_setup; cmd_seq; cmd_scatter; cmd_direct; cmd_commit; echo ">> ALL DRILLS COMPLETE"; }
cmd_sql()    { docker exec -it "$C" sqlplus "/ as sysdba"; }
cmd_down()   { docker compose down; }
cmd_destroy(){ docker compose down -v; }

case "${1:-}" in
  up) cmd_up ;;
  setup) cmd_setup ;;
  drill-seq) cmd_seq ;;
  drill-scatter) cmd_scatter ;;
  drill-direct) cmd_direct ;;
  drill-commit) cmd_commit ;;
  all) cmd_all ;;
  sql) cmd_sql ;;
  down) cmd_down ;;
  destroy) cmd_destroy ;;
  *) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
