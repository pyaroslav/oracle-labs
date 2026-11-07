#!/usr/bin/env bash
# Oracle idle-connection-drop lab — driver. Everything runs via docker, so you only need Docker.
# Companion to the post on ORA-03113 / ORA-03135 after a connection sits idle behind a firewall or load balancer.
#
# The "firewall": the database's network namespace forgets an idle TCP flow after 90 s (conntrack), and a sidecar
# adds an iptables rule for packets of a forgotten flow: DROP them (a silent firewall, Azure Load Balancer's default)
# or answer with a TCP reset (AWS NLB, or Azure LB with "TCP reset on idle"). Every client is its own container
# on the lab network: it runs a query, sits idle for 110 s, then runs a second one.
#
#   RESET : reset mode. Asserted: the second query fails at once with ORA-03135, and the database still has the
#           session (INACTIVE) afterwards: the reset went to the client only.
#   DROP  : drop mode. Asserted: the second query gets no answer. With the client's TCP retries cut to 5 it ends
#           in ORA-03113 (with the Linux default of 15 that takes about 15 minutes); with SQLNET.RECV_TIMEOUT=30
#           in the client's sqlnet.ora it ends in ORA-12609. The database still has both sessions.
#   FIX   : SQLNET.EXPIRE_TIME = 1 in the SERVER's sqlnet.ora (keepalive after 60 s idle, under the 90 s timeout).
#           Asserted: the same 110 s idle, drop mode, and the second query works.
#   TOOLATE : SQLNET.EXPIRE_TIME = 2 (120 s, over the 90 s timeout). Asserted: the second query fails anyway.
#   CLIENT : the client side. (ENABLE=BROKEN) in the connect descriptor alone: the second query still fails (the
#           OS default keepalive time is 2 hours). (ENABLE=BROKEN) plus net.ipv4.tcp_keepalive_time=60 on the client
#           host: it works. SQLNET.EXPIRE_TIME = 1 in the CLIENT's sqlnet.ora (this is a 26ai client): it works.
#   DEAD  : the client host disappears (its network is cut, nothing is closed). Asserted: without EXPIRE_TIME the
#           session is still there 4 minutes later; with SQLNET.EXPIRE_TIME = 1 the database removes it.
#
#   ./run.sh up        # start the database (first run pulls the image)
#   ./run.sh setup     # reset the lab: no EXPIRE_TIME, firewall in drop mode, leftover APP sessions killed
#   ./run.sh reset     # the firewall sends a reset: ORA-03135
#   ./run.sh drop      # the firewall drops silently: a hang, then ORA-03113 (or ORA-12609 with RECV_TIMEOUT)
#   ./run.sh fix       # SQLNET.EXPIRE_TIME below the firewall timeout: the session survives
#   ./run.sh toolate   # SQLNET.EXPIRE_TIME above the firewall timeout: it doesn't
#   ./run.sh client    # ENABLE=BROKEN alone vs ENABLE=BROKEN + OS keepalive time
#   ./run.sh dead      # a vanished client: kept forever without EXPIRE_TIME, cleaned up with it
#   ./run.sh all       # reset -> drop -> fix -> toolate -> client -> dead (each starts from setup), about 16 minutes
#   ./run.sh sql       # SQL*Plus as SYSDBA
#   ./run.sh down / destroy
set -euo pipefail
cd "$(dirname "$0")"

C=ora-idle-connection-drop-lab
FW=ora-idle-connection-drop-fw
NET=ora-idle-connection-drop-net
IMG=gvenzl/oracle-free:latest
FW_TIMEOUT=90   # must match nf_conntrack_tcp_timeout_established in docker-compose.yml
IDLE=110        # how long each client sits idle: longer than the firewall timeout
export LAB_PORT="${LAB_PORT:-1521}"
EZ="//oracle:1521/FREEPDB1"
BROKEN="(DESCRIPTION=(ENABLE=BROKEN)(ADDRESS=(PROTOCOL=TCP)(HOST=oracle)(PORT=1521))(CONNECT_DATA=(SERVICE_NAME=FREEPDB1)))"

die() { echo "!! FAIL: $*" >&2; exit 1; }
run_sys() { docker exec -i "$C" sqlplus -s -L "/ as sysdba"; }
pdb_val() {  # pdb_val "<select returning one value>"
  printf 'set heading off feedback off pagesize 0\nalter session set container = FREEPDB1;\n%s\nexit\n' "$1" \
    | run_sys | grep -v 'Session altered' | tr -d '[:space:]'
}

