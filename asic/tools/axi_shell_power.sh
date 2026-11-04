#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Power of a gemm_axi_shell run (OpenSTA in the OpenLane image), tt/25C/1.80V, 100 MHz.
#
#   tools/axi_shell_power.sh <shell run dir>                  OpenSTA default activity
#                                                             (same method as tools/power.sh)
#   tools/axi_shell_power.sh <shell run dir> --vcd C0 C1      activity from a simulation of
#       the original testbench (64x64x64, two jobs) on GEMM_top with the shell's FINAL GATE
#       NETLIST and the core's RTL; nets of the shell dumped for testbench cycles [C0, C1).
#       C1 = end: up to the end of the testbench. 2300 3200 = the window of the core's
#       VCD number (compute phase of job 2), so the two can be added.
# Output: <run>/reports/power/{vectorless,vcd_C0_C1}.design.rpt (+ .log)
# Needs iverilog and the sky130 cell models (PDK_ROOT / ~/.ciel / ~/.volare) for --vcd.
# ---------------------------------------------------------------------------
set -euo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
OL=${OL:-$HOME/OpenLane}
REPO=${REPO:-$KIT/../GEMM_32x32_KV260-main}
IMG=${OL_IMAGE:-ghcr.io/the-openroad-project/openlane:ff5509f65b17bfa4068d5336495ab1718987ff69-amd64}
# RAM limit as openlane/run_flow.sh (DOCKER_MEMORY / DOCKER_SWAP, empty = none)
MEM=()
[ -n "${DOCKER_MEMORY-10g}" ] && MEM+=(--memory="${DOCKER_MEMORY-10g}")
[ -n "${DOCKER_SWAP-40g}" ] && MEM+=(--memory-swap="${DOCKER_SWAP-40g}")
PDK_ROOT=${PDK_ROOT:-$HOME/.ciel}
RUN=""; C0=""; C1=""
while [ $# -gt 0 ]; do
    case "$1" in
        --vcd) C0=${2:?}; C1=${3:?}; shift 3 ;;
        *) RUN=$1; shift ;;
    esac
done
RUN=$(cd "${RUN:?give a gemm_axi_shell run dir}" && pwd)
NL=$RUN/results/final/verilog/gl/GemmAxiShell.nl.v
[ -f "$NL" ] || { echo "no final netlist in $RUN"; exit 1; }
OUT=$RUN/reports/power; mkdir -p "$OUT"

sta_power() {   # sta_power <name> [activity file]
    local env=(-e SHELL_FINAL="$RUN/results/final" -e OUT="$OUT/$1" -e PDK_ROOT="$PDK_ROOT")
    [ -n "${2:-}" ] && env+=(-e ACT="$2")
    docker run --rm "${MEM[@]}" -u "$(id -u):$(id -g)" -v "$HOME:$HOME" -v "$PDK_ROOT:$PDK_ROOT" -v "$KIT:$KIT" -v "$OL:$OL" \
        "${env[@]}" "$IMG" sta -no_splash -exit "$KIT/tools/power/shell_power.tcl" 2>&1 | tee "$OUT/$1.log"
    grep -E "^Total" "$OUT/$1.design.rpt" || { echo "no Total line in $OUT/$1.design.rpt"; exit 1; }
}

if [ -z "$C0" ]; then
    sta_power vectorless
    exit 0
fi

# ---- simulation with the shell gate netlist
name=vcd_${C0}_$C1
B=$KIT/sim/build_shell_power/$(basename "$RUN")_$name; mkdir -p "$B"
P=""
for r in "${PDK_ROOT:-}" "$HOME/.ciel" "$HOME/.volare" "$OL/pdks"; do
    [ -n "$r" ] && [ -d "$r/sky130A/libs.ref/sky130_fd_sc_hd/verilog" ] && { P=$r/sky130A; break; }
done
[ -n "$P" ] || { echo "sky130A cell models not found (set PDK_ROOT)"; exit 1; }
SC=$P/libs.ref/sky130_fd_sc_hd/verilog

