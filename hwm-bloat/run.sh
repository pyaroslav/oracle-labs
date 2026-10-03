#!/usr/bin/env bash
# Oracle high-water mark (HWM) bloat lab — driver. Everything runs INSIDE the container via `docker exec`, so
# you only need Docker. Companion to "You Deleted 99% of the Rows. The Full Scan Didn't Get Any Faster."
#
#   SETUP : load HWM.T with 200,000 rows (~200 bytes each) and measure a full scan: rows, consistent gets, and
#           blocks below the high-water mark.
#   BLOAT : delete 99% of the rows and commit, then run the SAME full scan -> 2,000 rows, but the consistent
#           gets and the blocks below the HWM barely move. Asserted (still >= 90% of the baseline).
#   FIX   : ALTER TABLE ... SHRINK SPACE (with row movement) compacts the rows and lowers the HWM; the SAME scan
#           now reads ~1% of the blocks. Asserted (<= 5% of the baseline), with every remaining row intact.
#
#   ./run.sh up       # start the database (first run pulls the image)
#   ./run.sh setup    # build the table and take the baseline measurement
#   ./run.sh bloat    # delete 99%; assert the full scan still does ~the same work
#   ./run.sh fix      # shrink the segment; assert the scan drops to ~1%
#   ./run.sh all      # setup -> bloat -> fix
#   ./run.sh sql      # SQL*Plus as SYSDBA
#   ./run.sh down / destroy
set -euo pipefail
cd "$(dirname "$0")"

C=ora-hwm-bloat-lab
STATE=.baseline
export LAB_PORT="${LAB_PORT:-1521}"

die() { echo "!! FAIL: $*" >&2; exit 1; }
run_sys() { docker exec -i "$C" sqlplus -s -L "/ as sysdba"; }
sig() { printf '%s\n' "$1" | grep -E "^$2=" | head -1 | cut -d= -f2- | tr -d '[:space:]'; }
pct() { echo $(( $1 * 100 / $2 )); }

wait_healthy() {
  echo "Waiting for the database to be ready..."
  for i in $(seq 1 90); do
    if docker exec "$C" healthcheck.sh >/dev/null 2>&1; then echo "Database is ready."; return 0; fi
    sleep 5
  done
  die "timed out waiting for the database"
}

# measure: full-scan HWM.T; sets ROWS / GETS / HWMB (blocks below HWM) / SEGB (allocated blocks)
measure() {
  local out; out=$(run_sys < scripts/measure.sql)
  ROWS=$(sig "$out" ROWS); GETS=$(sig "$out" GETS); HWMB=$(sig "$out" HWM_BLOCKS); SEGB=$(sig "$out" SEG_BLOCKS)
  [ -n "$ROWS" ] && [ -n "$GETS" ] && [ -n "$HWMB" ] || die "measurement failed:"$'\n'"$out"
  printf '   rows=%-7s  full-scan consistent gets=%-6s  blocks below HWM=%-6s  allocated blocks=%s\n' \
    "$ROWS" "$GETS" "$HWMB" "${SEGB:-?}"
}

baseline() {
  [ -f "$STATE" ] || die "no baseline -- run ./run.sh setup first"
  # shellcheck disable=SC1090
  . "$STATE"
}

cmd_up() { docker compose up -d; wait_healthy; }

cmd_setup() {
  wait_healthy
  echo ">> Loading HWM.T with 200,000 rows..."
  run_sys < scripts/setup.sql >/dev/null || die "setup.sql failed"
  echo ">> Baseline full scan:"
  measure
  [ "$ROWS" = "200000" ] || die "expected 200,000 rows, got '$ROWS'"
  printf 'B_GETS=%s\nB_HWMB=%s\n' "$GETS" "$HWMB" > "$STATE"
  echo ">> Setup complete."
}

cmd_bloat() {
  baseline
  echo ">> Deleting 99% of the rows (keeping every 100th) and committing..."
  run_sys < scripts/delete.sql >/dev/null || die "delete.sql failed"
  echo ">> The SAME full scan:"
  measure
  [ "$ROWS" = "2000" ] || die "expected 2,000 rows after the delete, got '$ROWS'"
  echo "   -> 1% of the rows, $(pct "$GETS" "$B_GETS")% of the baseline gets, $(pct "$HWMB" "$B_HWMB")% of the blocks below the HWM."
  [ $(( GETS * 100 )) -ge $(( B_GETS * 90 )) ] || die "expected the scan to still cost >=90% of the baseline gets ($B_GETS), got $GETS"
  [ $(( HWMB * 100 )) -ge $(( B_HWMB * 90 )) ] || die "expected the HWM to stay put (>=90% of $B_HWMB blocks), got $HWMB"
  echo "   -> DELETE removed the rows, not the blocks: the scan still reads everything below the high-water mark."
}

cmd_fix() {
  baseline
  echo ">> ALTER TABLE hwm.t ENABLE ROW MOVEMENT; ALTER TABLE hwm.t SHRINK SPACE;"
  run_sys < scripts/fix.sql >/dev/null || die "fix.sql failed"
  echo ">> The SAME full scan:"
  measure
  [ "$ROWS" = "2000" ] || die "expected all 2,000 remaining rows after the shrink, got '$ROWS'"
  echo "   -> $(pct "$GETS" "$B_GETS")% of the baseline gets, $(pct "$HWMB" "$B_HWMB")% of the blocks below the HWM, every row still there."
  [ $(( GETS * 100 )) -le $(( B_GETS * 5 )) ] || die "expected the scan to drop to <=5% of the baseline gets ($B_GETS), got $GETS"
  [ $(( HWMB * 100 )) -le $(( B_HWMB * 5 )) ] || die "expected the HWM to drop to <=5% of $B_HWMB blocks, got $HWMB"
  echo "   -> the high-water mark moved down, and the full scan's work followed the data."
}

cmd_all() {
  cmd_setup; echo
  cmd_bloat; echo
  cmd_fix; echo
  echo ">> PASS: deleting 99% of the rows left the full scan doing ~100% of the work (the HWM didn't move);"
  echo ">>       SHRINK SPACE lowered the HWM and the same scan dropped to ~1% of the work."
  echo ">> ALL DRILLS COMPLETE"
}

cmd_sql()     { docker exec -it "$C" sqlplus "/ as sysdba"; }
cmd_down()    { docker compose down; }
cmd_destroy() { rm -f "$STATE"; docker compose down -v; }

case "${1:-}" in
  up) cmd_up ;;
  setup) cmd_setup ;;
  bloat) cmd_bloat ;;
  fix) cmd_fix ;;
  all) cmd_all ;;
  sql) cmd_sql ;;
  down) cmd_down ;;
  destroy) cmd_destroy ;;
  *) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