wait_healthy() {
  echo "Waiting for the database to be ready..."
  for i in $(seq 1 90); do
    if docker exec "$C" healthcheck.sh >/dev/null 2>&1; then echo "Database is ready."; return 0; fi
    sleep 5
  done
  die "timed out waiting for the database"
}

sqlnet_ora() { docker exec "$C" bash -c 'echo "${TNS_ADMIN:-$ORACLE_HOME/network/admin}/sqlnet.ora"'; }
set_expire() {  # set_expire <minutes|none>: new server processes read sqlnet.ora when they start
  local f; f=$(sqlnet_ora)
  docker exec "$C" bash -c "touch '$f' && sed -i '/^SQLNET\.EXPIRE_TIME/d' '$f'"
  [ "$1" = none ] || docker exec "$C" bash -c "echo 'SQLNET.EXPIRE_TIME = $1' >> '$f'"
}

firewall() {  # firewall <drop|reset>: the rules live in the database's namespace, so replace them, don't add
  local action=DROP; [ "$1" = reset ] && action="REJECT --reject-with tcp-reset"
  docker rm -f "$FW" >/dev/null 2>&1 || true
  docker run -d --name "$FW" --net "container:$C" --cap-add NET_ADMIN alpine:3.20 sh -c \
    "apk add -q --no-cache iptables >/dev/null && iptables -F INPUT && iptables -A INPUT -p tcp --dport 1521 -m conntrack --ctstate INVALID -j $action && echo FW_READY && exec sleep infinity" >/dev/null
  for i in $(seq 1 60); do docker logs "$FW" 2>/dev/null | grep -q FW_READY && break; sleep 1; done
  docker logs "$FW" 2>/dev/null | grep -q FW_READY || die "the firewall sidecar did not start"
  local t; t=$(docker exec "$C" cat /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established)
  [ "$t" = "$FW_TIMEOUT" ] || die "the firewall idle timeout is $t s, expected $FW_TIMEOUT s"
}

