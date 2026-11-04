#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Gate-level simulation of the complete IP: the ORIGINAL testbench on the final
# netlist of a gemm_ip run (GEMM_top: the flat core + the hard macros), every
# macro also gate-level:
#   - the 32 rows: the final netlist of the row run (row_v1),
#   - the AXI macro u_axi_shell: the final netlist of the ip-shell run,
#   - the 80 SRAMs: the OpenRAM model, prepared as in run_gls.sh.
# The testbench copy gets the IP's 6-bit AXI4-Lite address (register offsets
# 0x0..0xC zero-extend, as in tools/axi_shell_power.sh) and loses the #(...)
# on GEMM_top (a gate netlist has no parameters).
#
# usage:  sim/run_ip_gls.sh <gemm_ip run dir> [path/to/GEMM_32x32_KV260-main]
# env:    SHELL_RUN=<gemm_ip_shell run dir>  [openlane/state/ip_shell_run.txt]
#         ROW_RUN=<row run dir>              [$OL/designs/gemm_row/runs/row_v1]
#         TB_SHAPE="M,K,N", BUILD=dir        as run_gls.sh
# Pass = OVERALL PASS; result events written to $BUILD/cycles_gls.txt.
# ---------------------------------------------------------------------------
set -euo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
OL=${OL:-$HOME/OpenLane}
RUN=${1:?give a gemm_ip run dir}
REPO=${2:-${REPO:-$KIT/../GEMM_32x32_KV260-main}}
SHELL_RUN=${SHELL_RUN:-$(cat "$KIT/openlane/state/ip_shell_run.txt" 2>/dev/null || true)}
ROW_RUN=${ROW_RUN:-$OL/designs/gemm_row/runs/row_v1}
BUILD=${BUILD:-$KIT/sim/build_ip_gls}
mkdir -p "$BUILD"

P=""
for r in "${PDK_ROOT:-}" "$HOME/.ciel" "$HOME/.volare" "$OL/pdks"; do
    [ -n "$r" ] && [ -d "$r/${PDK:-sky130A}/libs.ref/sky130_fd_sc_hd/verilog" ] && { P=$r/${PDK:-sky130A}; break; }
done
[ -n "$P" ] || { echo "sky130A not found (set PDK_ROOT)"; exit 1; }
SC=$P/libs.ref/sky130_fd_sc_hd/verilog
NET=$RUN/results/final/verilog/gl/GEMM_top.nl.v
SNET=$SHELL_RUN/results/final/verilog/gl/GemmAxiShell.nl.v
RNET=$ROW_RUN/results/final/verilog/gl/ProcessingElementRow.nl.v
for f in "$NET" "$SNET" "$RNET"; do [ -f "$f" ] || { echo "missing $f"; exit 1; }; done
echo "IP netlist   : $NET"
echo "AXI macro    : $SNET"
echo "row macro    : $RNET"

# netlist copies without physical-only cells (fill, decap, tap, diode)
python3 - "$NET" "$BUILD/ip_gl.v" "$SNET" "$BUILD/shell_gl.v" "$RNET" "$BUILD/row_gl.v" <<'PY'
import re, sys
phys = r"sky130_\w+__(?:decap|fill|tapvpwrvgnd|diode|fakediode)\w*"
for src, dst in zip(sys.argv[1::2], sys.argv[2::2]):
    s = open(src).read()
    n0 = len(re.findall(r"^\s*" + phys + r"\s", s, re.M))
    s = re.sub(r"^\s*" + phys + r"\s+[^\s(]+\s*\(.*?\);\s*$\n?", "", s, flags=re.M | re.S)
    open(dst, "w").write(s)
    print(f"{dst.split('/')[-1]}: dropped {n0} physical-only cells")
PY

# SRAM model, same preparation as run_gls.sh / run_system.sh
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

# testbench copy: as run_gls.sh, plus the 6-bit address and no #(...) on the DUT
sed -e 's/task automatic run_one_job/task run_one_job/' \
    -e "s/localparam integer P_AXI_LITE_ADDR_WIDTH = 4;/localparam integer P_AXI_LITE_ADDR_WIDTH = 6;/" \
    "$REPO/tb/tb_GEMM_2_job_64x64.sv" > "$BUILD/tb.sv"
grep -q "P_AXI_LITE_ADDR_WIDTH = 6;" "$BUILD/tb.sv" || { echo "could not set the address width in the testbench copy"; exit 1; }
python3 - "$BUILD/tb.sv" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
s, n = re.subn(r"\bGEMM_top\s*#\s*\((?:[^()]|\([^()]*\))*\)\s*dut", "GEMM_top dut", s, count=1)
if n != 1:
    sys.exit("run_ip_gls.sh: no GEMM_top #(...) dut instance in the testbench")
open(p, "w").write(s)
PY
if [ -n "${TB_SHAPE:-}" ]; then
    IFS=, read -r TM TK TN <<< "$TB_SHAPE"
    sed -i -e "s/localparam integer M = 64;/localparam integer M = $TM;/" \
           -e "s/localparam integer K = 64;/localparam integer K = $TK;/" \
           -e "s/localparam integer N = 64;/localparam integer N = $TN;/" "$BUILD/tb.sv"
fi

PWR=(); grep -q "\.VPWR(" "$BUILD/ip_gl.v" && PWR=(-DUSE_POWER_PINS)
EF=(); [ -f "$SC/sky130_ef_sc_hd.v" ] && EF=("$SC/sky130_ef_sc_hd.v")
echo "compiling (PDK models: $SC)"
iverilog -g2012 -DFUNCTIONAL -DUNIT_DELAY=#1 "${PWR[@]}" -o "$BUILD/gls.vvp" \
    "$BUILD/tb.sv" "$BUILD/ip_gl.v" "$BUILD/shell_gl.v" "$BUILD/row_gl.v" "$BUILD/sram_model.v" \
    "$SC/primitives.v" "$SC/sky130_fd_sc_hd.v" "${EF[@]}" ${EXTRA_V:-}
echo "simulating - gate level, this takes a while"
( cd "$BUILD" && vvp -n gls.vvp > gls.log )
grep -E "OVERALL (PASS|FAIL)" "$BUILD/gls.log" || echo "no OVERALL line - see $BUILD/gls.log"
grep -E "RESULT_VALID_FIRST|RESULT_ACCEPT" "$BUILD/gls.log" > "$BUILD/cycles_gls.txt" || true
grep -q "OVERALL PASS" "$BUILD/gls.log"
