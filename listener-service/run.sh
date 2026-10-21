#!/usr/bin/env bash
# Oracle ORA-12514 lab — driver. Everything runs INSIDE the container via `docker exec`, so you only need Docker.
# Companion to the post on ORA-12514 "listener does not currently know of service requested".
#
#   SETUP    : app service ORDERS_APP in FREEPDB1, created with DBMS_SERVICE and started by hand (not saved).
#   NAME     : connect to FREEPDB instead of FREEPDB1. Asserted: ORA-12514, while FREEPDB1 connects fine.
#              Then what the listener log recorded, and the neighbours: ORA-12154 (bad alias), ORA-12541 (no
#              listener), ORA-12505 (a PDB name given as a SID), and no service name at all (lands in CDB$ROOT,
#              because this image's listener.ora sets DEFAULT_SERVICE_LISTENER; without it, ORA-12504).
#   RESTART  : restart the listener. Asserted: ORA-12514 right after, and it clears on its own once the database
#              re-registers. Then restart it again and run ALTER SYSTEM REGISTER. Asserted: it connects at once.
#              Then lsnrctl reload (prints what it kept; not asserted, it varies) + REGISTER. Asserted: all connect.
#   SERVICE  : close and open the PDB. Asserted: the PDB is READ WRITE and FREEPDB1 connects, but ORDERS_APP
#              gets ORA-12514. Fix: start it and SAVE STATE. Asserted: it survives the next PDB restart.
#   PORT     : a second listener on 1522. Asserted: ORA-12514 there, "supports no services". Fix: LOCAL_LISTENER
#              lists both ports. Asserted: both services connect through 1522.
#
#   ./run.sh up        # start the database (first run pulls the image)
#   ./run.sh setup     # create the ORDERS_APP service (resets the lab; safe to rerun)
#   ./run.sh name      # wrong service name; assert ORA-12514; the neighbouring errors
#   ./run.sh restart   # listener restart; assert the ORA-12514 window and ALTER SYSTEM REGISTER
#   ./run.sh service   # PDB restart drops the app service; assert ORA-12514; SAVE STATE fixes it
#   ./run.sh port      # listener on a port the database doesn't know; LOCAL_LISTENER fixes it
#   ./run.sh all       # setup -> name -> restart -> service -> port
#   ./run.sh sql       # SQL*Plus as SYSDBA
#   ./run.sh down / destroy
set -euo pipefail
cd "$(dirname "$0")"

C=ora-listener-service-lab
export LAB_PORT="${LAB_PORT:-1521}"

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

# try <connect identifier>: connect as SYSTEM and report where we landed, or the error (first line, folded)
try() {
  local out
  out=$(docker exec -i "$C" sqlplus -s -L "system/Lab_Passw0rd1@$1" < scripts/who.sql 2>&1 || true)
  if printf '%s\n' "$out" | grep -q '^SVC='; then
    printf '%s\n' "$out" | grep '^SVC=' | head -1
  else
    printf '%s\n' "$out" | tr '\n' ' ' | grep -o 'ORA-[0-9]*:.*' | sed 's/ *Help:.*//; s/ *(CONNECTION_ID=[^)]*)//; s/  */ /g; s/ *$//' | head -1
  fi
}
# expect_ok retries briefly: registration (LREG) is asynchronous, so a slow runner can need a second or two
expect_ok()  { local r n; for n in 1 2 3 4 5; do r=$(try "$1"); [[ "$r" == SVC=* ]] && break; sleep 1; done
  [ "$n" -gt 1 ] && r="$r (after $n attempts)"; printf '   %-28s -> %s\n' "$1" "$r"; [[ "$r" == SVC=* ]] || die "expected $1 to connect, got: $r"; }
expect_err() { local r; r=$(try "$1"); printf '   %-28s -> %s\n' "${3:-$1}" "$r"; [[ "$r" == "$2"* ]] || die "expected $2 from $1, got: $r"; }

SID_FREEPDB1='(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=localhost)(PORT=1521))(CONNECT_DATA=(SID=FREEPDB1)))'

lsnr() { docker exec "$C" lsnrctl "$@"; }
listener_log() { docker exec "$C" bash -c 'cat /opt/oracle/diag/tnslsnr/*/listener/trace/listener.log'; }

