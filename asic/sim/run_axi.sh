#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# AXI accelerator IP (rtl_asic/axi): every RTL check in one go.
#
#   1. stream slices alone (sim/tb_axis_skid.v): AxisSkidBuffer and
#      AxisFwdSlice, each without and with clock gating; random valid/ready,
#      full throughput, heavy backpressure, bursts; order, loss, repeats and
#      the AXI-Stream stability rules
#   2. the shell alone (sim/tb_axi_shell.v) against a core model, for thin,
#      reg, reg+cg, lean, lean+cg: register map, IRQ, ERROR, JOB_CYCLES, ID,
#      data through every slice under random backpressure on both sides
#   3. lint of the shell variants (only if verilator is installed)
#   4. the ORIGINAL KV260 testbench on GEMM_top (ASIC) + ASIC core:
#        orig             reference: the KV260 RTL, its result cycles
#        asic WRAP=thin   must give the SAME cycle for every result event
#        asic WRAP=reg / reg+cg / lean / lean+cg: same results, a few cycles later
#        asic-sram WRAP=lean AXIS_CG=1, 3 matrix shapes: the netlist OpenLane
#          builds (OpenRAM models, GEMM_DP_RESET=0) behind the proposed wrapper
#
# usage:  sim/run_axi.sh [path/to/GEMM_32x32_KV260-main]
# output: sim/build_axi/  (logs, cycles_*.txt), PASS/FAIL per line, exit 1 on any FAIL
# ---------------------------------------------------------------------------
set -uo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
REPO=${1:-${REPO:-$KIT/../GEMM_32x32_KV260-main}}
OUT=$KIT/sim/build_axi
mkdir -p "$OUT"
FAILS=0
pass() { printf "  \033[32mPASS\033[0m %s\n" "$*"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$*"; FAILS=$((FAILS+1)); }
A=$KIT/rtl_asic/axi
SLICES=( "$A/AxisSkidBuffer.v" "$A/AxisFwdSlice.v" "$A/AxisClockGate.v" )

# ---- 1. slices
echo "== stream slices"
for v in skid skid_cg skid_cg16 fwd fwd_cg fwd_cg16; do
    d=(); case $v in fwd*) d+=(-DTB_FWD) ;; esac; case $v in *_cg*) d+=(-DTB_CG) ;; esac
    case $v in *_cg16) d+=(-DTB_CG_GROUPS=16) ;; esac
    if iverilog -g2012 "${d[@]}" -o "$OUT/slice_$v.vvp" "$KIT/sim/tb_axis_skid.v" "${SLICES[@]}" \
           > "$OUT/slice_${v}_build.log" 2>&1 \
       && ( cd "$OUT" && vvp -n "slice_$v.vvp" > "slice_$v.log" 2>&1 ) && grep -q "SKID PASS" "$OUT/slice_$v.log"; then
        pass "$v: $(grep -E '^phase 2:' "$OUT/slice_$v.log"); $(grep -E '^sent' "$OUT/slice_$v.log")"
    else
        fail "$v (see sim/build_axi/slice_$v.log, slice_${v}_build.log)"
        grep -E "ERROR|timeout" "$OUT/slice_$v.log" 2>/dev/null | head -5 | sed 's/^/       /'
    fi
done

# ---- 2. shell alone
echo "== GemmAxiShell against a core model"
SHELL_SRC=( "$A/GemmAxiShell.v" "$A/AxiLiteControlRegs.v" "${SLICES[@]}" "$KIT/rtl_asic/ResetSync.v" )
# 2_1_16: lean + clock gating with 16 gates per data bank (GEMM_CG_GROUPS, as gemm_ip_shell)
for v in 0_0 1_0 1_1 2_0 2_1 2_1_16; do
    IFS=_ read -r r c g <<< "$v"; g=${g:-1}
    if iverilog -g2012 -I "$KIT/rtl_asic" -DGEMM_AXIS_REG="$r" -DGEMM_AXIS_CG="$c" -DGEMM_CG_GROUPS="$g" -o "$OUT/shell_$v.vvp" \
           "$KIT/sim/tb_axi_shell.v" "${SHELL_SRC[@]}" > "$OUT/shell_${v}_build.log" 2>&1 \
       && ( cd "$OUT" && vvp -n "shell_$v.vvp" > "shell_$v.log" 2>&1 ) && grep -q "SHELL PASS" "$OUT/shell_$v.log"; then
        pass "GEMM_AXIS_REG=$r CG=$c CG_GROUPS=$g: $(grep -E '^job 1:' "$OUT/shell_$v.log")"
    else
        fail "GEMM_AXIS_REG=$r CG=$c CG_GROUPS=$g (see sim/build_axi/shell_$v.log, shell_${v}_build.log)"
        grep -E "ERROR|timeout" "$OUT/shell_$v.log" 2>/dev/null | head -5 | sed 's/^/       /'
    fi
done

