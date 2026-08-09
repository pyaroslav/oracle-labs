#!/usr/bin/env bash
# Oracle execution-plans lab — driver. Everything runs INSIDE the container via `docker exec`, so you
# only need Docker. Companion to the post "Oracle Execution Plans, Decoded: The One Number That Matters".
#
# It builds a 1,000,000-row table where 'OPEN' is deliberately rare, gathers stats WITHOUT a histogram,
# and reads the real execution plan (DBMS_XPLAN 'ALLSTATS LAST'):
#
#   BEFORE: no histogram -> the optimizer thinks 'OPEN' is ~half the table -> TABLE ACCESS FULL,
#           with E-Rows a thousandfold over A-Rows (the misestimate, asserted).
#   AFTER : gather a histogram -> it knows 'OPEN' is rare -> INDEX RANGE SCAN, E-Rows ~ A-Rows.
#
#   ./run.sh up        # start the database (first run pulls the image)
#   ./run.sh setup     # build the skewed 1M-row table, stats without a histogram
#   ./run.sh before    # show the plan the optimizer picks with no histogram
#   ./run.sh fix       # gather the histogram on the skewed column
#   ./run.sh after     # show the corrected plan
#   ./run.sh all       # setup -> before (assert misestimate) -> fix -> after (assert corrected)
#   ./run.sh sql       # SQL*Plus as SYSDBA inside the container
#   ./run.sh down      # stop & remove the container (keeps the data volume)
#   ./run.sh destroy   # stop & remove the container AND the data volume
set -euo pipefail
cd "$(dirname "$0")"

C=ora-execution-plans-lab
export LAB_PORT="${LAB_PORT:-1521}"

die() { echo "!! FAIL: $*" >&2; exit 1; }
run_sys() { docker exec -i "$C" sqlplus -s -L "/ as sysdba"; }

wait_healthy() {
  echo "Waiting for the database to be ready..."
  for i in $(seq 1 90); do
    if docker exec "$C" healthcheck.sh >/dev/null 2>&1; then echo "Database is ready."; return 0; fi
    sleep 5
  done
  die "timed out waiting for the database"
}

cmd_up() { docker compose up -d; wait_healthy; }

cmd_setup() {
  wait_healthy
  echo ">> Building a 1,000,000-row table (status='OPEN' is 500 rows), stats WITHOUT a histogram..."
  run_sys < scripts/setup.sql >/dev/null
  echo ">> Setup complete."
}

# print just the plan block from a probe.sql run
show_plan() { printf '%s\n' "$1" | awk '/>>>PLAN/{f=1;next} />>>ENDPLAN/{f=0} f'; }
# pull one signal value (e.g. sig "$out" EROWS) from a probe.sql run
sig() { printf '%s' "$1" | grep -oE "$2=[0-9]+" | head -1 | cut -d= -f2; }

cmd_before() { echo ">> BEFORE — the plan with no histogram:"; show_plan "$(run_sys < scripts/probe.sql)"; }
cmd_fix()    { echo ">> FIX — gathering a histogram on status..."; run_sys < scripts/fix.sql >/dev/null; echo ">> Histogram gathered."; }
cmd_after()  { echo ">> AFTER — the plan with the histogram:"; show_plan "$(run_sys < scripts/probe.sql)"; }

cmd_all() {
  cmd_setup

  echo
  echo ">> BEFORE: no histogram — the optimizer assumes 'OPEN' matches half the table"
  local b bf bE bA ratio
  b=$(run_sys < scripts/probe.sql)
  show_plan "$b"
  bf=$(sig "$b" HAS_FULL); bE=$(sig "$b" EROWS); bA=$(sig "$b" AROWS)
  [ -n "${bf:-}" ] && [ -n "${bE:-}" ] && [ -n "${bA:-}" ] || die "could not read the BEFORE plan signals:"$'\n'"$b"
  [ "$bA" -ge 1 ] || die "the probe query matched no rows -- setup data is wrong"
  [ "$bf" -ge 1 ] || die "expected a TABLE ACCESS FULL before the fix, but the plan has none"
  ratio=$(( bE / bA ))
  [ "$ratio" -ge 20 ] || die "expected a large over-estimate before the fix, got only ${ratio}x (E=$bE A=$bA)"
  echo "   -> E-Rows=$bE vs A-Rows=$bA : over-estimated ${ratio}x, so it FULL-scanned"

  echo
  cmd_fix

  echo
  echo ">> AFTER: with the histogram, the optimizer knows 'OPEN' is rare"
  local a ai af aE aA r2
  a=$(run_sys < scripts/probe.sql)
  show_plan "$a"
  ai=$(sig "$a" HAS_INDEX); af=$(sig "$a" HAS_FULL); aE=$(sig "$a" EROWS); aA=$(sig "$a" AROWS)
  [ -n "${ai:-}" ] && [ -n "${af:-}" ] && [ -n "${aE:-}" ] && [ -n "${aA:-}" ] || die "could not read the AFTER plan signals:"$'\n'"$a"
  [ "$aA" -ge 1 ] || die "the probe query matched no rows after the fix"
  [ "$ai" -ge 1 ] || die "expected an INDEX RANGE SCAN after the fix, but the plan has none"
  [ "$af" -eq 0 ] || die "still full-scanning after the fix -- the plan did not change"
  if [ "$aE" -ge "$aA" ]; then r2=$(( aE / aA )); else r2=$(( aA / aE )); fi
  [ "$r2" -le 3 ] || die "estimate still off after the fix: E=$aE A=$aA (${r2}x)"
  echo "   -> E-Rows=$aE vs A-Rows=$aA : estimate now matches reality (${r2}x), so it used the INDEX"

  echo
  echo ">> PASS: misestimate reproduced (${ratio}x over -> full scan) and the histogram corrected it (index range scan, E~=A)."
  echo ">> ALL DRILLS COMPLETE"
}

cmd_sql()     { docker exec -it "$C" sqlplus "/ as sysdba"; }
cmd_down()    { docker compose down; }
cmd_destroy() { docker compose down -v; }

case "${1:-}" in
  up) cmd_up ;;
  setup) cmd_setup ;;
  before) cmd_before ;;
  fix) cmd_fix ;;
  after) cmd_after ;;
  all) cmd_all ;;
  sql) cmd_sql ;;
  down) cmd_down ;;
  destroy) cmd_destroy ;;
  *) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