cmd_up() { docker compose up -d; wait_healthy; }

cmd_setup() {
  wait_healthy
  lsnr stop LISTENER2 >/dev/null 2>&1 || true
  echo ">> Creating app service ORDERS_APP in FREEPDB1 (DBMS_SERVICE, started by hand, state not saved)..."
  run_sys < scripts/setup.sql >/dev/null || die "setup.sql failed"
  expect_ok localhost:1521/orders_app
  echo ">> Setup complete."
}

cmd_name() {
  wait_healthy
  echo ">> One letter off: FREEPDB instead of FREEPDB1. Same host, same port, same listener."
  expect_err localhost:1521/FREEPDB ORA-12514
  expect_ok  localhost:1521/FREEPDB1
  echo ">> What the listener offers (lsnrctl services):"
  lsnr services | grep -E '^Service' | sed 's/^/   /'
  echo ">> What the listener log recorded for the failed connect (the service the client ASKED for):"
  # read the log once: grep -q / -m1 on a pipe would SIGPIPE the reader, which pipefail turns into a failure
  local lg; lg=$(listener_log | grep -E '\(SERVICE_NAME=FREEPDB\).* 12514$|^TNS-12514' || true)
  printf '%s\n' "$lg" | grep -E '\(SERVICE_NAME=FREEPDB\).* 12514$' | tail -1 \
    | grep -o '(SERVICE_NAME=FREEPDB)(CID=(PROGRAM=[^)]*)\|establish \* [^ ]* \* 12514' | sed 's/^/   /'
  printf '%s\n' "$lg" | grep '^TNS-12514' | tail -1 | sed 's/^/   /'
  [[ "$lg" == *"(SERVICE_NAME=FREEPDB)"* ]] || die "expected the listener log to record the 12514 for FREEPDB"
  echo ">> The neighbours, for contrast:"
  expect_err FREEPDB ORA-12154
  expect_err localhost:1523/FREEPDB1 ORA-12541
  expect_err "$SID_FREEPDB1" ORA-12505 "(SID=FREEPDB1) descriptor"
  local r; r=$(try localhost:1521)
  printf '   %-28s -> %s\n' "localhost:1521 (no service)" "$r"
  echo "     (this image's listener.ora sets DEFAULT_SERVICE_LISTENER = FREE; a listener without it says ORA-12504)"
  [ "$(sig "$(printf '%s' "$r" | tr ' ' '\n')" CON)" = 'CDB$ROOT' ] || die "expected no service name to land in CDB\$ROOT, got: $r"
  echo "   -> ORA-12514 means the listener answered. It just has no service by that name."
}

cmd_restart() {
  wait_healthy
  echo ">> Restarting the listener (the usual first reaction to ORA-12514):"
  lsnr stop >/dev/null; lsnr start >/dev/null
  lsnr status | grep -E 'supports no services' | sed 's/^/   lsnrctl status: /' || true
  local t0 t1 n=0 r=""
  t0=$(date +%s)
  r=$(try localhost:1521/FREEPDB1)
  printf '   %-28s -> %s\n' localhost:1521/FREEPDB1 "$r"
  if [[ "$r" == SVC=* ]]; then
    # LREG's periodic registration happened to land in the same second as the restart: nothing to wait for
    echo "   (the database re-registered within the second this time; run it again to see the gap)"
  else
    [[ "$r" == ORA-12514* ]] || die "expected ORA-12514 right after the listener restart, got: $r"
  fi
  for i in $(seq 1 120); do
    r=$(try localhost:1521/FREEPDB1)
    [[ "$r" == SVC=* ]] && break
    n=$((n + 1)); sleep 1
  done
  t1=$(date +%s)
  [[ "$r" == SVC=* ]] || die "the database never re-registered on its own"
  echo "   ORA-12514 for every service for ${n} more attempts, ~$((t1 - t0)) s, until the database re-registered by itself."
  echo ">> Restarting it again, then ALTER SYSTEM REGISTER straight away:"
  lsnr stop >/dev/null; lsnr start >/dev/null
  run_sys < scripts/register.sql >/dev/null || die "ALTER SYSTEM REGISTER failed"
  expect_ok localhost:1521/FREEPDB1
  expect_ok localhost:1521/orders_app
  echo "   -> restarting the listener CAUSED the ORA-12514 window; REGISTER closes it in a second."
  echo ">> lsnrctl reload (re-reads listener.ora without a stop/start):"
  lsnr reload >/dev/null
  # not asserted: on this listener a reload sometimes keeps the registrations and sometimes drops them all
  echo "   services the listener knows right after the reload: $(lsnr status | grep -c '^Service' || true)"
  run_sys < scripts/register.sql >/dev/null || die "ALTER SYSTEM REGISTER failed"
  expect_ok localhost:1521/FREEPDB1
  expect_ok localhost:1521/orders_app
  echo "   -> follow ANY listener stop/start or reload with ALTER SYSTEM REGISTER."
}

