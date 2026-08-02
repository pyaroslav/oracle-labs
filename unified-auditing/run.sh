#!/usr/bin/env bash
# Oracle unified-auditing lab — driver. Everything runs INSIDE the container via `docker exec`, so you
# only need Docker. Companion to the post "Oracle Unified Auditing Without the Noise".
#
# It enables the baseline policies plus one custom policy, TRIGGERS three real audited events, flushes
# the queued audit buffer, and PROVES each event was recorded in UNIFIED_AUDIT_TRAIL:
#
#   1. a failed login            -> caught by ORA_LOGON_FAILURES
#   2. a CREATE USER             -> caught by ORA_SECURECONFIG (the pre-enabled baseline)
#   3. a read of a sensitive tbl -> caught by a custom AUDIT POLICY
#
#   ./run.sh up        # start the database (first run pulls the image)
#   ./run.sh setup     # sensitive table, an auditee user, baseline + custom policy
#   ./run.sh trigger   # perform the three audited actions
#   ./run.sh verify    # flush the buffer, then prove each landed in the trail
#   ./run.sh all       # up-to-date: setup -> trigger -> verify -> summary (fails if any wasn't caught)
#   ./run.sh sql       # SQL*Plus as SYSDBA inside the container
#   ./run.sh down      # stop & remove the container (keeps the data volume)
#   ./run.sh destroy   # stop & remove the container AND the data volume
set -euo pipefail
cd "$(dirname "$0")"

C=ora-unified-auditing-lab
export LAB_PORT="${LAB_PORT:-1521}"
CONN='auditee/Lab_Passw0rd1@//localhost:1521/FREEPDB1'
WRONG='auditee/WrongPass_9z@//localhost:1521/FREEPDB1'

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

cmd_up()    { docker compose up -d; wait_healthy; }

cmd_setup() {
  wait_healthy
  echo ">> Setting up: sensitive table, auditee user, baseline + custom policy..."
  run_sys < scripts/setup.sql >/dev/null
  echo ">> Setup complete (ORA_SECURECONFIG + ORA_LOGON_FAILURES + aud_salary_access enabled)."
}

cmd_trigger() {
  echo ">> Triggering audited events..."
  # 1. a failed login -> ORA_LOGON_FAILURES
  printf 'select 1 from dual;\n' | docker exec -i "$C" sqlplus -s -L "$WRONG" >/dev/null 2>&1 || true
  echo "   1. failed login attempted (auditee / wrong password)"
  # 2. a CREATE USER -> ORA_SECURECONFIG
  run_sys >/dev/null <<'SQL'
alter session set container = FREEPDB1;
begin execute immediate 'drop user aud_probe cascade'; exception when others then null; end;
/
create user aud_probe identified by "Lab_Passw0rd1";
exit
SQL
  echo "   2. created a new user (aud_probe) -- a security-configuration change"
  # 3. a read of the sensitive table -> custom policy
  printf 'select count(*) from hr.employee_salary;\n' | docker exec -i "$C" sqlplus -s -L "$CONN" >/dev/null 2>&1 \
    || die "auditee could not read hr.employee_salary"
  echo "   3. auditee read hr.employee_salary"
}

row() { # label  count  detail
  if [ "$2" -ge 1 ]; then printf '  %-40s CAPTURED  (%s record/s)\n' "$1" "$2"
  else                    printf '  %-40s MISSED    (%s) -- policy not capturing!\n' "$1" "$2"; fi
}

cmd_verify() {
  echo ">> VERIFY: flushing the audit buffer, then reading UNIFIED_AUDIT_TRAIL..."
  local out fl cu ss fails=0
  out=$(run_sys < scripts/verify.sql)
  fl=$(printf '%s' "$out" | grep -oE 'FAILED_LOGIN=[0-9]+'     | cut -d= -f2)
  cu=$(printf '%s' "$out" | grep -oE 'CREATE_USER=[0-9]+'      | cut -d= -f2)
  ss=$(printf '%s' "$out" | grep -oE 'SENSITIVE_SELECT=[0-9]+' | cut -d= -f2)
  for v in "$fl" "$cu" "$ss"; do [[ "$v" =~ ^[0-9]+$ ]] || die "could not parse audit counts:"$'\n'"$out"; done
  echo "  --------------------------------------------------------------------"
  row "failed login  (ORA_LOGON_FAILURES)"        "$fl"
  row "CREATE USER   (ORA_SECURECONFIG)"          "$cu"
  row "sensitive read (aud_salary_access policy)" "$ss"
  echo "  --------------------------------------------------------------------"
  for v in "$fl" "$cu" "$ss"; do if [ "$v" -lt 1 ]; then fails=$((fails+1)); fi; done
  [ "$fails" -eq 0 ] || die "$fails audited event(s) were NOT captured -- a policy is broken"
  echo "  3 events triggered, 3 captured."
}

cmd_all() {
  cmd_setup
  echo
  cmd_trigger
  echo
  cmd_verify
  echo
  echo ">> PASS: every triggered action was recorded in the unified audit trail."
  echo ">> ALL DRILLS COMPLETE"
}

cmd_sql()     { docker exec -it "$C" sqlplus "/ as sysdba"; }
cmd_down()    { docker compose down; }
cmd_destroy() { docker compose down -v; }

case "${1:-}" in
  up) cmd_up ;;
  setup) cmd_setup ;;
  trigger) cmd_trigger ;;
  verify) cmd_verify ;;
  all) cmd_all ;;
  sql) cmd_sql ;;
  down) cmd_down ;;
  destroy) cmd_destroy ;;
  *) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
