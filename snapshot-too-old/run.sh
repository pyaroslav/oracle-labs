#!/usr/bin/env bash
# Oracle snapshot-too-old (ORA-01555) lab — driver. Everything runs INSIDE the container via `docker exec`, so
# you only need Docker. Companion to "ORA-01555 Snapshot Too Old: Reproduce It, Then Make It Impossible".
#
#   REPRODUCE : open a full-scan cursor on a 20,000-row table, pin its read-consistent snapshot, then rewrite
#               every row 12x and commit -- churning far more undo than the 10 MB, non-autoextending, NOT-
#               guaranteed undo tablespace can hold. Keep fetching the old snapshot -> the undo it needs has
#               been overwritten -> ORA-01555. Asserts the failure actually happens.
#   FIX       : swap in a 300 MB undo tablespace with RETENTION GUARANTEE and undo_retention=1200, then run the
#               EXACT SAME query -> unexpired undo is preserved, so it reads all 20,000 rows with no ORA-01555.
#
#   ./run.sh up        # start the database (first run pulls the image)
#   ./run.sh setup     # build the table + the weak undo config
#   ./run.sh reproduce # run the query under the weak config; assert ORA-01555
#   ./run.sh fix       # apply the fix, re-run the same query; assert it completes
#   ./run.sh all       # setup -> reproduce -> fix
#   ./run.sh sql       # SQL*Plus as SYSDBA
#   ./run.sh down / destroy
set -euo pipefail
cd "$(dirname "$0")"

C=ora-snapshot-too-old-lab
export LAB_PORT="${LAB_PORT:-1521}"

die() { echo "!! FAIL: $*" >&2; exit 1; }
run_sys() { docker exec -i "$C" sqlplus -s -L "/ as sysdba"; }
sig() { printf '%s\n' "$1" | grep -E "^$2=" | head -1 | cut -d= -f2- | tr -d '[:space:]'; }

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
  echo ">> Building the 20,000-row table and the weak undo config (10 MB, no autoextend, no guarantee)..."
  run_sys < scripts/setup.sql >/dev/null 2>&1 || true
  local m rows undo
  m=$(run_sys < scripts/meta.sql)
  rows=$(sig "$m" ROWS); undo=$(sig "$m" UNDO)
  echo "   rows=${rows:-?}  active undo tablespace=${undo:-?}"
  [ "${rows:-0}" = "20000" ]      || die "expected 20,000 rows, got '${rows:-null}' -- setup failed:"$'\n'"$m"
  [ "${undo:-x}" = "UNDO_SMALL" ] || die "expected active undo=UNDO_SMALL, got '${undo:-null}'"
  echo ">> Setup complete."
}

# run churn.sql and print the outcome; sets globals SNAP / ROWS_N / ERR
run_churn() {
  local out; out=$(run_sys < scripts/churn.sql)
  SNAP=$(sig "$out" SNAP_1555); ROWS_N=$(sig "$out" ROWS); ERR=$(sig "$out" ERR)
}

cmd_reproduce() {
  echo ">> Reproducing: long query + heavy undo churn on the weak config..."
  run_churn
  echo "   ORA-01555 raised? ${SNAP:-?}   (rows fetched before it died: ${ROWS_N:-?}, sqlcode ${ERR:-?})"
  [ "${SNAP:-}" = "YES" ] || die "expected ORA-01555 on the weak config, got SNAP_1555='${SNAP:-null}' (rows=${ROWS_N:-?}, err=${ERR:-?})"
  echo "   -> the query died with ORA-01555: its read-consistent undo was overwritten by the churn."
}

cmd_fix() {
  echo ">> Applying the fix: 300 MB undo tablespace, RETENTION GUARANTEE, undo_retention=1200..."
  run_sys < scripts/fix.sql >/dev/null 2>&1 || true
  echo ">> Re-running the EXACT SAME query under the fixed config..."
  run_churn
  echo "   ORA-01555 raised? ${SNAP:-?}   (rows fetched: ${ROWS_N:-?})"
  [ "${SNAP:-}" = "NO" ]        || die "expected NO ORA-01555 after the fix, got SNAP_1555='${SNAP:-null}' (err=${ERR:-?})"
  [ "${ROWS_N:-0}" -ge 20000 ]  || die "expected all 20,000 rows fetched after the fix, got '${ROWS_N:-null}'"
  echo "   -> same query, same churn: it read all ${ROWS_N} rows. Guaranteed undo preserved read consistency."
}

cmd_all() {
  cmd_setup; echo
  cmd_reproduce; echo
  cmd_fix; echo
  echo ">> PASS: the identical query failed with ORA-01555 on an undersized, unguaranteed undo tablespace, and"
  echo ">>       completed cleanly once undo was sized for the workload with RETENTION GUARANTEE."
  echo ">> ALL DRILLS COMPLETE"
}

cmd_sql()     { docker exec -it "$C" sqlplus "/ as sysdba"; }
cmd_down()    { docker compose down; }
cmd_destroy() { docker compose down -v; }

case "${1:-}" in
  up) cmd_up ;;
  setup) cmd_setup ;;
  reproduce) cmd_setup >/dev/null 2>&1 || true; cmd_reproduce ;;
  fix) cmd_fix ;;
  all) cmd_all ;;
  sql) cmd_sql ;;
  down) cmd_down ;;
  destroy) cmd_destroy ;;
  *) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
