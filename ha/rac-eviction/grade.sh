#!/usr/bin/env bash
# RAC node-eviction forensics lab — interactive self-check.
#   ./grade.sh         # prompts you for each scenario's root cause and scores you
#   ./grade.sh --show  # just print the answer key (one line per scenario)
set -euo pipefail
cd "$(dirname "$0")"

# scenario | accepted-cause regex (case-insensitive) | one-line answer
S1=("01 Interconnect (private network)"      "interconnect|network|nic|mtu|switch|link"          "Network heartbeat: interconnect packet loss / link flap on eth1. misscount (30s); voting disk was fine.")
S2=("02 Voting disk (storage path)"          "voting|disk|storage|san|multipath|path"            "Disk heartbeat: lost all multipath paths to a voting-file LUN; <majority (1 of 3). disktimeout (~200s).")
S3=("03 Resource starvation (CPU/memory)"    "cpu|memory|starv|swap|resource|load|schedul"       "Local heartbeat: a runaway process starved ocssd off the run queue (swap 99%, 0% idle). Looks like network; isn't.")
S4=("04 Time synchronization"                "time|clock|ntp|chrony|drift|step"                  "Time: chrony STEPped the clock ~7s on a running node, corrupting heartbeat accounting (see CRS-2409).")
S5=("05 Hardware / OS (NOT an eviction)"     "hardware|ecc|mce|dimm|machine|memory error|kernel|panic|not.*evict" "Hardware: uncorrectable ECC/MCE reset node2. No decay curve in GI logs — it died, CSS just reconfigured.")

scenarios=(S1 S2 S3 S4 S5)

if [[ "${1:-}" == "--show" ]]; then
  echo "Answer key (root cause per scenario):"
  for s in "${scenarios[@]}"; do
    declare -n ref="$s"; printf "  %-40s -> %s\n" "${ref[0]}" "${ref[2]}"
  done
  exit 0
fi

echo "RAC Node-Eviction Forensics — self-check"
echo "Read each scenarios/NN-*/logs.txt first. Type the ROOT CAUSE in a word or two."
echo "(e.g. 'interconnect', 'voting disk', 'cpu starvation', 'time', 'hardware')"
echo "----------------------------------------------------------------------"
score=0
for s in "${scenarios[@]}"; do
  declare -n ref="$s"
  name="${ref[0]}"; regex="${ref[1]}"; answer="${ref[2]}"
  printf "\nScenario %s\n  Your root cause: " "$name"
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
echo "Full reasoning (including the giveaway log line for each): see ANSWERS.md"
