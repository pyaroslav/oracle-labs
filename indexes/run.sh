#!/usr/bin/env bash
# Oracle Indexes lab — driver. Everything runs INSIDE the container via `docker exec`, so you only need
# Docker. Companion to "Oracle Indexes: When They Help, When They Hurt, and How to Tell".
#
# Builds a 1,000,000-row skewed ORDERS table (customer_id ~100k distinct; status 950k SHIPPED / 49k OPEN /
# 1k PENDING) with an index on each, then runs five queries and reads the real plan + buffer gets:
#
#   PROVE : (1) a SELECTIVE query (customer_id = 500) uses idx_cust — an index range scan of a few buffers
#           instead of a full scan of thousands. (2) The SAME idx_status is IGNORED for the common value
#           (SHIPPED, 95% -> the optimizer picks TABLE ACCESS FULL) but USED for the rare value (PENDING,
#           0.1% -> INDEX RANGE SCAN). (3) FORCING idx_status on SHIPPED reads far MORE buffers than the full
#           scan it replaced — the index actively hurting. Selectivity decides; the plan proves it.
#
#   ./run.sh up      # start the database (first run pulls the image)
#   ./run.sh setup   # build the 1M-row table + both indexes + stats (frequency histogram on status)
#   ./run.sh prove   # run the five queries; assert help / ignore / hurt from plans + buffer gets
#   ./run.sh all     # setup -> prove
#   ./run.sh sql     # SQL*Plus as SYSDBA
#   ./run.sh down / destroy
set -euo pipefail
cd "$(dirname "$0")"

C=ora-indexes-lab
export LAB_PORT="${LAB_PORT:-1521}"

die() { echo "!! FAIL: $*" >&2; exit 1; }
run_sys() { docker exec -i "$C" sqlplus -s -L "/ as sysdba"; }
# match a line KEY=..., take everything after the first '=', strip whitespace. Plan operation strings contain
# spaces (INDEX RANGE SCAN) -> they become INDEXRANGESCAN etc., and we substring-match those stripped forms.
sig() { printf '%s\n' "$1" | grep -E "^$2=" | head -1 | cut -d= -f2- | tr -d '[:space:]'; }
has() { case "$1" in *"$2"*) return 0;; *) return 1;; esac; }

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
  echo ">> Building the 1,000,000-row ORDERS table (this loads 1M rows + gathers stats, ~30-60s)..."
  run_sys < scripts/setup.sql >/dev/null 2>&1 || true
  local m rows shipped pending idx
  m=$(run_sys < scripts/meta.sql)
  rows=$(sig "$m" ROWS); shipped=$(sig "$m" SHIPPED); pending=$(sig "$m" PENDING); idx=$(sig "$m" IDX)
  echo "   rows=${rows:-?}  shipped=${shipped:-?}  pending=${pending:-?}  indexes=${idx:-?}"
  [ "${rows:-0}" = "1000000" ] || die "expected 1,000,000 rows, got '${rows:-null}' -- setup failed:"$'\n'"$m"
  [ "${shipped:-0}" = "950000" ] || die "expected 950,000 SHIPPED rows, got '${shipped:-null}'"
  [ "${pending:-0}" = "1000" ]  || die "expected 1,000 PENDING rows, got '${pending:-null}'"
  [ "${idx:-0}" = "2" ]         || die "expected 2 indexes on ORDERS, got '${idx:-null}'"
  echo ">> Setup complete."
}

cmd_prove() {
  echo ">> Running the five queries and reading their plans + buffer gets..."
  local out hi_op hi_buf hf_buf sh_op sh_buf shf_buf pe_op pe_buf
  out=$(run_sys < scripts/probe.sql)
  hi_op=$(sig "$out" HELPS_IDX_OP);       hi_buf=$(sig "$out" HELPS_IDX_BUF)
  hf_buf=$(sig "$out" HELPS_FULL_BUF)
  sh_op=$(sig "$out" SHIPPED_OP);         sh_buf=$(sig "$out" SHIPPED_BUF)
  shf_buf=$(sig "$out" SHIPPED_FORCED_BUF)
  pe_op=$(sig "$out" PENDING_OP);         pe_buf=$(sig "$out" PENDING_BUF)

  printf '   %-34s %-26s %s\n' "query" "plan (access op)" "buffer gets"
  printf '   %-34s %-26s %s\n' "-----" "----------------" "-----------"
  printf '   %-34s %-26s %s\n' "customer_id=500 (natural)"  "index range scan"  "${hi_buf:-?}"
  printf '   %-34s %-26s %s\n' "customer_id=500 (FULL hint)" "table access full" "${hf_buf:-?}"
  printf '   %-34s %-26s %s\n' "status=SHIPPED 95% (natural)" "table access full" "${sh_buf:-?}"
  printf '   %-34s %-26s %s\n' "status=SHIPPED (INDEX hint)"  "index range scan"  "${shf_buf:-?}"
  printf '   %-34s %-26s %s\n' "status=PENDING 0.1% (natural)" "index range scan" "${pe_buf:-?}"

  # (1) a selective query uses the index, and it's WAY cheaper than the full scan of the same query
  has "$hi_op" "INDEXRANGESCAN" || die "selective customer_id query did NOT use an index range scan (op='${hi_op:-null}')"
  [ "${hi_buf:-999999}" -lt 200 ]                  || die "index range scan should be cheap, got ${hi_buf:-null} buffers"
  [ "${hf_buf:-0}" -ge 1000 ]                      || die "the forced full scan should be expensive, got ${hf_buf:-null} buffers"
  [ "${hf_buf:-0}" -ge $(( ${hi_buf:-1} * 20 )) ]  || die "index should be >=20x cheaper than full scan (idx=${hi_buf}, full=${hf_buf})"

  # (2) same idx_status: IGNORED for the common value, USED for the rare value
  has "$sh_op" "TABLEACCESSFULL" || die "SHIPPED (95%) should be a FULL scan -- the optimizer should ignore idx_status (op='${sh_op:-null}')"
  has "$pe_op" "INDEXRANGESCAN"  || die "PENDING (0.1%) should use idx_status (op='${pe_op:-null}')"

  # (3) forcing the index on the common value reads FAR more than the full scan -- the index hurts
  [ "${shf_buf:-0}" -gt "${sh_buf:-0}" ] || die "forcing idx_status on SHIPPED should read MORE than the full scan (forced=${shf_buf}, natural=${sh_buf})"

  echo "   -> selective query: index range scan ${hi_buf} vs full ${hf_buf} buffers (index wins big)."
  echo "   -> same idx_status: IGNORED for SHIPPED (full scan) but USED for PENDING (index) -- selectivity decides."
  echo "   -> forced on SHIPPED it read ${shf_buf} vs the full scan's ${sh_buf} buffers -- the index HURT."
}

cmd_all() {
  cmd_setup; echo
  cmd_prove; echo
  echo ">> PASS: the right index on a selective predicate is a huge win; the wrong (or forced) index on a"
  echo ">>       common value is a loss; and the same index flips between help and hurt purely on selectivity."
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
