#!/usr/bin/env bash
# Oracle SQL Plan Management lab — driver. Everything runs INSIDE the container via `docker exec`, so you
# only need Docker. Companion to the post "Oracle SQL Plan Management: Stop a Good Plan From Going Bad".
#
# It builds a 1,000,000-row ORDERS table with a rare, indexed STATUS and a histogram, captures the good
# INDEX plan as an ACCEPTED SQL plan baseline, then drops the histogram to simulate stats drift:
#
#   REGRESSION (baselines off): with no histogram the optimizer estimates ~a third of the table for
#           `status = 'OPEN'` and picks a FULL TABLE SCAN -- the plan silently goes bad.
#   PROTECTED (baselines on) : the optimizer still costs the full scan cheapest, but the accepted baseline
#           holds the INDEX plan (still reproducible because the index exists), and DBMS_XPLAN's Note
#           reports the SQL plan baseline was used.
#
#   ./run.sh up        # start the database (first run pulls the image)
#   ./run.sh setup     # build the skewed table + index + histogram, gather stats
#   ./run.sh capture   # run the query and capture its INDEX plan as an accepted baseline
#   ./run.sh regress   # drop the histogram so the optimizer now prefers a full scan
#   ./run.sh nospm     # show the plan with SQL plan baselines OFF (the regression: full scan)
#   ./run.sh spm       # show the plan with SQL plan baselines ON  (the save: index, baseline used)
#   ./run.sh all       # setup -> capture -> regress -> nospm (assert regression) -> spm (assert save)
#   ./run.sh sql       # SQL*Plus as SYSDBA inside the container
#   ./run.sh down      # stop & remove the container (keeps the data volume)
#   ./run.sh destroy   # stop & remove the container AND the data volume
set -euo pipefail
cd "$(dirname "$0")"

C=ora-sql-plan-management-lab
export LAB_PORT="${LAB_PORT:-1521}"

die() { echo "!! FAIL: $*" >&2; exit 1; }
run_sys() { docker exec -i "$C" sqlplus -s -L "/ as sysdba"; }
# run probe.sql with SQL plan baselines ON (TRUE) or OFF (FALSE) -- fed in as a SQL*Plus define
run_probe() { { echo "define USE_SPM=$1"; cat scripts/probe.sql; } | run_sys; }

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
  echo ">> Building skewed ORDERS (500 OPEN of 1,000,000), index + histogram on STATUS..."
  run_sys < scripts/setup.sql >/dev/null
  echo ">> Setup complete."
}

cmd_capture() {
  echo ">> CAPTURE — running the query (index plan) and loading it as an accepted baseline..."
  local out
  out=$(run_sys < scripts/capture.sql)
  echo "$out" | grep -qE 'BASELINES_LOADED=[1-9]' || die "no plan captured into a baseline:"$'\n'"$out"
  echo "   -> $(printf '%s' "$out" | grep -oE 'BASELINES_LOADED=[0-9]+')"
}

cmd_regress() {
  echo ">> REGRESS — re-gathering STATUS with SIZE 1 (histogram gone -> optimizer prefers a full scan)..."
  run_sys < scripts/regress.sql >/dev/null
  echo ">> Histogram removed."
}

show_plan() { printf '%s\n' "$1" | awk '/>>>PLAN/{f=1;next} />>>ENDPLAN/{f=0} f'; }
sig() { printf '%s' "$1" | grep -oE "$2=[0-9]+" | head -1 | cut -d= -f2; }

cmd_nospm() { echo ">> NOSPM — SQL plan baselines OFF:"; show_plan "$(run_probe FALSE)"; }
cmd_spm()   { echo ">> SPM — SQL plan baselines ON:";  show_plan "$(run_probe TRUE)"; }

cmd_all() {
  cmd_setup
  echo
  cmd_capture
  echo
  cmd_regress

  echo
  echo ">> REGRESSION: baselines OFF -- with the histogram gone, the optimizer picks a full scan"
  local n nf ni nb
  n=$(run_probe FALSE)
  show_plan "$n"
  nf=$(sig "$n" HAS_FULL); ni=$(sig "$n" HAS_INDEX); nb=$(sig "$n" BASELINE)
  [ -n "${nf:-}" ] && [ -n "${nb:-}" ] || die "could not read the baselines-off signals:"$'\n'"$n"
  [ "$nf" -ge 1 ] || die "expected a FULL SCAN once the histogram is gone (baselines off), got none"
  [ "$nb" -eq 0 ] || die "a baseline was applied with baselines OFF -- parameter not honored"
  echo "   -> baselines off: TABLE ACCESS FULL (the plan regressed)"

  echo
  echo ">> PROTECTED: baselines ON -- the accepted index plan is held despite the cheaper full-scan cost"
  local s sf si sb
  s=$(run_probe TRUE)
  show_plan "$s"
  sf=$(sig "$s" HAS_FULL); si=$(sig "$s" HAS_INDEX); sb=$(sig "$s" BASELINE)
  [ -n "${sf:-}" ] && [ -n "${si:-}" ] && [ -n "${sb:-}" ] || die "could not read the baselines-on signals:"$'\n'"$s"
  [ "$si" -ge 1 ] || die "expected the INDEX plan held by the baseline (baselines on), got none"
  [ "$sf" -eq 0 ] || die "still full-scanning with baselines ON -- the baseline was not applied"
  [ "$sb" -ge 1 ] || die "plan was NOT built from the SQL plan baseline (Note missing) -- protection failed"
  echo "   -> baselines on: INDEX RANGE SCAN, built from the accepted SQL plan baseline"

  echo
  echo ">> PASS: the plan regressed to a full scan when unprotected, and the baseline held the index plan when on."
  echo ">> ALL DRILLS COMPLETE"
}

cmd_sql()     { docker exec -it "$C" sqlplus "/ as sysdba"; }
cmd_down()    { docker compose down; }
cmd_destroy() { docker compose down -v; }

case "${1:-}" in
  up) cmd_up ;;
  setup) cmd_setup ;;
  capture) cmd_capture ;;
  regress) cmd_regress ;;
  nospm) cmd_nospm ;;
  spm) cmd_spm ;;
  all) cmd_all ;;
  sql) cmd_sql ;;
  down) cmd_down ;;
  destroy) cmd_destroy ;;
  *) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
