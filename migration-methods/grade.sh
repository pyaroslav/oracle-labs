#!/usr/bin/env bash
# Oracle cloud-migration method-selection lab — interactive self-check.
#   ./grade.sh         # prompts you for the best method per scenario and scores you
#   ./grade.sh --show  # just print the answer key (one line per scenario)
set -euo pipefail
cd "$(dirname "$0")"

# scenario | accepted-method regex (case-insensitive) | one-line answer
S1=("01 Lift-and-shift to OCI"            "data.?guard|standby|physical online|switchover|zdm physical" \
    "Data Guard physical online (ZDM physical): same endian + same version + EE -> build a standby in OCI, switch over. Near-zero downtime + switch-back rollback.")
S2=("02 Off big-endian Solaris"           "xtts|transportable|cross.?platform|rman convert" \
    "Cross-platform Transportable Tablespaces / XTTS with RMAN CONVERT: cross-endian rules out physical restore & Data Guard; 12 TB is too big for Data Pump in a weekend; XTTS copies datafiles + rolls forward with incrementals, CONVERT flips endianness.")
S3=("03 Into Autonomous Database"         "data.?pump|expdp|impdp|logical" \
    "Data Pump (logical), dump files staged in Object Storage. ADB has no SYSDBA/file access, so physical is impossible; converge the charset to AL32UTF8 and run CPAT first. Use GoldenGate instead if near-zero downtime is mandatory.")
S4=("04 Oracle Database@Azure"            "data.?guard|standby|physical|switchover|zdm physical" \
    "Data Guard physical (ZDM): Database@Azure IS Exadata Database Service = the full toolbox, so a physical standby from on-prem into Azure + switchover works. The colleague is wrong -- it is NOT Data-Pump-only.")
S5=("05 Cross-endian, near-zero, fallback" "goldengate|golden.?gate|logical online|^gg$|ogg" \
    "GoldenGate (ZDM logical online): the only method that is near-zero downtime AND crosses endian + version (AIX 11g -> Linux 26ai), with bidirectional replication for a clean fallback after cutover.")
S6=("06 Standard Edition source"          "data.?pump|expdp|impdp|rman|offline|backup|restore" \
    "NOT Data Guard -- it is Enterprise Edition only. On SE2 use Data Pump (logical) or an offline RMAN backup/restore (ZDM physical offline). The lesson: EE-only near-zero methods (Data Guard, ZDM physical online) are off the table on Standard Edition.")

scenarios=(S1 S2 S3 S4 S5 S6)

if [[ "${1:-}" == "--show" ]]; then
  echo "Answer key (best method per scenario):"
  for s in "${scenarios[@]}"; do
    declare -n ref="$s"; printf "  %-38s -> %s\n" "${ref[0]}" "${ref[2]}"
  done
  exit 0
fi

echo "Oracle Cloud-Migration — method selection self-check"
echo "Read each scenarios/NN-*.md first, then type the BEST migration method."
echo "(e.g. 'data guard', 'goldengate', 'data pump', 'xtts / transportable')"
echo "----------------------------------------------------------------------"
score=0
for s in "${scenarios[@]}"; do
  declare -n ref="$s"
  name="${ref[0]}"; regex="${ref[1]}"; answer="${ref[2]}"
  printf "\nScenario %s\n  Best method: " "$name"
  read -r reply || reply=""
  if printf '%s' "$reply" | grep -qiE "$regex"; then
    printf "  \033[32m✓ correct\033[0m — %s\n" "$answer"
    score=$((score + 1))
  else
    printf "  \033[31m✗ not quite\033[0m — %s\n" "$answer"
  fi
done
echo "----------------------------------------------------------------------"
printf "Score: %d / %d\n" "$score" "${#scenarios[@]}"
echo "Full reasoning (incl. the giveaway constraint per scenario): see ANSWERS.md"
