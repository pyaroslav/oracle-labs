#!/usr/bin/env bash
# Oracle Data Redaction lab — driver. Everything runs INSIDE the container via `docker exec`, so you only
# need Docker. Companion to the post "Oracle Data Redaction: Mask at Read Time, Prove It Isn't Access Control".
#
# It builds one table of fake-but-sensitive rows (card, SSN, email, salary), protects it with a DBMS_REDACT
# policy, then reads it back as two users and reads the datafile off disk:
#
#   PROVE : an ordinary CLERK (subject to the policy) sees masked values -- last-4-only card, masked SSN,
#           masked email name, salary 0. An AUDITOR holding EXEMPT REDACTION POLICY sees the REAL values,
#           proving the stored data is intact and redaction is per-user and applied at read time.
#   DISK  : grep the raw datafile -- the real card prefix '4111-2222-3333' is STILL on disk (redaction does
#           not encrypt at rest; it is the opposite of TDE). And a WHERE clause on the true card still finds
#           the row, proving redaction masks the OUTPUT, not the data -- it is not access control.
#
#   ./run.sh up        # start the database (first run pulls the image)
#   ./run.sh setup     # build the table + the 4-column redaction policy + the clerk/auditor users
#   ./run.sh prove     # read as CLERK (masked) and AUDITOR (real); assert both
#   ./run.sh disk      # grep the datafile: real card still there; WHERE on the true value still matches
#   ./run.sh all       # setup -> prove -> disk
#   ./run.sh sql       # SQL*Plus as SYSDBA inside the container
#   ./run.sh clerk     # SQL*Plus as the CLERK user (see the masking yourself)
#   ./run.sh down      # stop & remove the container (keeps the data volume)
#   ./run.sh destroy   # stop & remove the container AND the data volume
set -euo pipefail
cd "$(dirname "$0")"

C=ora-data-redaction-lab
export LAB_PORT="${LAB_PORT:-1521}"
LABPW='Lab_Passw0rd1'
CARD_PREFIX='4111-2222-3333'          # the real card prefix, written to disk in the clear
REAL_CARD='4111-2222-3333-0001'       # id = 1, used for the inference probe and the auditor assert

die() { echo "!! FAIL: $*" >&2; exit 1; }
run_sys()  { docker exec -i "$C" sqlplus -s -L "/ as sysdba"; }
run_user() { docker exec -i "$C" sqlplus -s -L "$1/$LABPW@localhost:1521/FREEPDB1"; }
read_meta() { run_sys < scripts/meta.sql; }
# match a line starting with KEY=, take everything after the first '=', strip whitespace (SQL*Plus
# right-justifies numbers with leading spaces; our values contain no internal spaces).
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
  echo ">> Building the table, the 4-column redaction policy, and the clerk/auditor users..."
  run_sys < scripts/setup.sql >/dev/null 2>&1 || true   # asserts below are the real check
  local m rows cols
  m=$(read_meta); rows=$(sig "$m" ROWS); cols=$(sig "$m" REDACT_COLS)
  echo "   rows=${rows:-?}   redacted columns=${cols:-?}"
  [ "${rows:-0}" -ge 2000 ] || die "expected >=2000 rows, got '${rows:-null}' -- setup failed:"$'\n'"$m"
  [ "${cols:-0}" -ge 4 ]    || die "expected 4 redacted columns, got '${cols:-null}' -- redaction policy not fully applied (is Advanced Security / DBMS_REDACT available?)"
  echo ">> Setup complete."
}