# ---- 3. lint
if command -v verilator >/dev/null; then
    echo "== verilator lint (shell variants)"
    # SYNCASYNCNET: the synchronised reset is async in the slices/flags and sync in the
    # AXI4-Lite template, on purpose (same as the KV260 IP). LATCH: the behavioural ICG
    # model in AxisClockGate (synthesis uses the sky130 dlclkp cell instead).
    Q="-Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY -Wno-WIDTHEXPAND -Wno-SYNCASYNCNET -Wno-LATCH"
    for v in 0_0 1_0 1_1 2_0 2_1 2_1_16; do
        IFS=_ read -r r c g <<< "$v"; g=${g:-1}
        if verilator --lint-only -Wall $Q -I"$KIT/rtl_asic" -DGEMM_AXIS_REG=$r -DGEMM_AXIS_CG=$c -DGEMM_CG_GROUPS=$g --top-module GemmAxiShell \
               "${SHELL_SRC[@]}" > "$OUT/lint_shell_$v.log" 2>&1; then
            pass "GemmAxiShell REG=$r CG=$c CG_GROUPS=$g: lint clean"
        else fail "GemmAxiShell REG=$r CG=$c CG_GROUPS=$g: lint (see sim/build_axi/lint_shell_$v.log)"; fi
    done
else
    echo "== verilator not installed: lint skipped"
fi

# ---- 4. original testbench
echo "== original KV260 testbench"
events() { grep -E "RESULT_VALID_FIRST|RESULT_ACCEPT" "$1" 2>/dev/null; }
run() {   # run <label> <variant> <wrap> <cg> <shape or "">
    local label=$1 v=$2 w=$3 cg=$4 shape=$5
    if WRAP=$w AXIS_CG=$cg TB_SHAPE="$shape" "$KIT/sim/run_system.sh" "$v" "$REPO" > "$OUT/sys_$label.log" 2>&1; then
        pass "$label: OVERALL PASS"
    else
        fail "$label failed the testbench (see sim/build_axi/sys_$label.log)"
    fi
}
build_of() {   # build directory run_system.sh used: build_of <variant> <wrap> <cg> <shape>
    local v=$1 w=$2 cg=$3 shape=$4 tag="" wt=""
    [ -n "$shape" ] && tag=_M$(echo "$shape" | awk -F, '{print $1"K"$2"N"$3}')
    if [ "$w" != fpga ]; then wt=_axi$w; [ "$cg" = 1 ] && wt=${wt}cg; fi
    echo "$KIT/sim/build_system_$v$wt$tag"
}
# compare the result events of two runs: same job/beat/tlast sequence; report cycle shift
compare() {   # compare <label> <ref events> <dut events> <must be identical: 1|0>
    local label=$1 ref=$2 dut=$3 same=$4
    if [ ! -s "$ref" ] || [ ! -s "$dut" ]; then fail "$label: no result events to compare"; return; fi
    if [ "$same" = 1 ]; then
        if diff -q "$ref" "$dut" >/dev/null; then
            pass "$label: same cycle for all $(wc -l < "$dut") result events as the KV260 RTL"
        else fail "$label: result cycles differ from the KV260 RTL (diff $(basename "$ref") $(basename "$dut"))"; fi
        return
    fi
    if diff -q <(sed 's/ cycle=[0-9]*//' "$ref") <(sed 's/ cycle=[0-9]*//' "$dut") >/dev/null; then
        local d
        d=$(paste -d' ' <(sed 's/.*cycle=//' "$ref") <(sed 's/.*cycle=//' "$dut") \
            | awk '{x=$2-$1; if(NR==1||x<lo)lo=x; if(NR==1||x>hi)hi=x} END{print lo".."hi}')
        pass "$label: same $(wc -l < "$dut") result events in the same order, $d cycles later than the KV260 RTL"
    else
        fail "$label: result event sequence differs from the KV260 RTL"
    fi
}

for shape in "" "8,32,544" "16,992,32"; do
    tag=${shape:+_M$(echo "$shape" | awk -F, '{print $1"K"$2"N"$3}')}
    run "orig$tag" orig fpga 0 "$shape"
    events "$(build_of orig fpga 0 "$shape")/system.log" > "$OUT/cycles_orig$tag.txt"
    if [ -z "$shape" ]; then
        for w in thin reg reg_cg lean lean_cg; do
            ww=${w%_cg}; cg=0; [ "$w" != "$ww" ] && cg=1
            run "$w" asic "$ww" "$cg" ""
            events "$(build_of asic "$ww" "$cg" "")/system.log" > "$OUT/cycles_$w.txt"
            same=0; [ "$w" = thin ] && same=1
            compare "$w" "$OUT/cycles_orig.txt" "$OUT/cycles_$w.txt" "$same"
        done
    fi
    run "lean_cg-sram$tag" asic-sram lean 1 "$shape"
    events "$(build_of asic-sram lean 1 "$shape")/system.log" > "$OUT/cycles_lean_cg-sram$tag.txt"
    compare "lean_cg-sram${shape:+ ($shape)}" "$OUT/cycles_orig$tag.txt" "$OUT/cycles_lean_cg-sram$tag.txt" 0
done

echo
if [ "$FAILS" = 0 ]; then echo "AXI IP RTL: ALL PASS"; else echo "AXI IP RTL: $FAILS FAIL"; fi
[ "$FAILS" = 0 ]
