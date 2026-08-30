#!/usr/bin/env bash
# Oracle Partition Pruning lab — driver. Everything runs INSIDE the container via `docker exec`, so you only
# need Docker. Companion to the post "Oracle Partition Pruning: Read One Partition, Not the Whole Table".
#
# It builds a monthly range-partitioned table (1.2M rows, 24 partitions) and runs the SAME logical query
# (all June-2025 orders) two ways:
#
#   PRUNE : WHERE order_date >= DATE '2025-06-01' AND order_date < DATE '2025-07-01'
#           -> the optimizer PRUNES to a single partition (PARTITION RANGE SINGLE, Pstart=Pstop), few buffers.
#   FULL  : WHERE TO_CHAR(order_date,'YYYY-MM') = '2025-06'   (a function on the partition key)
#           -> pruning is DEFEATED (PARTITION RANGE ALL), every partition is scanned, ~24x the buffers.
#
# Same row count either way; the only difference is how much of the table Oracle had to read.
#
#   ./run.sh up        # start the database (first run pulls the image)
#   ./run.sh setup     # build the partitioned table + 1.2M rows + stats
#   ./run.sh prove     # run both queries; show the plans; assert pruning cuts the work while the count matches
#   ./run.sh all       # setup -> prove
#   ./run.sh sql       # SQL*Plus as SYSDBA inside the container
#   ./run.sh down      # stop & remove the container (keeps the data volume)
#   ./run.sh destroy   # stop & remove the container AND the data volume
set -euo pipefail
cd "$(dirname "$0")"

C=ora-partition-pruning-lab
export LAB_PORT="${LAB_PORT:-1521}"

die() { echo "!! FAIL: $*" >&2; exit 1; }
run_sys() { docker exec -i "$C" sqlplus -s -L "/ as sysdba"; }
# match a line starting with KEY=, take everything after the first '=', strip whitespace.
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
  echo ">> Building the partitioned table (1.2M rows, monthly partitions) + gathering stats..."
  run_sys < scripts/setup.sql >/dev/null 2>&1 || true   # asserts below are the real check
  local m parts rows
  m=$(run_sys < scripts/meta.sql); parts=$(sig "$m" PARTS); rows=$(sig "$m" ROWS)
  echo "   partitions=${parts:-?}   rows=${rows:-?}"
  [ "${rows:-0}"  -ge 1200000 ] || die "expected >=1.2M rows, got '${rows:-null}' -- setup failed:"$'\n'"$m"
  [ "${parts:-0}" -ge 24 ]      || die "expected >=24 partitions, got '${parts:-null}' -- interval partitioning didn't create them"
  echo ">> Setup complete."
}

cmd_prove() {
  echo ">> Running the same query two ways (prune vs function-defeated)..."
  local out pc fc pop fop pstart pstop fstart fstop pbuf fbuf ratio
  out=$(run_sys < scripts/probe.sql)
  # show the two real plans (everything before the signals block)
  printf '%s\n' "$out" | sed -n '/====== PLAN A/,/>>>SIGNALS/p' | sed '/>>>SIGNALS/d'

  pc=$(sig "$out" PRUNE_COUNT);  fc=$(sig "$out" FULL_COUNT)
  pop=$(sig "$out" PRUNE_OP);    fop=$(sig "$out" FULL_OP)
  pstart=$(sig "$out" PRUNE_PSTART); pstop=$(sig "$out" PRUNE_PSTOP)
  fstart=$(sig "$out" FULL_PSTART);  fstop=$(sig "$out" FULL_PSTOP)
  pbuf=$(sig "$out" PRUNE_BUFFERS);  fbuf=$(sig "$out" FULL_BUFFERS)

  echo "   PRUNE: op=${pop:-?} partitions ${pstart:-?}..${pstop:-?}  count=${pc:-?}  buffers=${pbuf:-?}"
  echo "   FULL : op=${fop:-?} partitions ${fstart:-?}..${fstop:-?}  count=${fc:-?}  buffers=${fbuf:-?}"

  # same logical result both ways
  [ -n "${pc:-}" ] && [ "$pc" = "$fc" ] || die "the two queries returned different counts (prune=$pc full=$fc) -- they should match"
  [ "$pc" = "50000" ] || die "expected 50000 June-2025 rows, got '$pc' -- setup data is off"

  # the pruned query touches ONE partition; the function query scans ALL of them
  case "$pop" in *SINGLE*) : ;; *) die "pruned query did not get PARTITION RANGE SINGLE (got '${pop:-null}')";; esac
  case "$fop" in *ALL*)    : ;; *) die "function query was expected to scan ALL partitions (got '${fop:-null}')";; esac
  [ "${pstart:-x}" = "${pstop:-y}" ]  || die "pruned query did not collapse to a single partition (Pstart=$pstart Pstop=$pstop)"
  [ "${fstart:-x}" != "${fstop:-x}" ] || die "function query did not span multiple partitions (Pstart=$fstart Pstop=$fstop)"

  # pruning must save most of the work
  [ "${pbuf:-0}" -gt 0 ] && [ "${fbuf:-0}" -gt 0 ] || die "could not read buffer gets (prune=$pbuf full=$fbuf)"
  ratio=$(( fbuf / (pbuf>0?pbuf:1) ))
  echo "   -> same 50,000 rows; pruning read ~${ratio}x fewer buffers by skipping the other partitions."
  [ "$fbuf" -ge $(( pbuf * 5 )) ] || die "pruning did not cut the work enough (full=$fbuf prune=$pbuf, expected full >= 5x prune)"
}

cmd_all() {
  cmd_setup
  echo
  echo ">> PROVE: one partition vs all of them, same answer"
  cmd_prove
  echo
  echo ">> PASS: a range predicate on the partition key prunes to one partition; a function on it scans them all."
  echo ">> ALL DRILLS COMPLETE"
}

cmd_sql()     { docker exec -it "$C" sqlplus "/ as sysdba"; }
cmd_down()    { docker compose down; }
cmd_destroy() { docker compose down -v; }

case "${1:-}" in
  up) cmd_up ;;
  setup) cmd_setup ;;
  prove) cmd_prove ;;
  all) cmd_all ;;
  sql) cmd_sql ;;
  down) cmd_down ;;
  destroy) cmd_destroy ;;
  *) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
