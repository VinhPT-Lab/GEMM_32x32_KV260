#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Full-system regression with the ORIGINAL testbench (tb_GEMM_2_job_64x64.sv:
# two 64x64x64 jobs, checked against a golden model, prints OVERALL PASS/FAIL
# and the cycle of every result beat).
#
# usage:  sim/run_system.sh asic|asic-sram|orig [path/to/GEMM_32x32_KV260-main]
#   asic      : GEMM_top (repo) + GemmAccelerator and everything below it from
#               rtl_asic/, behavioural memories
#   asic-sram : same, built exactly as OpenLane builds it (GEMM_DP_RESET=0),
#               and every buffer memory is the real sky130
#               OpenRAM macro model (sky130_sram_2kbyte_1rw1r_32x512_8) through
#               sram_1r1w's SRAM_USE_SKY130_OPENRAM branch - i.e. the netlist
#               OpenLane will build. Needs the macro .v from your PDK (found
#               automatically under $PDK_ROOT, ~/.volare, ~/.ciel, $OL/pdks; or set
#               SRAM_V=/path/to/sky130_sram_2kbyte_1rw1r_32x512_8.v)
#   orig      : the original KV260 RTL (+ behavioural mult_IP)
#
# TB_SHAPE="M,K,N" runs another matrix shape (core-sim uses 8,32,544 and
# 16,992,32 so the second bank of the 1024-word memories is exercised).
# Buffer depths: the testbench sets all three to 512; TB_W_DEPTH (default
# 1024, the ASIC choice) is patched into its copy for EVERY variant so the
# runs stay comparable. Running asic/asic-sram against orig and diffing the
# result-cycle lines proves the ASIC RTL keeps the FPGA cycle timing.
#
# The testbench is 32x32: GEMM_N must be 32 in rtl_asic/gemm_asic_cfg.vh.
#
# WRAP picks the AXI wrapper around the core (asic / asic-sram only):
#   fpga (default) : rtl/GEMM_top.v + axi_ip/ of the KV260 repo, as before
#   thin           : rtl_asic/axi/GEMM_top.v, GEMM_AXIS_REG=0 (same logic as
#                    the KV260 wrapper, ASIC copy: same result cycles expected)
#   reg            : rtl_asic/axi/GEMM_top.v, GEMM_AXIS_REG=1 (skid buffer on
#                    every stream: results 1-2 cycles later, same values)
#   lean           : rtl_asic/axi/GEMM_top.v, GEMM_AXIS_REG=2 (forward slices on
#                    the inputs, skid buffer on the result)
# AXIS_CG=1 (with reg / lean): clock-gated slice data banks (GEMM_AXIS_CG=1)
# ---------------------------------------------------------------------------
set -euo pipefail
VARIANT=${1:-asic}
KIT=$(cd "$(dirname "$0")/.." && pwd)
REPO=${2:-${REPO:-$KIT/../GEMM_32x32_KV260-main}}
TB_W_DEPTH=${TB_W_DEPTH:-1024}
WRAP=${WRAP:-fpga}
AXIS_CG=${AXIS_CG:-0}
case "$WRAP" in fpga|thin|reg|lean) ;; *) echo "WRAP must be fpga, thin, reg or lean"; exit 2 ;; esac
[ "$VARIANT" = orig ] && [ "$WRAP" != fpga ] && { echo "WRAP=$WRAP needs the ASIC core (asic or asic-sram)"; exit 2; }
# TB_SHAPE="M,K,N" replaces the testbench's 64,64,64 (golden model follows)
TB_SHAPE=${TB_SHAPE:-}
SHAPE_TAG=""
if [ -n "$TB_SHAPE" ]; then
    IFS=, read -r TM TK TN <<< "$TB_SHAPE"
    SHAPE_TAG="_M${TM}K${TK}N${TN}"
fi
WRAP_TAG=""
[ "$WRAP" != fpga ] && WRAP_TAG="_axi$WRAP"
[ "$WRAP" != fpga ] && [ "$AXIS_CG" = 1 ] && WRAP_TAG="${WRAP_TAG}cg"
BUILD=$KIT/sim/build_system_$VARIANT$WRAP_TAG$SHAPE_TAG
mkdir -p "$BUILD"