# netlist copy without physical-only cells (fill, decap, tap, diodes)
python3 - "$NL" "$B/shell_gl.v" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
phys = r"sky130_\w+__(?:decap|fill|tapvpwrvgnd|diode|fakediode)\w*"
s = re.sub(r"^\s*" + phys + r"\s+[^\s(]+\s*\(.*?\);\s*$\n?", "", s, flags=re.M | re.S)
open(sys.argv[2], "w").write(s)
PY
# GEMM_top copy: the gate netlist has no parameters, drop the #(...) on the shell instance
python3 - "$KIT/rtl_asic/axi/GEMM_top.v" "$B/GEMM_top.v" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
s, n = re.subn(r"\bGemmAxiShell\s*#\s*\((?:[^()]|\([^()]*\))*\)", "GemmAxiShell", s, count=1)
if n != 1:
    sys.exit("axi_shell_power.sh: no GemmAxiShell #(...) instance in GEMM_top.v")
open(sys.argv[2], "w").write(s)
PY
# testbench copy as in run_system.sh, with the IP's 6-bit AXI4-Lite address
# (the shell netlist has 6 address pins; the KV260 testbench drives 4 bits,
# and its register offsets 0x0..0xC zero-extend)
sed -e 's/task automatic run_one_job/task run_one_job/' \
    -e "s/\.P_WEIGHT_BUFFER_DEPTH(P_BUFFER_DEPTH)/.P_WEIGHT_BUFFER_DEPTH(1024)/" \
    -e "s/localparam integer P_AXI_LITE_ADDR_WIDTH = 4;/localparam integer P_AXI_LITE_ADDR_WIDTH = 6;/" \
    "$REPO/tb/tb_GEMM_2_job_64x64.sv" > "$B/tb.sv"
grep -q "P_AXI_LITE_ADDR_WIDTH = 6;" "$B/tb.sv" || { echo "could not set the address width in the testbench copy"; exit 1; }
TB=tb_GEMM_top_axi_two_job_64x64_verify_copy_matrix
STOP="wait ($TB.cycle == $C1); @(negedge $TB.clk); \$display(\"VCD_END cycle=%0d\", $TB.cycle); \$dumpflush; \$finish;"
[ "$C1" = end ] && STOP="// until the testbench finishes"
cat > "$B/vcd_window.v" <<V
\`timescale 1ns / 1ps
module vcd_window;
    initial begin
        \$dumpfile("$B/$name.vcd");
        wait ($TB.cycle == $C0);
        @(negedge $TB.clk);
        \$dumpvars(1, $TB.dut.u_axi_shell);
        \$display("VCD_START cycle=%0d", $TB.cycle);
        $STOP
    end
endmodule
V
EF=(); [ -f "$SC/sky130_ef_sc_hd.v" ] && EF=("$SC/sky130_ef_sc_hd.v")
echo "simulating: testbench + GEMM_top (RTL) + shell gate netlist + core RTL, dumping cycles $C0..$C1"
iverilog -g2012 -DFUNCTIONAL -DUNIT_DELAY=#1 -I "$KIT/rtl_asic" -o "$B/sim.vvp" \
    "$B/tb.sv" "$B/GEMM_top.v" "$B/shell_gl.v" "$B/vcd_window.v" \
    $(ls "$KIT"/rtl_asic/*.v) "$SC/primitives.v" "$SC/sky130_fd_sc_hd.v" "${EF[@]}"
( cd "$B" && vvp -n sim.vvp > sim.log )
if [ "$C1" = end ]; then
    grep -E "OVERALL (PASS|FAIL)" "$B/sim.log" || { echo "no OVERALL line - see $B/sim.log"; exit 1; }
    grep -q "OVERALL PASS" "$B/sim.log" || { echo "testbench failed with the shell netlist - see $B/sim.log"; exit 1; }
else
    # stopped at cycle C1, before the testbench prints OVERALL (as tools/power.sh does for the
    # core); the full check of the netlist is the "0 end" run. Here: window reached, no FAIL so far.
    grep -q "^VCD_END" "$B/sim.log" || { echo "simulation did not reach cycle $C1 - see $B/sim.log"; exit 1; }
    if grep -q "^FAIL" "$B/sim.log"; then echo "testbench reported FAIL before cycle $C1 - see $B/sim.log"; exit 1; fi
    echo "window $C0..$C1 simulated, no FAIL from the testbench up to there"
fi
python3 "$KIT/tools/power/vcd2act_flat.py" "$B/$name.vcd" "$B/shell_gl.v" u_axi_shell "$OUT/$name.act"
sta_power "$name" "$OUT/$name.act"
rm -f "$B/$name.vcd"
