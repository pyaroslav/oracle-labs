#!/usr/bin/env bash
# Oracle "Checkpoint not complete" lab — driver. Everything runs INSIDE the container via `docker exec`, so you only
# need Docker. Companion to "Checkpoint Not Complete: Every Commit Waits, and the SQL Is Fine."
#
#   SETUP  : load CK.T (100,000 rows of ~1 KB) on the image's default redo layout: two 20 MB groups.
#   BEFORE : rewrite every row once (~225 MB of redo). The log writer wraps around the two small groups faster than
#            DBWR can finish the checkpoints that free them -> sessions wait on "log file switch (checkpoint
#            incomplete)" and the alert log prints "Checkpoint not complete". Asserted (waits > 0, alert lines > 0).
#   FIX    : add three 512 MB groups, switch onto them, checkpoint, drop the two small ones.
#   AFTER  : the SAME burst. Asserted: zero checkpoint-incomplete waits and no new "Checkpoint not complete" lines.
#
#   ./run.sh up       # start the database (first run pulls the image)
#   ./run.sh setup    # build the table (needs the default small redo logs: run on a fresh container)
#   ./run.sh before   # the burst on 2 x 20 MB logs; assert the stall
#   ./run.sh fix      # resize the redo logs online
#   ./run.sh after    # the same burst; assert no stall
#   ./run.sh advise   # switches per minute + V$INSTANCE_RECOVERY.OPTIMAL_LOGFILE_SIZE (informational)
#   ./run.sh all      # setup -> before -> fix -> after
#   ./run.sh sql      # SQL*Plus as SYSDBA
#   ./run.sh down / destroy
set -euo pipefail
cd "$(dirname "$0")"

C=ora-checkpoint-incomplete-lab
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

alert_file() {
  local d
  d=$(printf "set heading off feedback off pages 0\nselect value from v\$diag_info where name = 'Diag Trace';\nexit\n" | run_sys | tr -d '[:space:]')
  echo "$d/alert_FREE.log"
}
alert_count() { docker exec "$C" bash -c "grep -c 'Checkpoint not complete' '$(alert_file)' || true"; }

snap() {
  local out; out=$(run_sys < scripts/snap.sql)
  WAITS=$(sig "$out" CKPT_WAITS); CS=$(sig "$out" CKPT_CS); SW=$(sig "$out" SWITCHES)
  NGROUPS=$(sig "$out" GROUPS); LOGMB=$(sig "$out" LOG_MB)
  [ -n "$WAITS" ] && [ -n "$CS" ] && [ -n "$SW" ] || die "snapshot failed:"$'\n'"$out"
}

show_logs() { run_sys < scripts/logs.sql | sed '/^$/d' | sed 's/^/   /'; }

# burst: run the update and report elapsed time + the deltas it caused
burst() {
  snap; local w0=$WAITS c0=$CS s0=$SW a0; a0=$(alert_count)
  local t0 t1; t0=$(date +%s%N)
  run_sys < scripts/burst.sql >/dev/null || die "burst.sql failed"
  t1=$(date +%s%N)
  snap; local a1; a1=$(alert_count)
  ELAPSED=$(awk -v n=$(( (t1 - t0) / 1000000 )) 'BEGIN { printf "%.1f", n / 1000 }')
  DW=$(( WAITS - w0 )); DS=$(awk -v n=$(( CS - c0 )) 'BEGIN { printf "%.1f", n / 100 }')
  DSW=$(( SW - s0 )); DA=$(( a1 - a0 ))
  printf '   update of 100,000 rows: %ss elapsed, %s log switches\n' "$ELAPSED" "$DSW"
  printf '   log file switch (checkpoint incomplete): %s waits, %ss waited\n' "$DW" "$DS"
  printf '   alert log "Checkpoint not complete": %s new lines\n' "$DA"
}

cmd_up() { docker compose up -d; wait_healthy; }

cmd_setup() {
  wait_healthy
  snap
  if [ "${LOGMB%.*}" -gt 50 ]; then die "redo logs are already ${LOGMB} MB -- run ./run.sh destroy && ./run.sh up for a fresh database"; fi
  echo ">> Redo log layout (the image default):"
  show_logs
  echo ">> Loading CK.T with 100,000 rows of ~1 KB..."
  run_sys < scripts/setup.sql >/dev/null || die "setup.sql failed"
  echo ">> Setup complete."
}

cmd_before() {
  wait_healthy
  snap
  echo ">> The burst on $NGROUPS x ${LOGMB} MB redo logs:"
  burst
  [ "$DW" -gt 0 ] || die "expected log file switch (checkpoint incomplete) waits, got 0"
  [ "$DA" -gt 0 ] || die "expected 'Checkpoint not complete' in the alert log, got none"
  echo "   -> the log writer lapped the checkpoint: every session waited until DBWR freed a log."
  echo ">> From the alert log:"
  docker exec "$C" bash -c "grep -B1 'Checkpoint not complete' '$(alert_file)' | tail -2" | sed 's/^/   /'
}

cmd_fix() {
  wait_healthy
  echo ">> Adding 3 x 512 MB groups, switching onto them, dropping the 2 x 20 MB groups..."
  run_sys < scripts/fix.sql >/dev/null || die "fix.sql failed"
  docker exec "$C" rm -f /opt/oracle/oradata/FREE/redo01.log /opt/oracle/oradata/FREE/redo02.log
  show_logs
  snap
  [ "$NGROUPS" = "3" ] && [ "${LOGMB%.*}" = "512" ] || die "expected 3 x 512 MB groups, got $NGROUPS x $LOGMB MB"
}

cmd_after() {
  wait_healthy
  snap
  echo ">> The SAME burst on $NGROUPS x ${LOGMB} MB redo logs:"
  burst
  [ "$DW" -eq 0 ] || die "expected no checkpoint-incomplete waits after the fix, got $DW"
  [ "$DA" -eq 0 ] || die "expected no new 'Checkpoint not complete' lines after the fix, got $DA"
  echo "   -> no waits: each log now holds the whole burst, so the writer never catches up with the checkpoint."
}

cmd_advise() { wait_healthy; run_sys < scripts/advise.sql | sed '/^$/d' | sed 's/^/   /'; }

case "${1:-}" in
  up) cmd_up ;;
  setup) cmd_setup ;;
  before) cmd_before ;;
  fix) cmd_fix ;;
  after) cmd_after ;;
  advise) cmd_advise ;;
  all) cmd_setup; cmd_before; cmd_fix; cmd_after; echo ">> All checks passed." ;;
  sql) docker exec -it "$C" sqlplus / as sysdba ;;
  down) docker compose down ;;
  destroy) docker compose down -v ;;
  *) sed -n '2,20p' "$0"; exit 1 ;;
esac
