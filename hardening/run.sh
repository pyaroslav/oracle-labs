#!/usr/bin/env bash
# Oracle hardening-audit lab — driver. Everything runs INSIDE the container via `docker exec`, so you
# don't need an Oracle client on your machine. Just Docker. Companion to the post
# "The Oracle Hardening Checklist That Actually Matters".
#
# The lab puts a database into a realistic weak state, scores it against six controls, then hardens it
# and re-scores to PROVE every check flips from FAIL to PASS:
#
#   1. default-password accounts        (a live login test — password = username)
#   2. PUBLIC / ANY / DBA over-grants    (network packages to PUBLIC, %ANY% privs, DBA on an app account)
#   3. failed-login lockout              (the DEFAULT profile)
#   4. unified-auditing baseline         (ORA_SECURECONFIG + ORA_LOGON_FAILURES)
#
#   ./run.sh up        # start the database container (first run pulls the image)
#   ./run.sh setup     # put the database into the weak state (aka weaken)
#   ./run.sh audit     # score the current database — prints a PASS/FAIL table
#   ./run.sh harden    # apply the six controls
#   ./run.sh all       # weaken → audit (must FAIL) → harden → audit (must PASS) → summary
#   ./run.sh sql       # SQL*Plus as SYSDBA inside the container
#   ./run.sh down      # stop & remove the container (keeps the data volume)
#   ./run.sh destroy   # stop & remove the container AND the data volume
set -euo pipefail
cd "$(dirname "$0")"

C=ora-hardening-lab
export LAB_PORT="${LAB_PORT:-1521}"
AUDIT_FAILS=0

die() { echo "!! FAIL: $*" >&2; exit 1; }
run_sys() { docker exec -i "$C" sqlplus -s -L "/ as sysdba"; }

wait_healthy() {
  echo "Waiting for the database to be ready..."
  for i in $(seq 1 90); do
    if docker exec "$C" healthcheck.sh >/dev/null 2>&1; then echo "Database is ready."; return 0; fi
    sleep 5
  done
  die "timed out waiting for the database"
}

# A live login test: can you authenticate as demo/demo? This is the honest form of the default-password
# check — not "is it in a dictionary view" but "does the password actually work". Echoes 1 (yes) or 0.
demo_login_works() {
  local out
  out=$(printf "select 'LOGIN_OK' from dual;\n" \
        | docker exec -i "$C" sqlplus -s -L "demo/demo@//localhost:1521/FREEPDB1" 2>&1 || true)
  if printf '%s' "$out" | grep -q 'LOGIN_OK'; then printf '1'; else printf '0'; fi
}

row() { # name  violations  fail-detail
  if [ "$2" -gt 0 ]; then printf '  %-44s FAIL  (%s)\n' "$1" "$3"
  else                    printf '  %-44s PASS\n' "$1"; fi
}

run_audit() { # prints the table; sets AUDIT_FAILS
  local pw net anyp role prof aud out fails=0
  pw=$(demo_login_works)
  out=$(run_sys < scripts/audit.sql)
  net=$( printf '%s' "$out" | grep -oE 'PUBLIC_NET=[0-9]+'   | cut -d= -f2)
  anyp=$(printf '%s' "$out" | grep -oE 'ANY_PRIV=[0-9]+'     | cut -d= -f2)
  role=$(printf '%s' "$out" | grep -oE 'POWER_ROLE=[0-9]+'   | cut -d= -f2)
  prof=$(printf '%s' "$out" | grep -oE 'PROFILE_OPEN=[0-9]+' | cut -d= -f2)
  aud=$( printf '%s' "$out" | grep -oE 'AUDIT_OFF=[0-9]+'    | cut -d= -f2)
  for v in "$pw" "$net" "$anyp" "$role" "$prof" "$aud"; do
    [[ "$v" =~ ^[0-9]+$ ]] || die "could not parse audit output (a check returned no number):"$'\n'"$out"
  done
  echo "  --------------------------------------------------------------------"
  row "default-password account (demo/demo)"        "$pw"   "logs in with password = username"
  row "network packages granted to PUBLIC"          "$net"  "UTL_HTTP/TCP/SMTP/INADDR/FILE EXECUTE to PUBLIC"
  row "ANY-privileges on customer accounts"         "$anyp" "e.g. SELECT ANY TABLE on an app account"
  row "DBA / PDB_DBA on customer accounts"          "$role" "an app account holds a super-role"
  row "failed-login lockout (DEFAULT profile)"      "$prof" "FAILED_LOGIN_ATTEMPTS = UNLIMITED"
  row "unified-auditing baseline"                   "$aud"  "ORA_SECURECONFIG / ORA_LOGON_FAILURES disabled"
  echo "  --------------------------------------------------------------------"
  for v in "$pw" "$net" "$anyp" "$role" "$prof" "$aud"; do
    if [ "$v" -gt 0 ]; then fails=$((fails + 1)); fi
  done
  AUDIT_FAILS=$fails
  echo "  6 checks, $fails failed"
}

cmd_up()     { docker compose up -d; wait_healthy; }

cmd_setup() { # weaken
  wait_healthy
  echo ">> Putting the database into the weak state..."
  run_sys < scripts/weaken.sql >/dev/null
  echo ">> Weak state applied (default-password account, PUBLIC/ANY/DBA grants, open profile, auditing off)."
}

cmd_audit()  { echo ">> AUDIT:"; run_audit; }

cmd_harden() {
  echo ">> Applying the six hardening controls..."
  run_sys < scripts/harden.sql >/dev/null
  echo ">> Hardening applied."
}

cmd_all() {
  cmd_setup
  echo
  echo "================ AUDIT: the database as delivered (weak) ================"
  run_audit
  [ "$AUDIT_FAILS" -eq 6 ] || die "expected 6 failing checks in the weak state, got $AUDIT_FAILS — the checks themselves are broken"
  echo
  cmd_harden
  echo
  echo "===================== AUDIT: after hardening ============================"
  run_audit
  [ "$AUDIT_FAILS" -eq 0 ] || die "hardening left $AUDIT_FAILS check(s) failing — hardening incomplete"
  echo
  echo ">> PASS: all six controls went FAIL -> PASS. The checklist isn't a claim, it's a test."
  echo ">> ALL DRILLS COMPLETE"
}

cmd_sql()     { docker exec -it "$C" sqlplus "/ as sysdba"; }
cmd_down()    { docker compose down; }
cmd_destroy() { docker compose down -v; }

case "${1:-}" in
  up) cmd_up ;;
  setup|weaken) cmd_setup ;;
  audit) cmd_audit ;;
  harden) cmd_harden ;;
  all) cmd_all ;;
  sql) cmd_sql ;;
  down) cmd_down ;;
  destroy) cmd_destroy ;;
  *) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
