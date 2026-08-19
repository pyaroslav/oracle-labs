#!/usr/bin/env bash
# Oracle TDE lab — driver. Everything runs INSIDE the container via `docker exec`, so you only need
# Docker. Companion to the post "Oracle Transparent Data Encryption: Prove the Datafile Is Unreadable".
#
# It configures a TDE software keystore, builds one ENCRYPTED tablespace and one ORDINARY one holding
# identical "canary" rows, then reads the raw datafiles off disk:
#
#   PROVE  : the canary string is plainly visible in the UNENCRYPTED datafile (grep finds it) and ABSENT
#            from the ENCRYPTED datafile (grep finds nothing) -- the "stolen .dbf file" threat, defeated.
#   WALLET : close the keystore and the database itself can no longer read the encrypted table
#            (ORA-28365); the plaintext table still reads. Reopen the wallet and access returns.
#
#   ./run.sh up        # start the database (first run pulls the image)
#   ./run.sh setup     # configure TDE (one restart), build the encrypted + plain tablespaces + canary data
#   ./run.sh prove     # read both datafiles off disk: canary visible in plain, absent in encrypted
#   ./run.sh wallet    # close the keystore -> encrypted table unreadable; reopen -> readable again
#   ./run.sh all       # setup -> prove (assert ciphertext) -> wallet (assert close blocks, open restores)
#   ./run.sh sql       # SQL*Plus as SYSDBA inside the container
#   ./run.sh down      # stop & remove the container (keeps the data volume)
#   ./run.sh destroy   # stop & remove the container AND the data volume
set -euo pipefail
cd "$(dirname "$0")"

C=ora-tde-lab
export LAB_PORT="${LAB_PORT:-1521}"
CANARY='CANARY_TDE_7F3A9B2E1D'

die() { echo "!! FAIL: $*" >&2; exit 1; }
run_sys() { docker exec -i "$C" sqlplus -s -L "/ as sysdba"; }
sig() { printf '%s' "$1" | grep -oE "$2=[^[:space:]]+" | head -1 | cut -d= -f2-; }

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
  echo ">> Configuring TDE keystore (one restart) + building encrypted & plain tablespaces with canary rows..."
  docker exec "$C" mkdir -p /opt/oracle/oradata/wallet/tde
  run_sys < scripts/setup.sql >/dev/null 2>&1 || true   # restart makes SQL*Plus noisy; asserts below are the real check
  wait_healthy
  echo ">> Setup complete."
}

# grep a datafile (inside the container) for the canary; prints the match count.
# grep -a treats the binary datafile as text (the container image has no `strings`).
canary_hits() { docker exec "$C" sh -c "grep -a -c '$CANARY' '$1' 2>/dev/null || true" | tr -d '[:space:]'; }

cmd_prove() {
  echo ">> Reading the raw datafiles off disk..."
  local m enc plain fe fp hp he
  m=$(run_sys < scripts/meta.sql)
  enc=$(sig "$m" ENC_TDE_ENC); plain=$(sig "$m" ENC_TDE_PLAIN)
  fe=$(sig "$m" FILE_ENC); fp=$(sig "$m" FILE_PLAIN)
  [ -n "${fe:-}" ] && [ -n "${fp:-}" ] || die "could not read the tablespace datafile paths:"$'\n'"$m"

  echo "   TDE_ENC encrypted=${enc:-?}   TDE_PLAIN encrypted=${plain:-?}"
  [ "${enc:-}" = "YES" ] || die "TDE_ENC is not encrypted (DBA_TABLESPACES.ENCRYPTED=${enc:-null}) -- keystore/setup failed"
  [ "${plain:-}" = "NO" ] || die "TDE_PLAIN unexpectedly reports ENCRYPTED=${plain:-null}"

  hp=$(canary_hits "$fp"); he=$(canary_hits "$fe")
  echo "   canary '$CANARY' in PLAIN  datafile ($fp): $hp hit(s)"
  echo "   canary '$CANARY' in ENC    datafile ($fe): $he hit(s)"
  [ "${hp:-0}" -ge 1 ] || die "canary NOT found in the unencrypted datafile -- setup did not write/flush the data"
  [ "${he:-0}" -eq 0 ] || die "canary FOUND in the ENCRYPTED datafile ($he hits) -- data is NOT encrypted at rest"
  echo "   -> plaintext datafile leaks the data; encrypted datafile is unreadable ciphertext."
}

cmd_wallet() {
  echo ">> Closing the keystore, then reopening it..."
  local w cr cp orr
  w=$(run_sys < scripts/wallet.sql)
  cr=$(sig "$w" CLOSED_READ); cp=$(sig "$w" CLOSED_PLAIN); orr=$(sig "$w" OPEN_READ)
  echo "   wallet CLOSED -> encrypted read: ${cr:-?} | plaintext read: ${cp:-?}"
  echo "   wallet OPEN   -> encrypted read: ${orr:-?}"
  case "${cr:-}" in BLOCKED_*) : ;; *) die "closing the wallet did NOT block reads of the encrypted table (got '${cr:-null}')";; esac
  case "${cp:-}" in READABLE_*) : ;; *) die "closing the wallet wrongly affected the plaintext table (got '${cp:-null}')";; esac
  case "${orr:-}" in READABLE_*) : ;; *) die "reopening the wallet did NOT restore access (got '${orr:-null}')";; esac
  echo "   -> keystore closed = encrypted data unreadable even to the DB; plaintext unaffected; reopen restores it."
}

cmd_all() {
  cmd_setup
  echo
  echo ">> PROVE: the datafile on disk"
  cmd_prove
  echo
  echo ">> WALLET: what the keystore controls"
  cmd_wallet
  echo
  echo ">> PASS: encrypted-at-rest proven on disk (canary absent from the .dbf), and the wallet gates access."
  echo ">> ALL DRILLS COMPLETE"
}

cmd_sql()     { docker exec -it "$C" sqlplus "/ as sysdba"; }
cmd_down()    { docker compose down; }
cmd_destroy() { docker compose down -v; }

case "${1:-}" in
  up) cmd_up ;;
  setup) cmd_setup ;;
  prove) cmd_prove ;;
  wallet) cmd_wallet ;;
  all) cmd_all ;;
  sql) cmd_sql ;;
  down) cmd_down ;;
  destroy) cmd_destroy ;;
  *) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
