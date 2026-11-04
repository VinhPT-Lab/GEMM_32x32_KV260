#!/bin/bash
# Antenna ECO round after the DRV / hold ECO (s4c_round.py on a DEF + guide), same
# fallbacks as s4c_try.sh. usage: [OUTD=dir] s6c_ant.sh <n> <IN def> <GUIDE>
# (OUTD: output directory under $ECO_DIR, default s6c)
source "$(dirname "$0")/env.sh"
n=$1; IN=$2; G=$3
D=${OUTD:-s6c}; mkdir -p "$ECO_DIR/$D"; cd "$ECO_DIR"
for mode in "WIN=15" "WIN=30" "FULL=1"; do
  tag=$(echo $mode | tr -d '='); log=$ECO_DIR/$D/a$n.$tag.log
  echo "== antenna round $n $mode $(date +%T)"
  "$ECO_TOOLS/nor.sh" s6ca$n "$ECO_TOOLS/s4c_round.py" "$log" IN="$IN" OUT=$D/a$n GUIDE="$G" MARGIN=10 $mode &
  sleep 5; "$ECO_TOOLS/watch.sh" s6ca$n "$log" > /dev/null; wait; rc=$?
  grep -E "^PROBE" "$log" | cut -c1-250
  if grep -qE "repair_antennas FAILED|DPL-0036" "$log"; then echo "-> DPL failed with $mode"; continue; fi
  if [ $rc -ne 0 ] || grep -qE "\[ERROR|Traceback|^Error" "$log"; then echo "-> antenna round $n stopped (rc $rc, error in $log)"; exit 1; fi
  echo "-> antenna round $n done with $mode"; exit 0
done
echo "-> antenna round $n: every fallback failed"; exit 2
