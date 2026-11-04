#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Directed tests for the two errata of IP v1 (README / HUONGDAN "ERRATA"), on the RTL
# exactly as built (run_system.sh asic-sram, WRAP=lean, AXIS_CG=1). RTL is not changed.
#
#   E1  buffer capacity: the word counters of InputBuffer / OutputBuffer are
#       log2(depth) bits wide, so a job of exactly 512 feature words, 1024 weight
#       words or 512 result words wraps the expected count to 0: a full feature or
#       weight buffer hangs the job, a full result buffer gives wrong results.
#       Legal: M*Kb <= 511, 32*Kb*Nb <= 1023 (i.e. Kb*Nb <= 31), M*Nb <= 511.
#   E2  M = 1 (row_count = 1): wrong results and extra result beats.
#
# Every case runs the original two-job testbench (TB_SHAPE) and is graded on the
# data (mismatch / protocol error / timeout lines), not on OVERALL: the
# testbench's busy-status poll misses very short jobs and then prints OVERALL
# FAIL with correct data.
#   PASS  0 mismatch, 0 protocol error, no timeout, no extra beat (both jobs)
#   WRONG wrong values or extra / missing result beats
#   HANG  timeout waiting for result beats
# usage: sim/run_errata.sh [path/to/GEMM_32x32_KV260-main]
# ---------------------------------------------------------------------------
set -uo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
REPO=${1:-${REPO:-$KIT/../GEMM_32x32_KV260-main}}
# name           M,K,N       expected  feature/weight/result words
CASES=(
  "M1            1,32,32     WRONG     1/32/1"
  "M1_K2         1,64,32     WRONG     2/64/1"
  "M2            2,32,32     PASS      2/32/2"
  "M2_K2         2,64,32     PASS      4/64/2"
  "F511          73,224,32   PASS      511/224/73"
  "F512          256,64,32   HANG      512/64/256"
  "W992          2,992,32    PASS      62/992/2"
  "W1024         2,512,64    HANG      32/1024/4"
  "O511          511,32,32   PASS      511/32/511"
  "O512          256,32,64   WRONG     256/64/512"
  "SPLIT128_HALF 64,128,128  PASS      256/512/256"
)
fail=0
printf "%-14s %-11s %-18s %-8s %-8s %s\n" case shape words expected got detail
for c in "${CASES[@]}"; do
    read -r name shape exp words <<< "$c"
    out=$(TB_SHAPE=$shape WRAP=lean AXIS_CG=1 "$KIT/sim/run_system.sh" asic-sram "$REPO" 2>&1)
    IFS=, read -r M K N <<< "$shape"
    log=$KIT/sim/build_system_asic-sram_axileancg_M${M}K${K}N${N}/system.log
    if [ ! -f "$log" ]; then got=ERROR; detail="no log: $(echo "$out" | tail -1)"
    elif grep -q "FAIL timeout" "$log"; then got=HANG; detail=$(grep -m1 -o "feature=[^ ]* weight=[^ ]* result=[^ ]*" "$log")
    elif grep -qE "FAIL job=|FAIL extra|FAIL result TLAST" "$log" || [ "$(grep -c 'Mismatch count = 0' "$log")" != 2 ] \
         || [ "$(grep -c 'Protocol error count = 0' "$log")" != 2 ]; then
        got=WRONG; detail="$(grep -c '^FAIL' "$log") FAIL lines, first: $(grep -m1 '^FAIL' "$log" | cut -c1-70)"
    else got=PASS; detail="$(grep -m1 -o 'OVERALL [A-Z]*' "$log")"; fi
    [ "$got" = "$exp" ] || fail=1
    printf "%-14s %-11s %-18s %-8s %-8s %s\n" "$name" "$shape" "$words" "$exp" "$got" "$detail"
done
[ $fail = 0 ] && echo "ERRATA TESTS: every case behaves as documented" || echo "ERRATA TESTS: a case does NOT behave as documented"
exit $fail