# Icarus (vvp) aborts with "of_JOIN_DETACH ... wt_context" on fork/join_none
# inside an AUTOMATIC task. run_one_job is only ever called sequentially, so
# a static copy behaves the same; the original testbench file is untouched.
sed -e 's/task automatic run_one_job/task run_one_job/' \
    -e "s/\.P_WEIGHT_BUFFER_DEPTH(P_BUFFER_DEPTH)/.P_WEIGHT_BUFFER_DEPTH($TB_W_DEPTH)/" \
    "$REPO/tb/tb_GEMM_2_job_64x64.sv" > "$BUILD/tb_icarus.sv"
if [ -n "$TB_SHAPE" ]; then
    sed -i -e "s/localparam integer M = 64;/localparam integer M = $TM;/" \
           -e "s/localparam integer K = 64;/localparam integer K = $TK;/" \
           -e "s/localparam integer N = 64;/localparam integer N = $TN;/" "$BUILD/tb_icarus.sv"
    grep -q "localparam integer N = $TN;" "$BUILD/tb_icarus.sv" || { echo "could not set TB_SHAPE"; exit 1; }
    echo "testbench shape M=$TM K=$TK N=$TN"
fi
grep -q "P_WEIGHT_BUFFER_DEPTH($TB_W_DEPTH)" "$BUILD/tb_icarus.sv" \
    || { echo "could not set the weight buffer depth in the testbench copy"; exit 1; }

