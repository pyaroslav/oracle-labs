#!/usr/bin/env bash
# Oracle AWR lab — driver. Everything runs INSIDE the container via `docker exec`, so you don't
# need an Oracle client on your machine. Just Docker.
#
#   ./run.sh up         # start the database (first run pulls the image + creates the DB)
#   ./run.sh setup      # create the demo schema (small + ~470MB table) and raise AWR SQL capture
#   ./run.sh drill      # CPU-bound: snapshot -> workload -> snapshot -> AWR report (awr-report.txt)
#   ./run.sh drill-io   # I/O signature: flush+scan a big table -> AWR report (io-report.txt)
#   ./run.sh drill-ash  # ASH report over the recent window (ash-report.txt)
#   ./run.sh all        # setup + all three drills
#   ./run.sh report     # re-print the last CPU AWR report
#   ./run.sh sql        # open a SYSDBA SQL*Plus session inside the container
#   ./run.sh down       # stop & remove the container (keeps the data volume)
#   ./run.sh destroy    # stop & remove the container AND the data volume
set -euo pipefail
cd "$(dirname "$0")"

C=ora-awr-lab
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
cmd_setup() { wait_healthy; echo ">> Creating demo schema (this builds a ~470MB table)..."; run_sql < scripts/01-demo-schema.sql; }

cmd_drill() {
  echo ">> CPU DRILL: snapshot -> workload -> snapshot -> AWR report"
  run_sql < scripts/awr-drill.sql > awr-report.txt 2>&1
  echo ">> Full AWR report saved to: $(pwd)/awr-report.txt ($(wc -c < awr-report.txt) bytes)"
  echo "================= THE SECTIONS THAT MATTER ================="
  echo "--- Header (DB Time) ---";          grep -iE "Elapsed:|DB Time:" awr-report.txt | head -2 || true
  echo "--- Load Profile ---";              grep -iA6 "Load Profile" awr-report.txt | head -8 || true
  echo "--- Top Foreground Events ---";     grep -iA6 "Top 10 Foreground Events" awr-report.txt | head -9 || true
  echo "--- Top SQL (workload SQL #1) ---"; grep -i "awr_demo" awr-report.txt | head -2 || true
  echo "==========================================================="
}

cmd_drill_io() {
  echo ">> I/O DRILL: flush + full-scan a big table -> AWR report"
  run_sql < scripts/io-drill.sql > io-report.txt 2>&1
  echo ">> Full report saved to: $(pwd)/io-report.txt ($(wc -c < io-report.txt) bytes)"
  echo "================= THE I/O SIGNATURE ================="
  echo "--- Load Profile (physical reads!) ---";       grep -iE "Physical read \(blocks\):" io-report.txt | head -1 || true
  echo "--- Top Foreground Events (db file reads) ---"; grep -iA7 "Top 10 Foreground Events" io-report.txt | head -10 || true
  echo "--- the I/O workload SQL ---";                  grep -i "io_demo" io-report.txt | head -2 || true
  echo "--- Segments by Physical Reads (the hot table) ---"; grep -iA6 "Segments by Physical Reads" io-report.txt | grep -i "BIGTAB" | head -1 || true
  echo "===================================================="
  echo "Note: on fast local disk the db-file-read WAIT time is small; on production storage these"
  echo "same physical reads become the top event. The signature (high physical reads + the segment)"
  echo "is what you learn to spot."
}

cmd_drill_ash() {
  echo ">> ASH DRILL: short workload -> Active Session History report"
  run_sql < scripts/ash-drill.sql > ash-report.txt 2>&1
  echo ">> Full ASH report saved to: $(pwd)/ash-report.txt ($(wc -c < ash-report.txt) bytes)"
  echo "================= ACTIVE SESSION HISTORY ================="
  echo "--- Top User Events ---";  grep -iA5 "Top User Events" ash-report.txt | head -7 || true
  echo "--- Top SQL ---";          grep -iA5 "Top SQL Statements" ash-report.txt | head -7 || true
  echo "========================================================="
}

cmd_report() { [ -f awr-report.txt ] && cat awr-report.txt || echo "No report yet — run './run.sh drill'."; }
cmd_all()    { cmd_setup; cmd_drill; cmd_drill_io; cmd_drill_ash; echo ">> ALL DRILLS COMPLETE"; }
cmd_sql()    { docker exec -it "$C" sqlplus "/ as sysdba"; }
cmd_down()   { docker compose down; }
cmd_destroy(){ docker compose down -v; }

case "${1:-}" in
  up) cmd_up ;;
  setup) cmd_setup ;;
  drill) cmd_drill ;;
  drill-io) cmd_drill_io ;;
  drill-ash) cmd_drill_ash ;;
  all) cmd_all ;;
  report) cmd_report ;;
  sql) cmd_sql ;;
  down) cmd_down ;;
  destroy) cmd_destroy ;;
  *) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