cmd_prove() {
  echo ">> Reading customer id=1 as two different users..."
  local C_OUT A_OUT c_card c_ssn c_email c_sal c_infer a_card a_ssn a_email a_sal
  C_OUT=$(run_user clerk   < scripts/read.sql)
  A_OUT=$(run_user auditor < scripts/read.sql)

  c_card=$(sig "$C_OUT" CARD);  c_ssn=$(sig "$C_OUT" SSN);   c_email=$(sig "$C_OUT" EMAIL)
  c_sal=$(sig "$C_OUT" SALARY); c_infer=$(sig "$C_OUT" INFER)
  a_card=$(sig "$A_OUT" CARD);  a_ssn=$(sig "$A_OUT" SSN);   a_email=$(sig "$A_OUT" EMAIL)
  a_sal=$(sig "$A_OUT" SALARY)

  printf '   %-10s %-24s %-24s\n' "column" "CLERK (subject)" "AUDITOR (exempt)"
  printf '   %-10s %-24s %-24s\n' "------" "---------------" "----------------"
  printf '   %-10s %-24s %-24s\n' "card"   "${c_card:-?}"  "${a_card:-?}"
  printf '   %-10s %-24s %-24s\n' "ssn"    "${c_ssn:-?}"   "${a_ssn:-?}"
  printf '   %-10s %-24s %-24s\n' "email"  "${c_email:-?}" "${a_email:-?}"
  printf '   %-10s %-24s %-24s\n' "salary" "${c_sal:-?}"   "${a_sal:-?}"

  # AUDITOR (exempt) must see the real values -- proves the stored data is intact and the exempt bypass works
  [ "$a_card"  = "$REAL_CARD" ]            || die "auditor did not see the real card (got '${a_card:-null}') -- EXEMPT REDACTION POLICY not effective"
  [ "$a_ssn"   = "123-45-0001" ]           || die "auditor did not see the real ssn (got '${a_ssn:-null}')"
  [ "$a_email" = "user0001@example.com" ]  || die "auditor did not see the real email (got '${a_email:-null}')"
  [ "$a_sal"   = "50001" ]                 || die "auditor did not see the real salary (got '${a_sal:-null}')"

  # CLERK (subject) must see MASKED values
  [[ "$c_card" == *0001 && "$c_card" != *"$CARD_PREFIX"* ]] || die "clerk card was not partially redacted (got '${c_card:-null}')"
  [[ "$c_ssn"  == *0001 && "$c_ssn"  != *"123-45"* ]]       || die "clerk ssn was not partially redacted (got '${c_ssn:-null}')"
  [[ "$c_email" == *"@example.com" && "$c_email" != *"user0001"* ]] || die "clerk email name was not redacted (got '${c_email:-null}')"
  [ "$c_sal" = "0" ]                       || die "clerk salary was not fully redacted to 0 (got '${c_sal:-null}')"

  # the gotcha: a WHERE clause on the TRUE card value still matches -- redaction masks output, not predicates
  [ "${c_infer:-0}" = "1" ] || die "inference probe failed: WHERE card='$REAL_CARD' as clerk returned '${c_infer:-null}', expected 1"

  echo "   -> clerk sees masking; auditor sees plaintext; and WHERE on the true card still matched as clerk."
}

# grep the datafile (inside the container) for the real card prefix; prints the match count.
# grep -a treats the binary datafile as text (the container image has no `strings`).
card_hits() { docker exec "$C" sh -c "grep -a -c '$CARD_PREFIX' '$1' 2>/dev/null || true" | tr -d '[:space:]'; }

cmd_disk() {
  echo ">> Reading the raw datafile off disk..."
  local m f hits
  m=$(read_meta); f=$(sig "$m" FILE_RED)
  [ -n "${f:-}" ] || die "could not read the RED_DATA datafile path:"$'\n'"$m"
  hits=$(card_hits "$f")
  echo "   real card prefix '$CARD_PREFIX' in datafile ($f): ${hits:-0} hit(s)"
  [ "${hits:-0}" -ge 1 ] || die "real card prefix NOT found on disk -- expected redaction to leave the data in the clear"
  echo "   -> the real card numbers are sitting on disk in plaintext. Redaction masked the query, not the datafile."
  echo "      (Encryption at rest is a SEPARATE control -- that's the TDE lab, where the canary is ABSENT from disk.)"
}

cmd_all() {
  cmd_setup
  echo
  echo ">> PROVE: masked for the clerk, plaintext for the exempt auditor"
  cmd_prove
  echo
  echo ">> DISK: what redaction does NOT do"
  cmd_disk
  echo
  echo ">> PASS: redaction masks at read time per user; the stored data is intact and still on disk;"
  echo ">>       and a predicate on the true value still matches -- redaction is display control, not access control."
  echo ">> ALL DRILLS COMPLETE"
}

cmd_sql()     { docker exec -it "$C" sqlplus "/ as sysdba"; }
cmd_clerk()   { docker exec -it "$C" sqlplus "clerk/$LABPW@localhost:1521/FREEPDB1"; }
cmd_down()    { docker compose down; }
cmd_destroy() { docker compose down -v; }

case "${1:-}" in
  up) cmd_up ;;
  setup) cmd_setup ;;
  prove) cmd_prove ;;
  disk) cmd_disk ;;
  all) cmd_all ;;
  sql) cmd_sql ;;
  clerk) cmd_clerk ;;
  down) cmd_down ;;
  destroy) cmd_destroy ;;
  *) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
