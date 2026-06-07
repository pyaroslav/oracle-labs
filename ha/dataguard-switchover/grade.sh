#!/usr/bin/env bash
# Data Guard switchover/failover forensics lab — interactive self-check.
#   ./grade.sh         # prompts you for the correct action per scenario and scores you
#   ./grade.sh --show  # just print the answer key (one line per scenario)
set -euo pipefail
cd "$(dirname "$0")"

# scenario | accepted-action regex (case-insensitive) | one-line answer
S1=("01 Planned maintenance"        "switchover"                                  "SWITCHOVER (primary healthy, planned). Zero loss, reversible: SWITCHOVER TO 'prod_sby'.")
S2=("02 Primary lost, FSFO off"     "failover"                                    "Manual FAILOVER (primary gone): FAILOVER TO 'prod_sby'. Reinstate old primary later. MaxAvailability+synced -> ~zero loss.")
S3=("03 FSFO already failed over"   "reinstate|already|nothing"                   "FSFO already failed over (prod_sby is primary). Outstanding action: REINSTATE DATABASE 'prod_pri' (or auto).")
S4=("04 How much data lost?"        "transport|14|seconds|async|maxperf"          "~14s lost = the TRANSPORT lag (ASYNC/MaxPerformance, no zero-loss). Apply lag (22s) is staleness, not loss. SYNC would make it zero.")
S5=("05 Switchover refused"         "gap|catch|apply|lag|wait|sync|not ready|fix" "Neither yet — fix the standby first. Apply lag 11m40s: get Redo Apply caught up, THEN retry switchover. Not a failover (primary healthy).")

scenarios=(S1 S2 S3 S4 S5)

if [[ "${1:-}" == "--show" ]]; then
  echo "Answer key (correct action per scenario):"
  for s in "${scenarios[@]}"; do
    declare -n ref="$s"; printf "  %-34s -> %s\n" "${ref[0]}" "${ref[2]}"
  done
  exit 0
fi

echo "Data Guard Switchover/Failover — self-check"
echo "Read each scenarios/NN-*/transcript.txt first. Type the correct ACTION."
echo "(e.g. 'switchover', 'failover', 'reinstate', 'transport lag', 'fix apply / not ready')"
echo "----------------------------------------------------------------------"
score=0
for s in "${scenarios[@]}"; do
  declare -n ref="$s"
  name="${ref[0]}"; regex="${ref[1]}"; answer="${ref[2]}"
  printf "\nScenario %s\n  Your answer: " "$name"
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
echo "Full reasoning (incl. the giveaway line per scenario): see ANSWERS.md"
