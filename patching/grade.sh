#!/usr/bin/env bash
# Oracle patching forensics lab — interactive self-check.
#   ./grade.sh         # prompts you for the diagnosis/action per scenario and scores you
#   ./grade.sh --show  # just print the answer key (one line per scenario)
set -euo pipefail
cd "$(dirname "$0")"

# scenario | accepted-answer regex (case-insensitive) | one-line answer
S1=("01 Version says patched, registry disagrees" \
    "datapatch" \
    "Run datapatch. OPatch put RU 19.27 in the home (version_full shows 19.27.0.0.0), but DBA_REGISTRY_SQLPATCH has no 19.27 row — the SQL half never ran. The database is half-patched and unsupported until datapatch loads the SQL and writes the SUCCESS row.")
S2=("02 'Apply the latest RUR to stay conservative'" \
    "discontinued|deprecated|no.?longer|dead|gone|there is no rur|use.*ru|latest ru|mrp|monthly recommended|does.?n.?t exist" \
    "RUR is discontinued (after January 2023) — there is nothing to apply. Stay on the latest Release Update; for fresher fixes between quarters use a Monthly Recommended Patch (MRP), which replaced RUR. The 3rd version digit that carried the RUR level is now always 0.")
S3=("03 Both stages consistent, but the year is 2026" \
    "behind|out.?of.?date|stale|old|latest ru|apply.*ru|update|upgrade|not current|too old|no\\b" \
    "Fully applied is not current. 19.18 is the January 2023 RU — a dozen-plus quarters behind — and it carries every CVE fixed since. The registry being consistent only means both stages of THAT RU ran; schedule the latest RU.")
S4=("04 opatch, version, and registry all agree" \
    "none|nothing|healthy|fully patched|consistent|no action|in sync|do nothing|it.?s fine|good" \
    "Nothing to do. opatch lspatches shows RU 19.27, version_full is 19.27.0.0.0, and DBA_REGISTRY_SQLPATCH has the 19.27 APPLY row with SUCCESS — binaries and SQL registry agree, both stages clean. This is what 'done' looks like. (Whether 19.27 is also the *latest* RU is scenario 03's question.)")
S5=("05 RAC: the two nodes disagree" \
    "rolling|node ?2|second node|finish|incomplete|mismatch|mixed|complete the patch|patch.*node|catch.*up" \
    "A rolling patch was left half-finished: node1's home is on 19.27, node2's is still 19.26. Finish patching node2's home so all nodes match, THEN run datapatch once (from any node). Running mixed-version homes is a temporary rolling state, not a resting state.")
S6=("06 datapatch ran — but read the STATUS" \
    "error|re.?run|rerun|failed|rollback|investigate|not.*complete|fix|redo|not\\b|no\\b" \
    "Not correctly patched. DBA_REGISTRY_SQLPATCH shows the 19.27 APPLY with status WITH ERRORS — the SQL side failed partway. Read the datapatch log, resolve the cause, and re-run datapatch until the row reads SUCCESS. 'OPatch succeeded' is not 'the patch is done.'")

scenarios=(S1 S2 S3 S4 S5 S6)

if [[ "${1:-}" == "--show" ]]; then
  echo "Answer key (diagnosis / action per scenario):"
  for s in "${scenarios[@]}"; do
    declare -n ref="$s"; printf "  %-46s -> %s\n" "${ref[0]}" "${ref[2]}"
  done
  exit 0
fi

echo "Oracle Patching — forensics self-check"
echo "Read each scenarios/NN-*.md first, then type the diagnosis or the action."
echo "(e.g. 'run datapatch', 'RUR is discontinued', 'apply the latest RU',"
echo " 'nothing — it's healthy', 'finish the rolling patch', 'datapatch errored — re-run it')"
echo "----------------------------------------------------------------------"
score=0
for s in "${scenarios[@]}"; do
  declare -n ref="$s"
  name="${ref[0]}"; regex="${ref[1]}"; answer="${ref[2]}"
  printf "\nScenario %s\n  Your call: " "$name"
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
echo "Full reasoning (and the signal that gives each one away): see ANSWERS.md"