cmd_service() {
  wait_healthy
  expect_ok localhost:1521/orders_app
  echo ">> Closing and opening FREEPDB1 (a patch, a node restart, a switchover)..."
  run_sys < scripts/pdb_restart.sql >/dev/null || die "PDB restart failed"
  local v; v=$(run_sys < scripts/services.sql)
  printf '   FREEPDB1 is %s; active services: %s\n' "$(sig "$v" PDB_OPEN)" \
    "$(printf '%s\n' "$v" | grep '^ACTIVE=' | cut -d= -f2 | tr '\n' ' ')"
  [ "$(sig "$v" PDB_OPEN)" = "READ_WRITE" ] || die "expected FREEPDB1 READ WRITE"
  printf '%s\n' "$v" | grep -q '^ACTIVE=orders_app' && die "expected orders_app NOT to be running after the PDB restart"
  expect_ok  localhost:1521/FREEPDB1
  expect_err localhost:1521/orders_app ORA-12514
  echo "   -> the database is up and open. The app's service just didn't come back with it."
  echo ">> Fix: start it and SAVE STATE, then restart the PDB again:"
  run_sys < scripts/save_state.sql >/dev/null || die "save_state.sql failed"
  run_sys < scripts/pdb_restart.sql >/dev/null || die "PDB restart failed"
  expect_ok localhost:1521/orders_app
}

cmd_port() {
  wait_healthy
  echo ">> A second listener on port 1522 (a new port, a second listener for an app tier, a DR-side listener):"
  docker exec "$C" bash -c 'grep -q "^LISTENER2" $ORACLE_HOME/network/admin/listener.ora || cat >> $ORACLE_HOME/network/admin/listener.ora <<EOT

LISTENER2 =
  (DESCRIPTION_LIST =
    (DESCRIPTION =
      (ADDRESS = (PROTOCOL = TCP)(HOST = 0.0.0.0)(PORT = 1522))
    )
  )
EOT'
  lsnr stop LISTENER2 >/dev/null 2>&1 || true
  lsnr start LISTENER2 >/dev/null
  local st; st=$(lsnr status LISTENER2)
  printf '%s\n' "$st" | grep -q 'supports no services' || die "expected LISTENER2 to know no services"
  echo "   lsnrctl status LISTENER2: The listener supports no services"
  expect_err localhost:1522/FREEPDB1 ORA-12514
  echo "   -> the database registers only with the listeners LOCAL_LISTENER names (default: port 1521)."
  echo ">> Fix: LOCAL_LISTENER lists both ports:"
  run_sys < scripts/local_listener.sql | grep '^LOCAL_LISTENER=' | sed 's/^/   /'
  expect_ok localhost:1522/FREEPDB1
  expect_ok localhost:1522/orders_app
  expect_ok localhost:1521/FREEPDB1
}

case "${1:-}" in
  up) cmd_up ;;
  setup) cmd_setup ;;
  name) cmd_name ;;
  restart) cmd_restart ;;
  service) cmd_service ;;
  port) cmd_port ;;
  all) cmd_setup; cmd_name; cmd_restart; cmd_service; cmd_port; echo ">> All checks passed." ;;
  sql) docker exec -it "$C" sqlplus / as sysdba ;;
  down) docker compose down ;;
  destroy) docker compose down -v ;;
  *) sed -n '2,25p' "$0"; exit 1 ;;
esac
