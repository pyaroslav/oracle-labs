#!/usr/bin/env bash
# Oracle password-rollover lab — driver. Everything runs INSIDE the container via `docker exec`, so you only need Docker.
# Companion to the post on ORA-01017 after a password change, and gradual password rollover (PASSWORD_ROLLOVER_TIME).
#
#   SETUP    : APP_USER in FREEPDB1 on profile APP_PROF (5 failed logins lock it), rollover off, logons audited.
#   OUTAGE   : change the password while app servers still use the old one. Asserted: ORA-01017 five times, then
#              ORA-28000, and the NEW password is locked out too. A pooled connection opened before the change
#              is still alive after it (asserted): the outage arrives later, when the pool reconnects.
#   ROLLOVER : PASSWORD_ROLLOVER_TIME 1 day, change the password. Asserted: OPEN & IN ROLLOVER; the old password
#              works more times than the lockout limit; the new one works; the audit trail tells old from new
#              (VERIFIER=...-OLD / -NEW). Asserted: wrong passwords still count and still lock the account.
#              Asserted: windows under 1 hour or over 60 days are rejected (ORA-02377).
#   LATE     : set PASSWORD_ROLLOVER_TIME only after the change. Asserted: OPEN, not in rollover; old gets ORA-01017.
#   TWICE    : change the password a second time inside the window. Asserted: the original and the latest work,
#              the one in the middle gets ORA-01017.
#   FINISH   : ALTER USER ... EXPIRE PASSWORD ROLLOVER PERIOD. Asserted: OPEN, the old password gets ORA-01017,
#              the new one works, and a connection opened with the old password stays alive.
#
#   ./run.sh up        # start the database (first run pulls the image)
#   ./run.sh setup     # create the account, profile and audit policy (resets the lab; safe to rerun)
#   ./run.sh outage    # password change with no rollover; assert ORA-01017 -> ORA-28000
#   ./run.sh rollover  # the same change with a rollover window; old and new both work
#   ./run.sh late      # rollover limit set after the change: too late for that change
#   ./run.sh twice     # a second change during the window drops the middle password
#   ./run.sh finish    # end the window early once every client is on the new password
#   ./run.sh all       # outage -> rollover -> late -> twice -> finish (each starts from setup)
#   ./run.sh sql       # SQL*Plus as SYSDBA
#   ./run.sh down / destroy
set -euo pipefail
cd "$(dirname "$0")"

C=ora-password-rollover-lab
export LAB_PORT="${LAB_PORT:-1521}"

# Spring is the password the app servers have; Summer is the new one; Autumn is a second change
OLD=Spring_Passw0rd1
NEW=Summer_Passw0rd2
THIRD=Autumn_Passw0rd3
TYPO=Sprint_Passw0rd1

die() { echo "!! FAIL: $*" >&2; exit 1; }
run_sys() { docker exec -i "$C" sqlplus -s -L "/ as sysdba"; }
pdb() { printf 'whenever sqlerror exit failure\nalter session set container = FREEPDB1;\n%s\nexit\n' "$1" | run_sys >/dev/null \
  || die "failed: $1"; }
sig() { printf '%s\n' "$1" | grep -E "^$2=" | head -1 | cut -d= -f2-; }

wait_healthy() {
  echo "Waiting for the database to be ready..."
  for i in $(seq 1 90); do
    if docker exec "$C" healthcheck.sh >/dev/null 2>&1; then echo "Database is ready."; return 0; fi
    sleep 5
  done
  die "timed out waiting for the database"
}

# login <password>: one new connection as APP_USER, the way an app server opens one. Prints OK or the error.
login() {
  local out
  out=$(printf "select 'LOGIN_OK' from dual;\nexit\n" \
    | docker exec -i "$C" sqlplus -s -L "app_user/$1@localhost:1521/FREEPDB1" 2>&1 || true)
  if printf '%s\n' "$out" | grep -q LOGIN_OK; then echo OK
  else printf '%s\n' "$out" | tr '\n' ' ' | grep -o 'ORA-[0-9]*:[^;.]*' | head -1; fi
}
expect() {  # expect <label> <password> <OK|ORA-nnnnn>
  local r; r=$(login "$2")
  printf '   %-34s -> %s\n' "$1" "$r"
  [[ "$r" == "$3"* ]] || die "expected $3 for $1, got: $r"
}
status() { run_sys < scripts/status.sql; }
expect_status() {
  local s; s=$(sig "$(status)" STATUS)
  echo "   account_status: $s"
  [ "$s" = "$1" ] || die "expected account status '$1', got '$s'"
}

# held <password>: a pooled connection opened now and used again ~20 s later (background)
held_start() {
  docker exec -d "$C" bash -c "sqlplus -s -L app_user/$1@localhost:1521/FREEPDB1 @/tmp/held.sql > /tmp/held.out 2>&1"
  for i in $(seq 1 20); do docker exec "$C" grep -q HELD_SID /tmp/held.out 2>/dev/null && return 0; sleep 1; done
  die "the held connection did not open"
}
held_check() {
  for i in $(seq 1 40); do docker exec "$C" grep -q 'HELD_STILL_ALIVE\|ORA-' /tmp/held.out 2>/dev/null && break; sleep 1; done
  if docker exec "$C" grep -q HELD_STILL_ALIVE /tmp/held.out; then
    echo "   connection opened before the change: still alive, still querying"
  else
    docker exec "$C" cat /tmp/held.out; die "expected the held connection to survive"
  fi
}

