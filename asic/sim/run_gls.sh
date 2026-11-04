#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Gate-level simulation of the hardened core: the ORIGINAL testbench, with
# GemmAccelerator replaced by the final netlist OpenLane wrote (after CTS,
# hold buffers, diodes, routing). Catches anything synthesis/flatten/resizer
# changed in the function - something RTL sims cannot see.
#
# usage:  sim/run_gls.sh [path/to/core run dir] [path/to/GEMM_32x32_KV260-main]
#         default run dir: $OL/designs/gemm_core/runs/core_v1
# env:    ROW=rtl (default) | gl   row macro model: its RTL (fast) or its own
#                                  gate netlist from row_v1 (slow, complete)
#         TB_SHAPE="M,K,N"         same as run_system.sh
#         BUILD=dir                build directory (default sim/build_gls)
#         EXTRA_V="a.v b.v"        extra Verilog compiled with the testbench
#                                  (e.g. a module that controls $dumpvars)
#         WRAP=fpga (default) | thin | reg | lean, AXIS_CG=0|1
#                                  AXI wrapper around the core netlist: the KV260
#                                  GEMM_top + axi_ip, or rtl_asic/axi/GEMM_top.v
#                                  with GEMM_AXIS_REG=0 / 1 (see run_system.sh)
#
# Models: sky130_fd_sc_hd functional models (-DFUNCTIONAL -DUNIT_DELAY=#1:
# 1 ns clock-to-Q, zero-delay logic, fine at the 10 ns testbench clock), the
# OpenRAM model (prepared like run_system.sh asic-sram). Physical-only cells
# (fill, decap, tap, diode) are dropped; power ports are tied to 1/0.
# Pass = OVERALL PASS and the same result cycles as the FPGA RTL.
# ---------------------------------------------------------------------------
set -euo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
OL=${OL:-$HOME/OpenLane}
RUN=${1:-$OL/designs/gemm_core/runs/core_v1}
REPO=${2:-${REPO:-$KIT/../GEMM_32x32_KV260-main}}
ROW=${ROW:-rtl}
WRAP=${WRAP:-fpga}
AXIS_CG=${AXIS_CG:-0}
case "$WRAP" in fpga|thin|reg|lean) ;; *) echo "WRAP must be fpga, thin, reg or lean"; exit 2 ;; esac
CGT=""; [ "$AXIS_CG" = 1 ] && CGT=cg
if [ "$WRAP" = fpga ]; then BUILD=${BUILD:-$KIT/sim/build_gls}; else BUILD=${BUILD:-$KIT/sim/build_gls_axi$WRAP$CGT}; fi
mkdir -p "$BUILD"

pdk_dir() {
    local r
    for r in "${PDK_ROOT:-}" "$HOME/.ciel" "$HOME/.volare" "$OL/pdks"; do
        [ -n "$r" ] && [ -d "$r/${PDK:-sky130A}/libs.ref/sky130_fd_sc_hd/verilog" ] && { echo "$r/${PDK:-sky130A}"; return; }
    done
}
P=$(pdk_dir); [ -n "$P" ] || { echo "sky130A not found (set PDK_ROOT)"; exit 1; }
SC=$P/libs.ref/sky130_fd_sc_hd/verilog
NET=""
for f in "$RUN"/results/final/verilog/gl/GemmAccelerator.nl.v "$RUN"/results/final/verilog/gl/GemmAccelerator.v; do
    [ -f "$f" ] && { NET=$f; break; }
done
[ -n "$NET" ] || { echo "no final netlist in $RUN/results/final/verilog/gl"; exit 1; }
echo "netlist: $NET"

# netlist copy: drop physical-only cells, tie the power ports
python3 - "$NET" "$BUILD/core_gl.v" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
phys = r"sky130_\w+__(?:decap|fill|tapvpwrvgnd|diode|fakediode)\w*"
n0 = len(re.findall(r"^\s*" + phys + r"\s", s, re.M))
s = re.sub(r"^\s*" + phys + r"\s+[^\s(]+\s*\(.*?\);\s*$\n?", "", s, flags=re.M | re.S)
# power ports of the top module -> internal supplies
m = re.search(r"module\s+GemmAccelerator\s*\((.*?)\);", s, re.S)
hdr = m.group(1)
for p in ("vccd1", "vssd1", "VPWR", "VGND"):
    hdr = re.sub(r"\s*\b%s\b\s*,?" % p, " ", hdr)
hdr = re.sub(r",\s*$", "", hdr.strip())
s = s[:m.start(1)] + hdr + s[m.end(1):]
s = re.sub(r"\binout\s+vccd1\s*;", "supply1 vccd1;", s)
s = re.sub(r"\binout\s+vssd1\s*;", "supply0 vssd1;", s)
open(sys.argv[2], "w").write(s)
print(f"dropped {n0} physical-only cells")
PY
PWR=(); grep -q "\.VPWR(" "$BUILD/core_gl.v" && PWR=(-DUSE_POWER_PINS)

