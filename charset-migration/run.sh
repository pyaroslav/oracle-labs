#!/usr/bin/env bash
# Oracle character-set migration lab -- driver. Everything runs INSIDE the container via `docker exec`, so you
# only need Docker. Companion to "The Migration Completed Successfully. Half the Names Are Now Question Marks."
#
#   REPRODUCE : a customers table in the AL32UTF8 (Unicode) database holds 10 names -- 5 plain ASCII, 5 with
#               non-ASCII characters (Latin accents + a CJK name). Model migrating into a NARROWER target set
#               (US7ASCII) with CONVERT: the row count stays 10 and nothing errors, but half the names are
#               damaged -- accents silently stripped (Jose) and unmappable characters turned to '?'. Asserts
#               the loss happens (and that a Western-European target, WE8MSWIN1252, still loses the CJK name).
#   FIX       : the pre-migration SCAN that flags exactly the rows a US7ASCII target would damage, and the
#               migration into an AL32UTF8 (Unicode) target instead -- a superset, so zero loss. Asserts the
#               scan flags the damaged rows and the Unicode target preserves every character.
#
#   ./run.sh up        # start the database (first run pulls the image)
#   ./run.sh setup     # build the customers table with a mix of ASCII and non-ASCII names
#   ./run.sh reproduce # migrate to a narrow target charset; assert silent data loss
#   ./run.sh fix       # scan for lossy rows + migrate to a Unicode target; assert zero loss
#   ./run.sh all       # setup -> reproduce -> fix
#   ./run.sh sql       # SQL*Plus as SYSDBA (UTF-8 client)
#   ./run.sh down / destroy
set -euo pipefail
cd "$(dirname "$0")"

C=ora-charset-migration-lab
export LAB_PORT="${LAB_PORT:-1521}"

die() { echo "!! FAIL: $*" >&2; exit 1; }
# UTF-8 client so any non-ASCII output displays correctly; the assertions are server-side CONVERT comparisons,
# so they do not depend on the client charset.
run_sys() { docker exec -e NLS_LANG=.AL32UTF8 -i "$C" sqlplus -s -L "/ as sysdba"; }
sig() { printf '%s\n' "$1" | grep -E "^$2=" | head -1 | cut -d= -f2- | tr -d '[:space:]'; }
show_block() { printf '%s\n' "$1" | awk "/>>>$2/{f=1;next} />>>END$2/{f=0} f"; }

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
  echo ">> Building the customers table in the AL32UTF8 database (5 ASCII + 5 non-ASCII names)..."
  run_sys < scripts/setup.sql >/dev/null 2>&1 || true
  local m rows mb
  m=$(run_sys < scripts/meta.sql)
  rows=$(sig "$m" ROWS); mb=$(sig "$m" MULTIBYTE)
  echo "   rows=${rows:-?}  non-ASCII (multibyte) names=${mb:-?}"
  [ "${rows:-0}" = "10" ] || die "expected 10 rows, got '${rows:-null}' -- setup failed:"$'\n'"$m"
  [ "${mb:-0}" = "5" ]    || die "expected 5 multibyte names, got '${mb:-null}'"
  echo ">> Setup complete."
}

cmd_reproduce() {
  echo ">> Migrating into a NARROWER target character set (US7ASCII)..."
  local out rows7 us7 we8 q
  out=$(run_sys < scripts/loss.sql)
  rows7=$(sig "$out" ROWS_AFTER); us7=$(sig "$out" US7_LOST); we8=$(sig "$out" WE8_LOST); q=$(sig "$out" HAS_QMARK)
  echo "   rows after migration: ${rows7:-?}   errors raised: 0"
  echo "   names damaged by a US7ASCII target: ${us7:-?} of ${rows7:-?}   (of those, turned into '?': ${q:-?})"
  echo "   names still damaged by a WE8MSWIN1252 (Western European) target: ${we8:-?}"
  show_block "$out" EXAMPLES | sed 's/^/      /'
  [ "${rows7:-0}" = "10" ]  || die "expected the row count to still be 10 after migration, got '${rows7:-null}'"
  [ "${us7:-0}" -ge 5 ]     || die "expected at least 5 names damaged by the US7ASCII target, got '${us7:-null}'"
  [ "${q:-0}" -ge 1 ]       || die "expected at least one name turned into '?', got '${q:-null}'"
  [ "${we8:-0}" -ge 1 ]     || die "expected the CJK name still lost by a WE8MSWIN1252 target, got '${we8:-null}'"
  echo "   -> the load 'succeeded' (10 rows, no errors) yet half the names lost characters. Silent data loss."
}

cmd_fix() {
  echo ">> FIX 1 -- pre-migration scan: which rows would a US7ASCII target damage?"
  local out flagged al32
  out=$(run_sys < scripts/fix.sql)
  flagged=$(sig "$out" SCAN_FLAGGED); al32=$(sig "$out" AL32_LOST)
  echo "   scan flagged ${flagged:-?} row(s) as lossy BEFORE cutover."
  echo ">> FIX 2 -- migrate into an AL32UTF8 (Unicode) target instead:"
  echo "   names damaged by the Unicode target: ${al32:-?}"
  [ "${flagged:-0}" -ge 5 ] || die "expected the scan to flag the 5 lossy rows, got '${flagged:-null}'"
  [ "${al32:-x}" = "0" ]    || die "expected ZERO loss migrating to a Unicode target, got '${al32:-null}'"
  echo "   -> the scan catches the damage in advance, and a Unicode target preserves every character."
}

cmd_all() {
  cmd_setup; echo
  cmd_reproduce; echo
  cmd_fix; echo
  echo ">> PASS: migrating Unicode data into a narrower character set silently stripped accents and turned"
  echo ">>       unmappable names into '?' -- half the rows -- with no error and an unchanged row count; a"
  echo ">>       pre-migration scan flagged them and a Unicode target preserved everything."
  echo ">> ALL DRILLS COMPLETE"
}

cmd_sql()     { docker exec -e NLS_LANG=.AL32UTF8 -it "$C" sqlplus "/ as sysdba"; }
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
