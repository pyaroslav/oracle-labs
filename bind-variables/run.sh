#!/usr/bin/env bash
# Oracle bind-variables lab — driver. Everything runs INSIDE the container via `docker exec`, so you only
# need Docker. Companion to "Bind Variables: The Hard-Parse Storm That Melts Your Shared Pool".
#
# Runs ONE logical query (select count(*) from bindlab.widgets where id = <n>) 1,000 times two ways:
#
#   PROVE : (1) LITERALS — the value is baked into the SQL text, so every iteration is a distinct statement:
#           ~1,000 parent cursors in V$SQL and ~1,000 hard parses, and megabytes of shared pool burned on
#           un-shareable cursors. (2) BINDS — the value is a bind variable (:b), so there is ONE cursor, one
#           hard parse, and 1,000 executions of it, for a few KB. Same answer, a fraction of the work.
#
#   ./run.sh up      # start the database (first run pulls the image)
#   ./run.sh setup   # build the 1,000-row bindlab.widgets table
#   ./run.sh prove   # run both loops; assert the cursor + hard-parse counts
#   ./run.sh all     # setup -> prove
#   ./run.sh sql     # SQL*Plus as SYSDBA
#   ./run.sh down / destroy
set -euo pipefail
cd "$(dirname "$0")"

C=ora-bind-variables-lab
export LAB_PORT="${LAB_PORT:-1521}"

die() { echo "!! FAIL: $*" >&2; exit 1; }
run_sys() { docker exec -i "$C" sqlplus -s -L "/ as sysdba"; }
# match a line KEY=..., take everything after the first '=', strip whitespace.
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
  echo ">> Building the 1,000-row bindlab.widgets table..."
  run_sys < scripts/setup.sql >/dev/null 2>&1 || true
  local m rows tab
  m=$(run_sys < scripts/meta.sql)
  rows=$(sig "$m" ROWS); tab=$(sig "$m" TAB)
  echo "   rows=${rows:-?}  table=${tab:-?}"
  [ "${tab:-0}" = "1" ]      || die "bindlab.widgets was not created -- setup failed:"$'\n'"$m"
  [ "${rows:-0}" = "1000" ]  || die "expected 1,000 rows, got '${rows:-null}'"
  echo ">> Setup complete."
}

cmd_prove() {
  echo ">> Running the same query 1,000 times as LITERALS, then as BINDS..."
  local lo bo lit_cur lit_hp lit_mem bind_cur bind_hp bind_exec bind_mem
  lo=$(run_sys < scripts/literals.sql)
  bo=$(run_sys < scripts/binds.sql)
  lit_cur=$(sig "$lo" LIT_CURSORS);   lit_hp=$(sig "$lo" LIT_HARD_PARSES); lit_mem=$(sig "$lo" LIT_MEM_KB)
  bind_cur=$(sig "$bo" BIND_CURSORS); bind_hp=$(sig "$bo" BIND_HARD_PARSES)
  bind_exec=$(sig "$bo" BIND_EXECS);  bind_mem=$(sig "$bo" BIND_MEM_KB)

  printf '   %-26s %-14s %-14s %s\n' "1,000 runs of one query" "cursors" "hard parses" "shared pool"
  printf '   %-26s %-14s %-14s %s\n' "------------------------" "-------" "-----------" "-----------"
  printf '   %-26s %-14s %-14s %s\n' "with LITERALS"  "${lit_cur:-?}"  "${lit_hp:-?}"  "${lit_mem:-?} KB"
  printf '   %-26s %-14s %-14s %s\n' "with a BIND (:b)" "${bind_cur:-?}" "${bind_hp:-?}" "${bind_mem:-?} KB"
  printf '   %-26s %-14s %-14s\n'    "bind executions"  "${bind_exec:-?}" "(of the 1 cursor)"

  # (1) literals explode into ~1,000 cursors and ~1,000 hard parses
  [ "${lit_cur:-0}"  -ge 900 ] || die "expected ~1,000 literal cursors in V\$SQL, got ${lit_cur:-null}"
  [ "${lit_hp:-0}"   -ge 900 ] || die "expected ~1,000 hard parses for literals, got ${lit_hp:-null}"
  # (2) the bind collapses to a single cursor with ~1 hard parse but all 1,000 executions
  [ "${bind_cur:-99}"  -le 3 ]    || die "expected 1 bind cursor in V\$SQL, got ${bind_cur:-null}"
  [ "${bind_hp:-99}"   -le 20 ]   || die "expected ~1 hard parse for the bind, got ${bind_hp:-null}"
  [ "${bind_exec:-0}"  -ge 1000 ] || die "expected 1,000 executions of the bind cursor, got ${bind_exec:-null}"
  # (3) literals cost orders of magnitude more hard parses than the bind
  [ "${lit_hp:-0}" -ge $(( ${bind_hp:-1} * 20 )) ] || die "literals should hard-parse >=20x the bind (lit=${lit_hp}, bind=${bind_hp})"

  echo "   -> literals: ${lit_cur} cursors / ${lit_hp} hard parses / ${lit_mem} KB of shared pool."
  echo "   -> bind:     ${bind_cur} cursor / ${bind_hp} hard parse / ${bind_mem} KB, executed ${bind_exec} times."
  echo "   -> same answer; the bind did it with a fraction of the parsing and the memory."
}

cmd_all() {
  cmd_setup; echo
  cmd_prove; echo
  echo ">> PASS: one query run 1,000 times is ~1,000 cursors + ~1,000 hard parses with literals, but a single"
  echo ">>       cursor + one hard parse + 1,000 executions with a bind variable. Bind your variables."
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
