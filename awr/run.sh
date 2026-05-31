#!/usr/bin/env bash
# Oracle AWR lab — driver. Everything runs INSIDE the container via `docker exec`, so you don't
# need an Oracle client on your machine. Just Docker.
#
#   ./run.sh up        # start the database (first run pulls the image + creates the DB)
#   ./run.sh setup     # create the small demo schema the workload uses
#   ./run.sh drill     # snapshot -> known workload -> snapshot -> generate an AWR report
#   ./run.sh report    # re-print the last generated report (awr-report.txt)
#   ./run.sh all       # setup + drill
#   ./run.sh sql       # open a SYSDBA SQL*Plus session inside the container
#   ./run.sh down      # stop & remove the container (keeps the data volume)
#   ./run.sh destroy   # stop & remove the container AND the data volume
set -euo pipefail
cd "$(dirname "$0")"

C=ora-awr-lab
export LAB_PORT="${LAB_PORT:-1521}"

wait_healthy() {
  echo "Waiting for the database to be ready..."
  for i in $(seq 1 90); do
    if docker exec "$C" healthcheck.sh >/dev/null 2>&1; then echo "Database is ready."; return 0; fi
    sleep 5
  done
  echo "Timed out waiting for the database." >&2; exit 1
}

cmd_up()    { docker compose up -d; wait_healthy; }
cmd_setup() { wait_healthy; echo ">> Creating demo schema..."; docker exec -i "$C" sqlplus -s -L "/ as sysdba" < scripts/01-demo-schema.sql; }

cmd_drill() {
  echo ">> AWR DRILL: snapshot -> workload -> snapshot -> report"
  docker exec -i "$C" sqlplus -s -L "/ as sysdba" < scripts/awr-drill.sql > awr-report.txt 2>&1
  echo ">> Full AWR report saved to: $(pwd)/awr-report.txt ($(wc -c < awr-report.txt) bytes)"
  echo
  echo "================= THE SECTIONS THAT MATTER ================="
  echo "--- Header (snapshot window + DB Time) ---"
  grep -iE "Elapsed:|DB Time:" awr-report.txt | head -2
  echo "--- Load Profile (top lines) ---"
  grep -iA6 "Load Profile" awr-report.txt | head -8
  echo "--- Top Foreground Events (where the time went) ---"
  grep -iA6 "Top 10 Foreground Events" awr-report.txt | head -9
  echo "--- Top SQL (the demo workload should be #1) ---"
  grep -i "awr_demo" awr-report.txt | head -2
  echo "==========================================================="
  echo "Open awr-report.txt to read the whole thing — that's the exercise."
}

cmd_report() { [ -f awr-report.txt ] && cat awr-report.txt || echo "No report yet — run './run.sh drill'."; }
cmd_all()    { cmd_setup; cmd_drill; }
cmd_sql()    { docker exec -it "$C" sqlplus "/ as sysdba"; }
cmd_down()   { docker compose down; }
cmd_destroy(){ docker compose down -v; }

case "${1:-}" in
  up) cmd_up ;;
  setup) cmd_setup ;;
  drill) cmd_drill ;;
  report) cmd_report ;;
  all) cmd_all ;;
  sql) cmd_sql ;;
  down) cmd_down ;;
  destroy) cmd_destroy ;;
  *) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
