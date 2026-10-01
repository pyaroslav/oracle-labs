#!/usr/bin/env bash
# Oracle SQL*Net plaintext lab — driver. Everything runs via docker, so you only need Docker. Companion to
# "Your Oracle Traffic Is Readable on the Wire. Here's the Proof, and the Fix."
#
#   SNIFF : the APP user connects over TCP (//localhost:1521/FREEPDB1) and reads a confidential row while a
#           sidecar container that shares the database's network namespace runs tcpdump on port 1521. With the
#           out-of-the-box config, the SQL text AND the secret value are readable in the capture. Asserted.
#   FIX   : make native network encryption + integrity REQUIRED in the server's sqlnet.ora (AES256 / SHA256),
#           then run the SAME query under the SAME capture -> neither the SQL nor the secret is readable, and
#           V$SESSION_CONNECT_INFO shows the session negotiated AES256 + SHA256. Asserted.
#
#   ./run.sh up       # start the database (first run pulls the image)
#   ./run.sh setup    # create the APP user + confidential table; reset sqlnet.ora to the default (plaintext)
#   ./run.sh sniff    # capture a session on the default config; assert the secret is readable on the wire
#   ./run.sh fix      # require encryption + integrity; capture the same session; assert nothing is readable
#   ./run.sh all      # setup -> sniff -> fix
#   ./run.sh sql      # SQL*Plus as SYSDBA
#   ./run.sh down / destroy
set -euo pipefail
cd "$(dirname "$0")"

C=ora-sqlnet-encryption-lab
CAP=ora-sqlnet-encryption-sniffer
SECRET=CANARY-7731-CONFIDENTIAL
export LAB_PORT="${LAB_PORT:-1521}"
mkdir -p captures

die() { echo "!! FAIL: $*" >&2; exit 1; }
run_sys() { docker exec -i "$C" sqlplus -s -L "/ as sysdba"; }
sig() { printf '%s\n' "$1" | grep -E "^$2=" | head -1 | cut -d= -f2- | tr -d '[:space:]'; }

wait_healthy() {
  echo "Waiting for the database to be ready..."
  for i in $(seq 1 90); do
    if docker exec "$C" healthcheck.sh >/dev/null 2>&1; then echo "Database is ready."; return 0; fi
    sleep 5
  done
  die "timed out waiting for the database"
}

# the server's sqlnet.ora (gvenzl image: $ORACLE_HOME/network/admin unless TNS_ADMIN is set)
sqlnet_ora() { docker exec "$C" bash -c 'echo "${TNS_ADMIN:-$ORACLE_HOME/network/admin}/sqlnet.ora"'; }

# drop any encryption / checksum settings -> Oracle's default (ACCEPTED on both sides = no encryption)
reset_sqlnet() {
  local f; f=$(sqlnet_ora)
  docker exec "$C" bash -c "touch '$f' && sed -i '/^SQLNET\.\(ENCRYPTION\|CRYPTO_CHECKSUM\)/d' '$f'"
}

cmd_up() { docker compose up -d; wait_healthy; }

cmd_setup() {
  wait_healthy
  echo ">> Creating the APP user and a table of confidential rows; resetting sqlnet.ora to the default..."
  run_sys < scripts/setup.sql >/dev/null || die "setup.sql failed"
  reset_sqlnet
  echo ">> Setup complete. (server sqlnet.ora: $(sqlnet_ora))"
}

# capture <label>: run probe.sql as APP over TCP while a sidecar tcpdumps port 1521.
# Sets globals OUT (probe signals), FILE (capture text), SQL_SEEN / DATA_SEEN (matches in the capture).
capture() {
  local label=$1
  FILE="captures/${label}.txt"
  docker rm -f "$CAP" >/dev/null 2>&1 || true
  docker pull -q alpine:3.20 >/dev/null
  docker run -d --name "$CAP" --net "container:$C" alpine:3.20 sh -c \
    'apk add -q --no-cache tcpdump >/dev/null && echo CAPTURE_READY && exec tcpdump -i lo -A -s0 -l -U "tcp port 1521" 2>/dev/null' >/dev/null
  for i in $(seq 1 60); do
    docker logs "$CAP" 2>/dev/null | grep -q CAPTURE_READY && break
    sleep 1
  done
  docker logs "$CAP" 2>/dev/null | grep -q CAPTURE_READY || die "the packet-capture sidecar did not start"
  sleep 3   # let tcpdump attach to the interface
  OUT=$(docker exec -i "$C" sqlplus -s -L "app/App_Passw0rd1@//localhost:1521/FREEPDB1" < scripts/probe.sql)
  sleep 2
  docker logs "$CAP" > "$FILE" 2>/dev/null || true
  docker rm -f "$CAP" >/dev/null 2>&1 || true
  SQL_SEEN=$(grep -c "from vault" "$FILE" || true)
  DATA_SEEN=$(grep -c "$SECRET" "$FILE" || true)
  [ "$(sig "$OUT" SECRET)" = "$SECRET" ] || die "the APP session did not read the row over TCP:"$'\n'"$OUT"
  [ "$(wc -l < "$FILE")" -gt 20 ]         || die "the capture is empty -- tcpdump saw no traffic on port 1521"
}

