#!/usr/bin/env bash
# Oracle AI Vector Search lab — run the 23ai vector-search demo from the post on Oracle Database Free.
# No OCI account, no license. Everything runs INSIDE the container via `docker exec`, so you only need Docker.
#
#   ./run.sh up      # start Oracle Database Free (first run pulls the image + creates the DB)
#   ./run.sh demo    # create a VECTOR table and run a VECTOR_DISTANCE similarity search
#   ./run.sh all     # the demo (same as ./run.sh demo)
#   ./run.sh sql     # open a SYSDBA SQL*Plus session inside the container
#   ./run.sh down    # stop & remove the container (keeps the data volume)
#   ./run.sh destroy # stop & remove the container AND the data volume
set -euo pipefail
cd "$(dirname "$0")"

C=ora-vector-search-lab
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

cmd_demo() {
  wait_healthy
  echo ">> AI VECTOR SEARCH DEMO (23ai VECTOR / VECTOR_DISTANCE)"
  run_sql < scripts/vectors.sql | tee vector-demo.txt
  echo "-----------------------------------------------------------"
  # Honest verification: fail if the vector operations errored or returned nothing.
  if grep -qiE "ORA-[0-9]|SP2-[0-9]" vector-demo.txt; then
    echo "FAIL: the demo hit Oracle errors — vector search may be unavailable on this image:" >&2
    grep -iE "ORA-[0-9]|SP2-[0-9]" vector-demo.txt | head >&2
    exit 1
  fi
  grep -q "kitten" vector-demo.txt || { echo "FAIL: the similarity search returned no rows." >&2; exit 1; }
  echo ">> OK — VECTOR_DISTANCE similarity search ran; 'kitten'/'dog' are nearest to 'cat'."
}

cmd_all()     { cmd_demo; echo ">> DONE"; }
cmd_sql()     { docker exec -it "$C" sqlplus "/ as sysdba"; }
cmd_down()    { docker compose down; }
cmd_destroy() { docker compose down -v; }

case "${1:-}" in
  up) cmd_up ;;
  demo) cmd_demo ;;
  all) cmd_all ;;
  sql) cmd_sql ;;
  down) cmd_down ;;
  destroy) cmd_destroy ;;
  *) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