ASIC_RTL=( "$KIT"/rtl_asic/*.v )       # includes GEMM_core.v, Signed_adder.v, Right_shifter.v
case "$WRAP" in
  fpga) COMMON=( "$BUILD/tb_icarus.sv" "$REPO/rtl/GEMM_top.v" "$REPO"/axi_ip/*.v ); WRAP_DEFS=() ;;
  thin) COMMON=( "$BUILD/tb_icarus.sv" "$KIT"/rtl_asic/axi/*.v ); WRAP_DEFS=( -DGEMM_AXIS_REG=0 -DGEMM_AXIS_CG=0 ) ;;
  reg)  COMMON=( "$BUILD/tb_icarus.sv" "$KIT"/rtl_asic/axi/*.v ); WRAP_DEFS=( -DGEMM_AXIS_REG=1 -DGEMM_AXIS_CG="$AXIS_CG" ) ;;
  lean) COMMON=( "$BUILD/tb_icarus.sv" "$KIT"/rtl_asic/axi/*.v ); WRAP_DEFS=( -DGEMM_AXIS_REG=2 -DGEMM_AXIS_CG="$AXIS_CG" ) ;;
esac
echo "AXI wrapper: $WRAP${AXIS_CG:+ (AXIS_CG=$AXIS_CG)}"
DEFS=()

find_sram_model() {
    local f
    for f in "${SRAM_V:-}" \
             "${PDK_ROOT:-/nonexistent}"/sky130A/libs.ref/sky130_sram_macros/verilog/sky130_sram_2kbyte_1rw1r_32x512_8.v \
             "$HOME"/.volare/sky130A/libs.ref/sky130_sram_macros/verilog/sky130_sram_2kbyte_1rw1r_32x512_8.v \
             "$HOME"/.ciel/sky130A/libs.ref/sky130_sram_macros/verilog/sky130_sram_2kbyte_1rw1r_32x512_8.v \
             "${OL:-$HOME/OpenLane}"/pdks/sky130A/libs.ref/sky130_sram_macros/verilog/sky130_sram_2kbyte_1rw1r_32x512_8.v; do
        [ -n "$f" ] && [ -f "$f" ] && { echo "$f"; return 0; }
    done
    find -L "$HOME/.volare" "$HOME/.ciel" "${PDK_ROOT:-/nonexistent}" -name sky130_sram_2kbyte_1rw1r_32x512_8.v 2>/dev/null | head -1
}

case "$VARIANT" in
  asic) SRC=( "${COMMON[@]}" "${ASIC_RTL[@]}" ) ;;
  asic-sram)
      M=$(find_sram_model)
      [ -n "$M" ] || { echo "sky130_sram_2kbyte_1rw1r_32x512_8.v not found - set SRAM_V=/path/to/it"; exit 1; }
      echo "SRAM model: $M"
      # quiet model (VERBOSE prints every access), and give it a timescale -
      # without one Icarus would read its #3 as 3 SECONDS
      # The PDK model also declares `mem` AFTER the always blocks that use it;
      # Icarus then reads mem[addr0_reg] as a hierarchical scope and stops
      # ("Scope index expression is not constant"). Move the declaration up.
      python3 - "$M" "$BUILD/sram_model.v" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
src = re.sub(r"parameter\s+VERBOSE\s*=\s*1", "parameter VERBOSE = 0", src)
m = re.search(r"^[ \t]*reg\s*\[DATA_WIDTH-1:0\]\s*mem\s*\[[^\]]*\]\s*;[ \t]*\n", src, re.M)
if not m:
    sys.exit("sram model: could not find the 'mem' declaration")
decl = m.group(0)
src = src[:m.start()] + src[m.end():]
anchor = re.search(r"^[ \t]*parameter\s+T_HOLD[^\n]*\n", src, re.M)
if not anchor:
    sys.exit("sram model: could not find 'parameter T_HOLD'")
src = src[:anchor.end()] + decl + src[anchor.end():]
# Strict collision model: the real macro does not define what port 1 reads
# when port 0 writes the same word in the same cycle, so return X there
# (the stock model just races). If the design ever USES such a value, the X
# reaches the results and the testbench fails. Also name the macro in the
# warning so collisions can be counted per buffer.
rd = "dout1 <= #(DELAY) mem[addr1_reg];"
if rd not in src:
    sys.exit("sram model: read statement not found")
src = src.replace(rd, "dout1 <= #(DELAY) ((!csb0_reg && !web0_reg && (addr0_reg == addr1_reg)) ? "
                      "{DATA_WIDTH{1'bx}} : mem[addr1_reg]);")
src = src.replace('" WARNING: Writing and reading addr0=%b and addr1=%b simultaneously!",addr0,addr1',
                  '" WARNING: Writing and reading %m addr0=%b and addr1=%b simultaneously!",addr0,addr1')
open(sys.argv[2], "w").write("`timescale 1ns / 1ps\n" + src)
PY
      SRC=( "${COMMON[@]}" "${ASIC_RTL[@]}" "$BUILD/sram_model.v" )
      # exactly what OpenLane builds: OpenRAM macros and no datapath reset
      DEFS=( -DSRAM_USE_SKY130_OPENRAM -DGEMM_DP_RESET=0 ) ;;
  orig) SRC=( "${COMMON[@]}" "$REPO/rtl/GEMM_core.v" "$REPO/rtl/Signed_adder.v" "$REPO/rtl/Right_shifter.v"
              "$KIT/sim/mult_IP_model.v"
              "$REPO/rtl/In_buffer.v" "$REPO/rtl/Buffer_feeder.v" "$REPO/rtl/Out_buffer.v"
              "$REPO/rtl/Gemm_compute_core.v" "$REPO/rtl/PE_array.v" "$REPO/rtl/PE_row.v" "$REPO/rtl/PE.v" ) ;;
  *) echo "usage: $0 asic|asic-sram|orig [repo]"; exit 2 ;;
esac

iverilog -g2012 "${DEFS[@]}" "${WRAP_DEFS[@]}" -I "$KIT/rtl_asic" -o "$BUILD/system.vvp" "${SRC[@]}"
( cd "$BUILD" && vvp -n system.vvp > system.log )
grep -E "OVERALL (PASS|FAIL)" "$BUILD/system.log" || echo "no OVERALL line - see $BUILD/system.log"
if [ "$VARIANT" = asic-sram ]; then
    n=$(grep -c "WARNING: Writing and reading" "$BUILD/system.log" || true)
    echo "same-address read+write on one macro in the same cycle: $n (read returns X there)"
    grep "WARNING: Writing and reading" "$BUILD/system.log" \
        | sed -E 's/.*\.(u_[a-z_]+_buffer|u_buffer_feeder)\.(u_[a-z_]+mem)\..*/  \1.\2/' | sort | uniq -c
    echo "  (InputBuffer/BufferFeeder read every cycle while they fill, so some are"
    echo "   expected there; the read value is unused then. OVERALL PASS + identical"
    echo "   result cycles are what prove the macro wiring.)"
fi
grep -q "OVERALL PASS" "$BUILD/system.log"

# If iverilog chokes on SystemVerilog in the testbench, use Verilator 5:
#   verilator --binary --timing -Wno-fatal -I$KIT/rtl_asic \
#     --top-module tb_GEMM_top_axi_two_job_64x64_verify_copy_matrix <same files>