cmd_sniff() {
  echo ">> Default config: APP reads a confidential row over TCP while tcpdump listens on port 1521..."
  capture plaintext
  echo "   session encryption: $(sig "$OUT" ENC)   integrity: $(sig "$OUT" CKSUM)"
  echo "   capture: SQL text seen ${SQL_SEEN}x, secret '${SECRET}' seen ${DATA_SEEN}x  (${FILE})"
  grep -m1 -o "select[^.]*from vault[^.]*" "$FILE" | sed 's/^/     wire> /' || true
  grep -m1 -o "$SECRET" "$FILE" | sed 's/^/     wire> /' || true
  [ "$(sig "$OUT" ENC)" = "NONE" ] || die "expected an unencrypted session on the default config"
  [ "${DATA_SEEN:-0}" -ge 1 ]      || die "expected the secret to be readable in the capture, it was not"
  [ "${SQL_SEEN:-0}" -ge 1 ]       || die "expected the SQL text to be readable in the capture, it was not"
  echo "   -> anyone who can see these packets can read the query and the result."
}

cmd_fix() {
  echo ">> Requiring native network encryption + integrity on the server (AES256 / SHA256)..."
  local f; f=$(sqlnet_ora)
  reset_sqlnet
  docker exec "$C" bash -c "cat >> '$f' <<'ORA'
SQLNET.ENCRYPTION_SERVER = REQUIRED
SQLNET.ENCRYPTION_TYPES_SERVER = (AES256)
SQLNET.CRYPTO_CHECKSUM_SERVER = REQUIRED
SQLNET.CRYPTO_CHECKSUM_TYPES_SERVER = (SHA256)
ORA"
  docker exec "$C" grep -E '^SQLNET\.(ENCRYPTION|CRYPTO_CHECKSUM)' "$f" | sed 's/^/     sqlnet.ora> /'
  echo ">> Same session, same query, same capture..."
  capture encrypted
  echo "   session encryption: $(sig "$OUT" ENC)   integrity: $(sig "$OUT" CKSUM)"
  echo "   capture: SQL text seen ${SQL_SEEN}x, secret '${SECRET}' seen ${DATA_SEEN}x  (${FILE})"
  [ "$(sig "$OUT" ENC)" = "AES256" ] || die "expected the session to negotiate AES256, got '$(sig "$OUT" ENC)'"
  [ "$(sig "$OUT" CKSUM)" = "SHA256" ] || die "expected the session to negotiate SHA256, got '$(sig "$OUT" CKSUM)'"
  [ "${DATA_SEEN:-1}" -eq 0 ] || die "the secret is STILL readable in the capture after the fix"
  [ "${SQL_SEEN:-1}" -eq 0 ]  || die "the SQL text is STILL readable in the capture after the fix"
  echo "   -> the same query and result crossed the wire, and none of it is readable."
}

cmd_all() {
  cmd_setup; echo
  cmd_sniff; echo
  cmd_fix; echo
  echo ">> PASS: on the default config the SQL and the confidential result were readable in a packet capture;"
  echo ">>       with encryption + integrity REQUIRED on the server, the same session negotiated AES256/SHA256"
  echo ">>       and nothing was readable."
  echo ">> ALL DRILLS COMPLETE"
}

cmd_sql()     { docker exec -it "$C" sqlplus "/ as sysdba"; }
cmd_down()    { docker rm -f "$CAP" >/dev/null 2>&1 || true; docker compose down; }
cmd_destroy() { docker rm -f "$CAP" >/dev/null 2>&1 || true; docker compose down -v; }

case "${1:-}" in
  up) cmd_up ;;
  setup) cmd_setup ;;
  sniff) cmd_sniff ;;
  fix) cmd_fix ;;
  all) cmd_all ;;
  sql) cmd_sql ;;
  down) cmd_down ;;
  destroy) cmd_destroy ;;
  *) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
