#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# core_sim_quick.sh [path/to/GEMM_32x32_KV260-main]
# The checks of `run_flow.sh core-sim` without the stage bookkeeping, so they
# can run from any copy of the kit (e.g. a new kit unpacked next to the one an
# OpenLane run is using): for the testbench shape and two shapes that reach
# the second memory bank, the FPGA RTL (orig) and the ASIC RTL with the real
# OpenRAM models (asic-sram) must both print OVERALL PASS and give every
# result event on the same cycle.
# Needs iverilog/vvp (and the OpenRAM macro .v, found like run_system.sh does).
# ---------------------------------------------------------------------------
set -uo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
REPO=${1:-${REPO:-$KIT/../GEMM_32x32_KV260-main}}
[ -d "$REPO/rtl" ] || { echo "original repo not found at $REPO (give its path)"; exit 2; }
OUT=$KIT/sim/core_sim_quick_$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"
fails=0
for shape in "" "8,32,544" "16,992,32"; do
    tag=${shape:+_M$(echo "$shape" | awk -F, '{print $1"K"$2"N"$3}')}
    for v in orig asic-sram; do
        if TB_SHAPE="$shape" "$KIT/sim/run_system.sh" "$v" "$REPO" > "$OUT/sys_$v$tag.log" 2>&1 \
           && grep -q "OVERALL PASS" "$OUT/sys_$v$tag.log"; then
            echo "PASS $v ${shape:-64,64,64}: OVERALL PASS"
        else
            echo "FAIL $v ${shape:-64,64,64} (see $OUT/sys_$v$tag.log)"; fails=$((fails + 1))
        fi
        grep -E "RESULT_VALID_FIRST|RESULT_ACCEPT" "$KIT/sim/build_system_$v$tag/system.log" \
            > "$OUT/cycles_$v$tag.txt" 2>/dev/null
    done
    if [ -s "$OUT/cycles_orig$tag.txt" ] && diff -q "$OUT/cycles_orig$tag.txt" "$OUT/cycles_asic-sram$tag.txt" >/dev/null; then
        echo "PASS ${shape:-64,64,64}: same cycle for all $(wc -l < "$OUT/cycles_asic-sram$tag.txt") result events as the FPGA RTL"
    else
        echo "FAIL ${shape:-64,64,64}: result cycles differ from the FPGA RTL (diff $OUT/cycles_*$tag.txt)"; fails=$((fails + 1))
    fi
done
echo "logs in $OUT"
[ "$fails" -eq 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL ($fails)"
exit "$fails"
