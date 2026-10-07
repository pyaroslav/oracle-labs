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
die() { echo "!! FAIL: $*" >&2; exit 1; }
# KEY=value from a >>>SIGNALS block (whitespace stripped)
sig() { { grep -E "^$2=" "$1" || true; } | head -1 | cut -d= -f2- | tr -d '[:space:]'; }
# print one report section: from the line that STARTS with the title (so the "-> Segments by ..."
# table-of-contents entries don't match) down to the section's closing "   -----" rule.
section() { awk -v h="$2" 'index($0, h) == 1 { p = 1 } p { print } p && /^[ \t]+-+$/ { exit }' "$1"; }
# a drill's SQL must not have errored (e.g. ORA-30009 would leave a report of a half-run workload)
no_ora() { local e; e=$({ grep -E "^ORA-[0-9]+" "$1" || true; } | head -3); [ -z "$e" ] || die "$1 contains errors:"$'\n'"$e"; }

wait_healthy() {
  echo "Waiting for the database to be ready..."
  for i in $(seq 1 90); do
    if docker exec "$C" healthcheck.sh >/dev/null 2>&1; then echo "Database is ready."; return 0; fi
    sleep 5
  done
  die "timed out waiting for the database"
}

cmd_up()    { docker compose up -d; wait_healthy; }
cmd_setup() { wait_healthy; echo ">> Creating demo schema (this builds a ~1.4GB table)..."; run_sql < scripts/01-demo-schema.sql; }

cmd_drill() {
  echo ">> CPU DRILL: snapshot -> workload -> snapshot -> AWR report"
  run_sql < scripts/awr-drill.sql > awr-report.txt 2>&1
  echo ">> Full AWR report saved to: $(pwd)/awr-report.txt ($(wc -c < awr-report.txt) bytes)"
  echo "================= THE SECTIONS THAT MATTER ================="
  echo "--- Header (DB Time) ---";          grep -iE "Elapsed:|DB Time:" awr-report.txt | head -2 || true
  echo "--- Load Profile ---";              grep -iA6 "Load Profile" awr-report.txt | head -8 || true
  echo "--- Top Foreground Events ---";     grep -iA6 "Top 10 Foreground Events" awr-report.txt | head -9 || true
  echo "--- Top SQL (workload SQL #1) ---"; { grep -i "awr_demo" awr-report.txt || true; } | head -2
  echo "==========================================================="
  no_ora awr-report.txt
  local top cpu
  top=$(section awr-report.txt "Top 10 Foreground Events")
  cpu=$(awk '$1 == "DB" && $2 == "CPU" { print $NF; exit }' <<< "$top")
  [ -n "$cpu" ] || die "no DB CPU line in Top 10 Foreground Events"
  awk -v c="$cpu" 'BEGIN { exit !(c + 0 >= 80) }' || die "DB CPU should dominate DB time (>=80%), got ${cpu}%"
  { grep -qi "awr_demo" awr-report.txt; } || die "the awr_demo workload SQL is missing from the AWR report"
  echo ">> CHECK OK: DB CPU = ${cpu}% of DB time; awr_demo SQL captured"
}

cmd_drill_io() {
  echo ">> I/O DRILL: flush + full-scan a big table -> AWR report"
  run_sql < scripts/io-drill.sql > io-report.txt 2>&1
  echo ">> Full report saved to: $(pwd)/io-report.txt ($(wc -c < io-report.txt) bytes)"
  echo "================= THE I/O SIGNATURE ================="
  echo "--- Load Profile (physical reads!) ---";       grep -iE "Physical read \(blocks\):" io-report.txt | head -1 || true
  echo "--- Top Foreground Events (db file reads) ---"; grep -iA7 "Top 10 Foreground Events" io-report.txt | head -10 || true
  echo "--- the I/O workload SQL ---";                  grep -i "io_demo" io-report.txt | head -2 || true
  # 23ai/26ai prints owner+tablespace on one line and object name + numbers on the next, and the
  # title first appears in the report's table of contents -> read the real section, show the header
  # rows + the BIGTAB line.
  local seg bigtab
  seg=$(section io-report.txt "Segments by Physical Reads")
  bigtab=$({ grep -E "^BIGTAB[[:space:]]" <<< "$seg" || true; } | head -1)
  echo "--- Segments by Physical Reads (the hot table) ---"
  { grep -E "^-> Total Physical Reads|^Object Name|^LABUSER" <<< "$seg" || true; } | head -3
  printf '%s\n' "$bigtab"
  echo "===================================================="
  no_ora io-report.txt
  [ -n "$bigtab" ] || die "BIGTAB not found in 'Segments by Physical Reads':"$'\n'"$seg"
  local pct; pct=$(awk '{ print $NF }' <<< "$bigtab")
  awk -v c="$pct" 'BEGIN { exit !(c + 0 >= 50) }' || die "BIGTAB should be the dominant segment by physical reads, got ${pct}%"
  echo ">> CHECK OK: BIGTAB = ${pct}% of physical reads"
  echo "Note: on fast local disk the db-file-read WAIT time is small; on production storage these"
  echo "same physical reads become the top event. The signature (high physical reads + the segment)"
  echo "is what you learn to spot."
}

cmd_drill_ash() {
  echo ">> ASH DRILL: short workload -> Active Session History report"
  run_sql < scripts/ash-drill.sql > ash-report.txt 2>&1
  echo ">> Full ASH report saved to: $(pwd)/ash-report.txt ($(wc -c < ash-report.txt) bytes)"
  echo "================= ACTIVE SESSION HISTORY ================="
  local ev sq
  ev=$(section ash-report.txt "Top User Events")
  sq=$(section ash-report.txt "Top SQL with Top Events")   # 23ai/26ai name (older: "Top SQL Statements")
  echo "--- Header ---";          { grep -E "Analysis (Begin|End) Time:|Sample Count:|Average Active Sessions:" ash-report.txt || true; }
  echo "--- Top User Events ---"; printf '%s\n' "$ev"
  echo "--- Top SQL ---";         printf '%s\n' "$sq"
  echo "========================================================="
  no_ora ash-report.txt
  local n d
  n=$(sig ash-report.txt ASH_SAMPLES); d=$(sig ash-report.txt ASH_DEMO_SAMPLES)
  [ "${n:-0}" -ge 5 ] || die "ASH captured only '${n:-null}' samples in the workload window"
  [ "${d:-0}" -ge 5 ] || die "ASH captured only '${d:-null}' samples of the ash_demo SQL"
  { grep -q "No data exists" <<< "$ev"; } && die "ASH 'Top User Events' is empty"
  { grep -qE "^CPU" <<< "$ev"; } || die "ASH 'Top User Events' has no CPU row"
  { grep -qi "ash_demo" <<< "$sq"; } || die "ASH 'Top SQL' does not show the ash_demo statement"
  echo ">> CHECK OK: ${n} ASH samples in the window, ${d} on the ash_demo SQL"
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