# client <name> <connect> [docker run options...]: query, sit idle $IDLE s, query again. Runs in the background;
# collect it with `result <name>`. Prints SID=, then the second query's output, then AFTER_IDLE=<seconds it took>.
# SECOND_OK is built by the query, so a failed query (which SQL*Plus echoes) can't match it.
client() {
  local name=$1 conn=$2; shift 2
  docker rm -f "ora-idle-client-$name" >/dev/null 2>&1 || true
  docker run -d --name "ora-idle-client-$name" --network "$NET" "$@" --entrypoint bash "$IMG" -c "
    { echo 'set heading off feedback off pagesize 0';
      echo \"select 'SID='||sys_context('userenv','sid') from dual;\";
      sleep $IDLE; date +%s > /tmp/t0;
      echo \"select 'SECOND'||'_OK' from dual;\"; echo exit; } | sqlplus -s -L 'app/App_Passw0rd1@$conn'
    echo AFTER_IDLE=\$(( \$(date +%s) - \$(cat /tmp/t0) ))" >/dev/null
}
result() {  # result <name> [max seconds]: wait for the client to finish, print its output, remove it
  local name="ora-idle-client-$1" max=${2:-600}
  for i in $(seq 1 "$max"); do
    [ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" = false ] && break
    sleep 1
  done
  docker logs "$name" 2>&1
  docker rm -f "$name" >/dev/null 2>&1 || true
}
field() { printf '%s\n' "$1" | grep -E "^$2=" | head -1 | cut -d= -f2- | tr -d '[:space:]'; }
err() { printf '%s\n' "$1" | grep -oE 'ORA-[0-9]{5}' | head -1; }
alive() { pdb_val "select count(*) from v\$session where username = 'APP' and sid = $1;"; }

cmd_up() { docker compose up -d; wait_healthy; }
clean_side() {  # the firewall sidecar and any client a failed drill left behind (they hold the lab network)
  docker rm -f "$FW" $(docker ps -aq --filter name=ora-idle-client-) >/dev/null 2>&1 || true
  docker volume rm ora-idle-tns ora-idle-ctns >/dev/null 2>&1 || true
}

cmd_setup() {
  wait_healthy
  set_expire none
  firewall drop
  # leftover sessions from earlier drills (the point of the lab is that the database keeps them)
  printf 'alter session set container = FREEPDB1;\nbegin for s in (select sid, serial# from v$session where username = %s) loop execute immediate %s; end loop; end;\n/\nexit\n' \
    "'APP'" "'alter system kill session '''||s.sid||','||s.serial#||''' immediate'" | run_sys >/dev/null
}

cmd_reset() {
  echo ">> RESET: the firewall answers a forgotten flow with a TCP reset (AWS NLB; Azure LB with TCP reset on)."
  cmd_setup; firewall reset
  client reset "$EZ"
  echo "   a client runs a query, then sits idle ${IDLE}s (firewall timeout ${FW_TIMEOUT}s)..."
  local out sid; out=$(result reset)
  sid=$(field "$out" SID)
  echo "   second query after $(field "$out" AFTER_IDLE)s: $(err "$out")"
  [ "$(err "$out")" = ORA-03135 ] || die "expected ORA-03135, got: $out"
  [ "$(field "$out" AFTER_IDLE)" -le 5 ] || die "expected the error at once"
  echo "   on the database, session $sid: $( [ "$(alive "$sid")" = 1 ] && echo 'still there' || echo gone )"
  [ "$(alive "$sid")" = 1 ] || die "expected the database to still have session $sid"
  echo "   -> the client got the reset, the database didn't: it keeps an INACTIVE session nobody owns."
}

cmd_drop() {
  echo ">> DROP: the firewall silently drops a forgotten flow (Azure Load Balancer's default)."
  cmd_setup
  client retries "$EZ" --sysctl net.ipv4.tcp_retries2=5
  docker run --rm -v ora-idle-tns:/tns alpine:3.20 sh -c 'echo "SQLNET.RECV_TIMEOUT = 30" > /tns/sqlnet.ora'
  client recv "$EZ" -v ora-idle-tns:/tns -e TNS_ADMIN=/tns
  echo "   two clients run a query, then sit idle ${IDLE}s (firewall timeout ${FW_TIMEOUT}s)..."
  local a b
  a=$(result retries); b=$(result recv)
  docker volume rm ora-idle-tns >/dev/null 2>&1 || true
  echo "   client with tcp_retries2=5 (Linux default 15): second query after $(field "$a" AFTER_IDLE)s: $(err "$a")"
  [ "$(err "$a")" = ORA-03113 ] || die "expected ORA-03113, got: $a"
  echo "   client with SQLNET.RECV_TIMEOUT=30: second query after $(field "$b" AFTER_IDLE)s: $(err "$b")"
  [ "$(err "$b")" = ORA-12609 ] || die "expected ORA-12609, got: $b"
  local n=0 s; for s in "$(field "$a" SID)" "$(field "$b" SID)"; do n=$(( n + $(alive "$s") )); done
  echo "   on the database: $n of 2 sessions still there"
  [ "$n" = 2 ] || die "expected the database to still have both sessions"
  echo "   -> no reset, so the client waits for TCP to give up; how long depends on the client host, not Oracle."
}

cmd_fix() {
  echo ">> FIX: SQLNET.EXPIRE_TIME = 1 on the server (keepalive after 60s idle, under the ${FW_TIMEOUT}s timeout)."
  cmd_setup; set_expire 1
  client fix "$EZ" --sysctl net.ipv4.tcp_retries2=5
  echo "   a client runs a query, then sits idle ${IDLE}s..."
  local out; out=$(result fix)
  echo "   second query after $(field "$out" AFTER_IDLE)s: $(printf '%s\n' "$out" | grep -qx SECOND_OK && echo OK || err "$out")"
  printf '%s\n' "$out" | grep -qx SECOND_OK || die "expected the second query to work, got: $out"
  echo "   -> the keepalive refreshed the firewall's idle timer; nothing about the app changed."
}

cmd_toolate() {
  echo ">> TOOLATE: SQLNET.EXPIRE_TIME = 2 (120s), over the ${FW_TIMEOUT}s timeout."
  cmd_setup; set_expire 2
  client toolate "$EZ" --sysctl net.ipv4.tcp_retries2=5
  echo "   a client runs a query, then sits idle ${IDLE}s..."
  local out; out=$(result toolate)
  echo "   second query after $(field "$out" AFTER_IDLE)s: $(err "$out")"
  printf '%s\n' "$out" | grep -qx SECOND_OK && die "expected the second query to fail"
  [ -n "$(err "$out")" ] || die "expected an ORA- error, got: $out"
  echo "   -> EXPIRE_TIME is in minutes and has to be BELOW the idle timeout; the first keepalive came too late."
}

cmd_client() {
  echo ">> CLIENT: (ENABLE=BROKEN) in the connect descriptor turns on TCP keepalive at the client."
  cmd_setup
  client broken "$BROKEN" --sysctl net.ipv4.tcp_retries2=5 --sysctl net.ipv4.tcp_keepalive_time=7200  # the Linux default
  client keepalive "$BROKEN" --sysctl net.ipv4.tcp_retries2=5 --sysctl net.ipv4.tcp_keepalive_time=60
  docker run --rm -v ora-idle-ctns:/tns alpine:3.20 sh -c 'echo "SQLNET.EXPIRE_TIME = 1" > /tns/sqlnet.ora'
  client cexpire "$EZ" --sysctl net.ipv4.tcp_retries2=5 -v ora-idle-ctns:/tns -e TNS_ADMIN=/tns
  echo "   three clients run a query, then sit idle ${IDLE}s..."
  local a b c; a=$(result broken); b=$(result keepalive); c=$(result cexpire)
  docker volume rm ora-idle-ctns >/dev/null 2>&1 || true
  echo "   ENABLE=BROKEN, OS keepalive time 7200s (default): $(printf '%s\n' "$a" | grep -qx SECOND_OK && echo OK || err "$a")"
  printf '%s\n' "$a" | grep -qx SECOND_OK && die "expected ENABLE=BROKEN alone to fail"
  echo "   ENABLE=BROKEN, OS keepalive time 60s:             $(printf '%s\n' "$b" | grep -qx SECOND_OK && echo OK || err "$b")"
  printf '%s\n' "$b" | grep -qx SECOND_OK || die "expected ENABLE=BROKEN + a 60s keepalive time to work, got: $b"
  echo "   SQLNET.EXPIRE_TIME = 1 in the CLIENT's sqlnet.ora (26ai client): $(printf '%s\n' "$c" | grep -qx SECOND_OK && echo OK || err "$c")"
  printf '%s\n' "$c" | grep -qx SECOND_OK || die "expected client-side EXPIRE_TIME to work, got: $c"
  echo "   -> ENABLE=BROKEN only switches keepalive on; the OS decides when the first one is sent."
  echo "      A 26ai client can also set the interval itself, with SQLNET.EXPIRE_TIME in its own sqlnet.ora."
}

cmd_dead() {
  echo ">> DEAD: the client host disappears (network cut, nothing closed)."
  cmd_setup
  client nokeep "$EZ"
  sleep 10; set_expire 1
  client keep "$EZ"
  sleep 10
  local a b; a=$(docker logs "ora-idle-client-nokeep" 2>&1); b=$(docker logs "ora-idle-client-keep" 2>&1)
  a=$(field "$a" SID); b=$(field "$b" SID)
  [ -n "$a" ] && [ -n "$b" ] || die "the clients did not connect"
  docker network disconnect "$NET" ora-idle-client-nokeep
  docker network disconnect "$NET" ora-idle-client-keep
  local t0 gone=""; t0=$(date +%s)
  while [ $(( $(date +%s) - t0 )) -lt 240 ]; do
    [ -z "$gone" ] && [ "$(alive "$b")" = 0 ] && gone=$(( $(date +%s) - t0 ))
    sleep 5
  done
  docker rm -f ora-idle-client-nokeep ora-idle-client-keep >/dev/null 2>&1 || true
  echo "   session $b (EXPIRE_TIME = 1): $( [ -n "$gone" ] && echo "removed after about ${gone}s" || echo 'still there' )"
  [ -n "$gone" ] || die "expected the database to remove session $b"
  echo "   session $a (no EXPIRE_TIME): $( [ "$(alive "$a")" = 1 ] && echo 'still there after 240s' || echo gone )"
  [ "$(alive "$a")" = 1 ] || die "expected the database to keep session $a"
  echo "   -> without EXPIRE_TIME nothing ever asks; the session (and any locks it holds) stays."
}

case "${1:-}" in
  up) cmd_up ;;
  setup) cmd_setup ;;
  reset) cmd_reset ;;
  drop) cmd_drop ;;
  fix) cmd_fix ;;
  toolate) cmd_toolate ;;
  client) cmd_client ;;
  dead) cmd_dead ;;
  all) cmd_reset; cmd_drop; cmd_fix; cmd_toolate; cmd_client; cmd_dead; cmd_setup; echo ">> All checks passed." ;;
  sql) docker exec -it "$C" sqlplus / as sysdba ;;
  down) clean_side; docker compose down ;;
  destroy) clean_side; docker compose down -v ;;
  *) sed -n '2,36p' "$0"; exit 1 ;;
esac