# SRAM model, same preparation as run_system.sh
SRAM_V=$(find -L "$P/libs.ref/sky130_sram_macros/verilog" -name sky130_sram_2kbyte_1rw1r_32x512_8.v | head -1)
python3 - "$SRAM_V" "$BUILD/sram_model.v" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
s = re.sub(r"parameter\s+VERBOSE\s*=\s*1", "parameter VERBOSE = 0", s)
m = re.search(r"^[ \t]*reg\s*\[DATA_WIDTH-1:0\]\s*mem\s*\[[^\]]*\]\s*;[ \t]*\n", s, re.M)
d = m.group(0); s = s[:m.start()] + s[m.end():]
a = re.search(r"^[ \t]*parameter\s+T_HOLD[^\n]*\n", s, re.M)
s = s[:a.end()] + d + s[a.end():]
s = s.replace("dout1 <= #(DELAY) mem[addr1_reg];",
              "dout1 <= #(DELAY) ((!csb0_reg && !web0_reg && (addr0_reg == addr1_reg)) ? {DATA_WIDTH{1'bx}} : mem[addr1_reg]);")
open(sys.argv[2], "w").write("`timescale 1ns / 1ps\n" + s)
PY

if [ "$ROW" = gl ]; then
    # .nl.v (no power ports): the core netlist instantiates the row without them
    RN=$OL/designs/gemm_row/runs/row_v1/results/final/verilog/gl/ProcessingElementRow.nl.v
    python3 - "$RN" "$BUILD/row_gl.v" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
phys = r"sky130_\w+__(?:decap|fill|tapvpwrvgnd|diode|fakediode)\w*"
s = re.sub(r"^\s*" + phys + r"\s+[^\s(]+\s*\(.*?\);\s*$\n?", "", s, flags=re.M | re.S)
open(sys.argv[2], "w").write(s)
PY
    ROWSRC=( "$BUILD/row_gl.v" )
else
    ROWSRC=( "$KIT/rtl_asic/PE_row.v" "$KIT/rtl_asic/PE.v" )
fi

# testbench copy as in run_system.sh (weight depth 1024, optional shape)
sed -e 's/task automatic run_one_job/task run_one_job/' \
    -e "s/\.P_WEIGHT_BUFFER_DEPTH(P_BUFFER_DEPTH)/.P_WEIGHT_BUFFER_DEPTH(1024)/" \
    "$REPO/tb/tb_GEMM_2_job_64x64.sv" > "$BUILD/tb.sv"
if [ -n "${TB_SHAPE:-}" ]; then
    IFS=, read -r TM TK TN <<< "$TB_SHAPE"
    sed -i -e "s/localparam integer M = 64;/localparam integer M = $TM;/" \
           -e "s/localparam integer K = 64;/localparam integer K = $TK;/" \
           -e "s/localparam integer N = 64;/localparam integer N = $TN;/" "$BUILD/tb.sv"
fi

# GEMM_top copy: the gate netlist of GemmAccelerator has no parameters (fixed at
# synthesis: shift 10, row count 9, depths from gemm_asic_cfg.vh), so the
# #(...) override on its instance is dropped
python3 - "$REPO/rtl/GEMM_top.v" "$BUILD/GEMM_top.v" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
s, n = re.subn(r"\bGemmAccelerator\s*#\s*\((?:[^()]|\([^()]*\))*\)", "GemmAccelerator", s, count=1)
if n != 1:
    sys.exit("run_gls.sh: no GemmAccelerator #(...) instance found in GEMM_top.v")
open(sys.argv[2], "w").write(s)
PY

EF=(); [ -f "$P/libs.ref/sky130_fd_sc_hd/verilog/sky130_ef_sc_hd.v" ] && EF=("$P/libs.ref/sky130_fd_sc_hd/verilog/sky130_ef_sc_hd.v")
echo "compiling (PDK models: $SC)"
case "$WRAP" in
  fpga) WRAPSRC=( "$BUILD/GEMM_top.v" "$REPO"/axi_ip/*.v ); WRAPDEF=() ;;
  thin) WRAPSRC=( "$KIT"/rtl_asic/axi/*.v "$KIT/rtl_asic/ResetSync.v" ); WRAPDEF=( -DGEMM_AXIS_REG=0 -DGEMM_AXIS_CG=0 ) ;;
  reg)  WRAPSRC=( "$KIT"/rtl_asic/axi/*.v "$KIT/rtl_asic/ResetSync.v" ); WRAPDEF=( -DGEMM_AXIS_REG=1 -DGEMM_AXIS_CG="$AXIS_CG" ) ;;
  lean) WRAPSRC=( "$KIT"/rtl_asic/axi/*.v "$KIT/rtl_asic/ResetSync.v" ); WRAPDEF=( -DGEMM_AXIS_REG=2 -DGEMM_AXIS_CG="$AXIS_CG" ) ;;
esac
echo "AXI wrapper: $WRAP"
iverilog -g2012 -DFUNCTIONAL -DUNIT_DELAY=#1 -DGEMM_DP_RESET=0 "${PWR[@]}" "${WRAPDEF[@]}" -I "$KIT/rtl_asic" \
    -o "$BUILD/gls.vvp" \
    "$BUILD/tb.sv" "${WRAPSRC[@]}" \
    "$BUILD/core_gl.v" "${ROWSRC[@]}" "$BUILD/sram_model.v" \
    "$SC/primitives.v" "$SC/sky130_fd_sc_hd.v" "${EF[@]}" ${EXTRA_V:-}
echo "simulating - gate level, this takes a while"
( cd "$BUILD" && vvp -n gls.vvp > gls.log )
grep -E "OVERALL (PASS|FAIL)" "$BUILD/gls.log" || echo "no OVERALL line - see $BUILD/gls.log"
grep -E "RESULT_VALID_FIRST|RESULT_ACCEPT" "$BUILD/gls.log" > "$BUILD/cycles_gls.txt" || true
grep -q "OVERALL PASS" "$BUILD/gls.log"