cmd_up() { docker compose up -d; wait_healthy; }

cmd_setup() {
  wait_healthy
  docker exec -i "$C" bash -c 'cat > /tmp/held.sql' < scripts/held.sql
  run_sys < scripts/setup.sql >/dev/null || die "setup.sql failed"
  expect "app server logs in" "$OLD" OK
  expect_status OPEN
}

cmd_outage() {
  echo ">> Setup: APP_USER on APP_PROF (FAILED_LOGIN_ATTEMPTS 5), no rollover."
  cmd_setup
  held_start "$OLD"
  echo ">> Password changed. App servers still have the old one (rolling config push, a pool reconnecting):"
  pdb "alter user app_user identified by \"$NEW\";"
  for i in 1 2 3 4 5; do expect "old password, attempt $i" "$OLD" ORA-01017; done
  expect "old password, attempt 6" "$OLD" ORA-28000
  echo ">> The app server that already has the NEW password:"
  expect "new password" "$NEW" ORA-28000
  expect_status "LOCKED(TIMED)"
  held_check
  echo "   -> the outage shows up when pools reconnect, not when the password changes."
  echo ">> What the audit trail recorded:"
  run_sys < scripts/failures.sql | grep '^FAILED' | sed 's/^/   /'
}

cmd_rollover() {
  echo ">> Same change, with a rollover window: PASSWORD_ROLLOVER_TIME 1 (day)."
  cmd_setup
  sleep 1  # PASSWORD_CHANGE_DATE has 1 s resolution: keep the setup login out of the count below
  pdb "alter profile app_prof limit password_rollover_time 1;"
  pdb "alter user app_user identified by \"$NEW\";"
  expect_status "OPEN & IN ROLLOVER"
  for i in 1 2 3 4 5 6 7; do expect "old password, login $i" "$OLD" OK; done
  expect "new password" "$NEW" OK
  echo "   -> 7 logins on the old password, limit is 5 failures: none of them failed."
  echo ">> Who is still on the old password (unified audit, LOGON_INFO):"
  local v; v=$(run_sys < scripts/verifiers.sql | grep '^VERIFIER=')
  printf '%s\n' "$v" | sed 's/^/   /'
  [[ "$v" == *"-OLD LOGONS=7"* ]] || die "expected 7 audited logons on the OLD verifier"
  [[ "$v" == *"-NEW LOGONS=1"* ]] || die "expected 1 audited logon on the NEW verifier"
  echo ">> Rollover accepts two passwords, not any password. A typo still counts:"
  for i in 1 2 3 4 5; do expect "wrong password, attempt $i" "$TYPO" ORA-01017; done
  expect "new password, after the typos" "$NEW" ORA-28000
  expect "old password, after the typos" "$OLD" ORA-28000
  echo ">> Window limits:"
  local e
  e=$(printf 'alter session set container = FREEPDB1;\nalter profile app_prof limit password_rollover_time 1/48;\nalter profile app_prof limit password_rollover_time 61;\nexit\n' \
    | run_sys | grep -c ORA-02377 || true)
  echo "   30 minutes and 61 days: ORA-02377 x$e (minimum is 1 hour, maximum 60 days)"
  [ "$e" = 2 ] || die "expected both out-of-range windows to be rejected"
}

cmd_late() {
  echo ">> Rollover switched on AFTER the password change (the window starts at the change):"
  cmd_setup
  pdb "alter user app_user identified by \"$NEW\";"
  pdb "alter profile app_prof limit password_rollover_time 1;"
  expect_status OPEN
  expect "old password" "$OLD" ORA-01017
  expect "new password" "$NEW" OK
  echo "   -> set the profile limit first, then change the password."
}

cmd_twice() {
  echo ">> A second change inside the window (a rerun of the rotation job, a second ticket):"
  cmd_setup
  pdb "alter profile app_prof limit password_rollover_time 1;"
  pdb "alter user app_user identified by \"$NEW\";"
  pdb "alter user app_user identified by \"$THIRD\";"
  expect_status "OPEN & IN ROLLOVER"
  expect "original password" "$OLD" OK
  expect "first new password (middle)" "$NEW" ORA-01017
  expect "latest password" "$THIRD" OK
  echo "   -> during a rollover only the original and the latest password are valid."
}

cmd_finish() {
  echo ">> Every client is on the new password: end the window now instead of waiting it out."
  cmd_setup
  pdb "alter profile app_prof limit password_rollover_time 1;"
  pdb "alter user app_user identified by \"$NEW\";"
  held_start "$OLD"
  pdb "alter user app_user expire password rollover period;"
  expect_status OPEN
  expect "old password" "$OLD" ORA-01017
  expect "new password" "$NEW" OK
  held_check
}

case "${1:-}" in
  up) cmd_up ;;
  setup) cmd_setup ;;
  outage) cmd_outage ;;
  rollover) cmd_rollover ;;
  late) cmd_late ;;
  twice) cmd_twice ;;
  finish) cmd_finish ;;
  all) cmd_outage; cmd_rollover; cmd_late; cmd_twice; cmd_finish; echo ">> All checks passed." ;;
  sql) docker exec -it "$C" sqlplus / as sysdba ;;
  down) docker compose down ;;
  destroy) docker compose down -v ;;
  *) sed -n '2,29p' "$0"; exit 1 ;;
esac
