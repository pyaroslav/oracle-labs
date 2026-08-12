#!/usr/bin/env bash
# Oracle optimizer-stats lab — driver. Everything runs INSIDE the container via `docker exec`, so you
# only need Docker. Companion to the post "Oracle Optimizer Statistics, Demystified".
#
# It builds a 1,000,000-row table where MODEL determines MAKE (the columns are correlated), joins it to an
# orders table, gathers stats WITHOUT a column group, and reads the real plan (DBMS_XPLAN 'ALLSTATS LAST'):
#
#   BEFORE: no column group -> the optimizer treats make & model as independent, multiplies their
#           selectivities, expects ~200 rows from the filter, and picks a NESTED LOOP join -- right for a
#           few hundred rows, wrong for the ~10,000 that actually match (E-Rows a fraction of A-Rows).
#   AFTER : create an extended statistic on (make, model) -> estimate corrects to ~10,000 -> HASH JOIN,
#           E-Rows ~ A-Rows.
#
#   ./run.sh up        # start the database (first run pulls the image)
#   ./run.sh setup     # build the correlated tables, stats without a column group
#   ./run.sh before    # show the plan with make & model treated as independent
#   ./run.sh fix       # create + gather the (make, model) column group
#   ./run.sh after     # show the corrected plan
#   ./run.sh all       # setup -> before (assert under-estimate) -> fix -> after (assert corrected)
#   ./run.sh sql       # SQL*Plus as SYSDBA inside the container
#   ./run.sh down      # stop & remove the container (keeps the data volume)
#   ./run.sh destroy   # stop & remove the container AND the data volume
set -euo pipefail
cd "$(dirname "$0")"

C=ora-optimizer-stats-lab
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
  echo ">> Building correlated cars table + orders (model determines make), stats WITHOUT a column group..."
  run_sys < scripts/setup.sql >/dev/null
  echo ">> Setup complete."
}

show_plan() { printf '%s\n' "$1" | awk '/>>>PLAN/{f=1;next} />>>ENDPLAN/{f=0} f'; }
sig() { printf '%s' "$1" | grep -oE "$2=[0-9]+" | head -1 | cut -d= -f2; }

cmd_before() { echo ">> BEFORE — make & model treated as independent:"; show_plan "$(run_sys < scripts/probe.sql)"; }
cmd_fix()    { echo ">> FIX — creating an extended statistic on (make, model)..."; run_sys < scripts/fix.sql >/dev/null; echo ">> Column group gathered."; }
cmd_after()  { echo ">> AFTER — with the (make, model) column group:"; show_plan "$(run_sys < scripts/probe.sql)"; }

cmd_all() {
  cmd_setup

  echo
  echo ">> BEFORE: no column group -- optimizer multiplies selectivities and under-counts the filter"
  local b bn bE bA ratio
  b=$(run_sys < scripts/probe.sql)
  show_plan "$b"
  bn=$(sig "$b" HAS_NL); bE=$(sig "$b" EROWS); bA=$(sig "$b" AROWS)
  [ -n "${bn:-}" ] && [ -n "${bE:-}" ] && [ -n "${bA:-}" ] || die "could not read the BEFORE plan signals:"$'\n'"$b"
  [ "$bE" -ge 1 ] || die "the estimate came back 0"
  [ "$bA" -ge 1 ] || die "the probe query matched no rows -- setup data is wrong"
  [ "$bn" -ge 1 ] || die "expected a NESTED LOOPS join before the fix, but the plan has none"
  ratio=$(( bA / bE ))
  [ "$ratio" -ge 10 ] || die "expected a large UNDER-estimate before the fix, got only ${ratio}x (E=$bE A=$bA)"
  echo "   -> CARS filter E-Rows=$bE vs A-Rows=$bA : under-counted ${ratio}x, so it chose a NESTED LOOP"

  echo
  cmd_fix

  echo
  echo ">> AFTER: with the column group, the optimizer knows make & model travel together"
  local a an ah aE aA r2
  a=$(run_sys < scripts/probe.sql)
  show_plan "$a"
  an=$(sig "$a" HAS_NL); ah=$(sig "$a" HAS_HASH); aE=$(sig "$a" EROWS); aA=$(sig "$a" AROWS)
  [ -n "${an:-}" ] && [ -n "${ah:-}" ] && [ -n "${aE:-}" ] && [ -n "${aA:-}" ] || die "could not read the AFTER plan signals:"$'\n'"$a"
  [ "$aA" -ge 1 ] || die "the probe query matched no rows after the fix"
  [ "$ah" -ge 1 ] || die "expected a HASH JOIN after the fix, but the plan has none"
  [ "$an" -eq 0 ] || die "still using a NESTED LOOP after the fix -- the plan did not change"
  if [ "$aE" -ge "$aA" ]; then r2=$(( aE / aA )); else r2=$(( aA / aE )); fi
  [ "$r2" -le 3 ] || die "estimate still off after the fix: E=$aE A=$aA (${r2}x)"
  echo "   -> CARS filter E-Rows=$aE vs A-Rows=$aA : estimate now matches reality (${r2}x), so it HASH-joined"

  echo
  echo ">> PASS: under-estimate reproduced (${ratio}x under -> nested loop) and the column group corrected it (hash join, E~=A)."
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
