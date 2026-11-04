#!/bin/bash
# One antenna ECO round (s4c_round.py) with the fallbacks: +-15 um, +-30 um,
# then remove_fillers. usage: s4c_try.sh <round n> <IN def|odb> [GUIDE]
source "$(dirname "$0")/env.sh"
n=$1; IN=$2; G=${3:-}
mkdir -p "$ECO_DIR/s4c"; cd "$ECO_DIR"
for mode in "WIN=15" "WIN=30" "FULL=1"; do
  tag=$(echo $mode | tr -d '='); log=$ECO_DIR/s4c/r$n.$tag.log
  echo "== round $n $mode $(date +%T)"
  "$ECO_TOOLS/nor.sh" s4c$n "$ECO_TOOLS/s4c_round.py" "$log" IN="$IN" OUT=s4c/r$n GUIDE="$G" MARGIN=10 $mode &
  sleep 5; "$ECO_TOOLS/watch.sh" s4c$n "$log" > /dev/null; wait; rc=$?
  grep -E "^PROBE" "$log" | cut -c1-250
  if grep -qE "repair_antennas FAILED|DPL-0036" "$log"; then echo "-> DPL failed with $mode"; continue; fi
  if [ $rc -ne 0 ] || grep -qE "\[ERROR|Traceback|^Error" "$log"; then echo "-> round $n stopped (rc $rc, error in $log)"; exit 1; fi
  echo "-> round $n done with $mode"; exit 0
done
echo "-> round $n: every fallback failed"; exit 2
