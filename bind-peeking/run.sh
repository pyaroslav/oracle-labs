#!/usr/bin/env bash
# Oracle bind peeking + adaptive cursor sharing lab — driver. Everything runs INSIDE the container via `docker exec`.
# Companion to "Same SQL, Fast for One Value, Slow for Another."
#
#   ORDERS has 200,000 rows: 200 OPEN, 199,800 CLOSED, with a histogram on STATUS. One statement joins it to a
#   1,000,000-row CUSTOMERS table with a bind:  ... where o.status = :s
#
#   SETUP : build the schema and gather stats (frequency histogram on STATUS).
#   PEEK  : fresh shared pool; the FIRST execution binds 'OPEN' -> the optimizer peeks it and picks nested loops
#           (right for 200 rows). Then 'CLOSED' runs 5 times and reuses that cursor: 199,800 index probes each time.
#           Asserted: same child cursor, nested loops, every CLOSED run >= 10x the work of the hash-join plan,
#           and adaptive cursor sharing never splits the cursor.
#   FIX   : the skewed, low-cardinality predicate as a literal: each value gets its own cursor and plan.
#           'CLOSED' -> hash join (asserted <= 10% of the peeked plan's work), 'OPEN' -> nested loops (cheap).
#
#   ./run.sh up | setup | peek | fix | all | sql | down | destroy
set -euo pipefail
cd "$(dirname "$0")"

C=ora-bind-peeking-lab
export LAB_PORT="${LAB_PORT:-1521}"
USERCON="acs/Lab_Passw0rd1@//localhost/FREEPDB1"

die() { echo "!! FAIL: $*" >&2; exit 1; }
run_sys() { docker exec -i "$C" sqlplus -s -L "/ as sysdba"; }
sig() { printf '%s\n' "$1" | { grep -E "^$2=" || true; } | head -1 | cut -d= -f2- | tr -d '[:space:]'; }

wait_healthy() {
  echo "Waiting for the database to be ready..."
  for i in $(seq 1 90); do
    if docker exec "$C" healthcheck.sh >/dev/null 2>&1; then echo "Database is ready."; return 0; fi
    sleep 5
  done
  die "timed out waiting for the database"
}

copy_scripts() { for f in scripts/run1.sql scripts/run_lit.sql scripts/plan.sql; do docker cp "$f" "$C:/tmp/$(basename "$f")" >/dev/null; done; }

# exec1 <script> <value>: one execution in a fresh session; sets ROWS GETS CHILD SQLID JOIN BAWARE
exec1() {
  local out plan
  out=$(docker exec -i "$C" sqlplus -s -L "$USERCON" "@/tmp/$1" "$2") || die "execution failed:"$'\n'"$out"
  ROWS=$(sig "$out" ROWS); GETS=$(sig "$out" GETS); CHILD=$(sig "$out" CHILD); SQLID=$(sig "$out" SQLID)
  [ -n "$GETS" ] && [ -n "$SQLID" ] || die "measurement failed:"$'\n'"$out"
  plan=$(docker exec -i "$C" sqlplus -s -L "/ as sysdba" @/tmp/plan.sql "$SQLID" "$CHILD")
  if   printf '%s' "$plan" | grep -q "NESTED LOOPS"; then JOIN="NESTED LOOPS"
  elif printf '%s' "$plan" | grep -q "HASH JOIN";    then JOIN="HASH JOIN"
  else JOIN="?"; fi
  BAWARE=$(sig "$plan" BAWARE)
  printf '   %-7s rows=%-7s logical reads=%-8s child cursor=%s  plan=%s\n' "$2" "$ROWS" "$GETS" "$CHILD" "$JOIN"
}

cmd_up() { docker compose up -d; wait_healthy; }

cmd_setup() {
  wait_healthy
  echo ">> Building ORDERS (200,000 rows: 200 OPEN / 199,800 CLOSED) and CUSTOMERS (1,000,000 rows); histogram on STATUS..."
  local out; out=$(run_sys < scripts/setup.sql) || die "setup.sql failed:"$'\n'"$out"
  printf '%s\n' "$out" | { grep -E "^(OPEN_ROWS|HISTOGRAM)=" || true; } | sed 's/^/   /'
  printf '%s' "$out" | grep -q "OPEN_ROWS=200 CLOSED_ROWS=199800" || die "unexpected row counts:"$'\n'"$out"
  printf '%s' "$out" | grep -q "HISTOGRAM=FREQUENCY" || die "no frequency histogram on STATUS"
  copy_scripts
  echo ">> Setup complete."
}

cmd_peek() {
  copy_scripts
  echo ">> Fresh shared pool. The SAME statement, bound:  ... where o.status = :s"
  run_sys <<< "alter system flush shared_pool;" >/dev/null
  exec1 run1.sql OPEN
  local c0=$CHILD id0=$SQLID
  [ "$JOIN" = "NESTED LOOPS" ] || die "expected the OPEN peek to pick nested loops, got '$JOIN'"
  local i bad=0
  for i in 1 2 3 4 5; do
    exec1 run1.sql CLOSED
    [ "$SQLID" = "$id0" ] && [ "$CHILD" = "$c0" ] || die "expected CLOSED to reuse child $c0, it ran child $CHILD"
    [ "$JOIN" = "NESTED LOOPS" ] || die "expected CLOSED to inherit nested loops, got '$JOIN'"
    bad=$GETS
  done
  echo "$bad" > .peek_gets
  echo "   -> 'OPEN' was peeked first, so all five 'CLOSED' runs inherited its nested-loops plan: ~$bad logical reads"
  echo "      each, probing CUSTOMERS 199,800 times. Adaptive cursor sharing never split the cursor (bind aware: ${BAWARE:-?})."
}

cmd_fix() {
  copy_scripts
  [ -f .peek_gets ] || cmd_peek >/dev/null
  local bad; bad=$(cat .peek_gets)
  echo ">> The fix for a skewed, low-cardinality column: the predicate as a literal -> one cursor + plan per value"
  exec1 run_lit.sql CLOSED
  local good=$GETS
  [ "$JOIN" = "HASH JOIN" ] || die "expected CLOSED (literal) to get a hash join, got '$JOIN'"
  [ $(( good * 10 )) -le "$bad" ] || die "expected the literal CLOSED plan to do <=10% of the peeked plan's work ($bad), got $good"
  exec1 run_lit.sql OPEN
  [ "$JOIN" = "NESTED LOOPS" ] || die "expected OPEN (literal) to keep nested loops, got '$JOIN'"
  echo "   -> 'CLOSED' with its own plan: $good logical reads instead of $bad ($(( bad / good ))x less work);"
  echo "      'OPEN' keeps its cheap nested loops. Two distinct values = two cursors, no hard-parse storm."
}

cmd_all() {
  cmd_setup; echo
  cmd_peek; echo
  cmd_fix; echo
  echo ">> PASS: the first bind value decided the plan for everyone; the common value inherited a nested-loops plan"
  echo ">>       at >=10x the work, and adaptive cursor sharing did not rescue it. A per-value plan fixed it."
  echo ">> ALL DRILLS COMPLETE"
}

cmd_sql()     { docker exec -it "$C" sqlplus "/ as sysdba"; }
cmd_down()    { docker compose down; }
cmd_destroy() { rm -f .peek_gets; docker compose down -v; }

case "${1:-}" in
  up) cmd_up ;; setup) cmd_setup ;; peek) cmd_peek ;; fix) cmd_fix ;; all) cmd_all ;;
  sql) cmd_sql ;; down) cmd_down ;; destroy) cmd_destroy ;;
  *) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
