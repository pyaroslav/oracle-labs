#!/usr/bin/env bash
# Oracle patching-inspection lab — driver. READ-ONLY: it inspects your patch state; it does NOT
# download or apply any Oracle patch (real Release Updates come from My Oracle Support under a support
# contract). Everything runs INSIDE the container via `docker exec`, so you only need Docker.
#
#   ./run.sh up         # start Oracle Database Free (first run pulls the image + creates the DB)
#   ./run.sh level      # your release/RU level + the SQL-patch registry (DBA_REGISTRY_SQLPATCH)
#   ./run.sh inventory  # the binary patch inventory: opatch lspatches
#   ./run.sh verify     # datapatch -verify: the SQL side, read-only ("what WOULD apply")
#   ./run.sh all        # level + inventory + verify
#   ./run.sh sql        # open a SYSDBA SQL*Plus session inside the container
#   ./run.sh down       # stop & remove the container (keeps the data volume)
#   ./run.sh destroy    # stop & remove the container AND the data volume
set -euo pipefail
cd "$(dirname "$0")"

C=ora-patching-lab
export LAB_PORT="${LAB_PORT:-1521}"
run_sql() { docker exec -i "$C" sqlplus -s -L "/ as sysdba"; }

wait_healthy() {
  echo "Waiting for the database to be ready..."
  for i in $(seq 1 90); do
    if docker exec "$C" healthcheck.sh >/dev/null 2>&1; then echo "Database is ready."; return 0; fi
    sleep 5
  done
  echo "Timed out waiting for the database." >&2; exit 1
}

cmd_up() { docker compose up -d; wait_healthy; }

cmd_level() {
  wait_healthy
  echo ">> PATCH LEVEL + SQL-PATCH REGISTRY (read-only)"
  run_sql < scripts/level.sql
}

cmd_inventory() {
  wait_healthy
  echo ">> BINARY PATCH INVENTORY  --  opatch lspatches"
  echo "   OPatch maintains the binary side (the patches applied to the Oracle home)."
  docker exec "$C" bash -lc '$ORACLE_HOME/OPatch/opatch lspatches' 2>&1 \
    || echo "   (opatch/inventory not readable on this image — the SQL-side views above are the point)"
}

cmd_verify() {
  wait_healthy
  echo ">> DATAPATCH -VERIFY  (read-only: reports pending SQL actions, applies nothing)"
  echo "   datapatch is the SQL half of a patch. In -verify mode it changes nothing;"
  echo "   on a base image it should report there is nothing to apply (binaries and SQL in sync)."
  docker exec "$C" bash -lc '$ORACLE_HOME/OPatch/datapatch -verify' 2>&1 \
    || echo "   (datapatch not runnable in this mode on this image — see README)"
}

cmd_all()     { cmd_level; echo; cmd_inventory; echo; cmd_verify; echo; echo ">> DONE — you read patch state without applying anything."; }
cmd_sql()     { docker exec -it "$C" sqlplus "/ as sysdba"; }
cmd_down()    { docker compose down; }
cmd_destroy() { docker compose down -v; }

case "${1:-}" in
  up) cmd_up ;;
  level) cmd_level ;;
  inventory) cmd_inventory ;;
  verify) cmd_verify ;;
  all) cmd_all ;;
  sql) cmd_sql ;;
  down) cmd_down ;;
  destroy) cmd_destroy ;;
  *) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
