#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Lint + synthesis sanity check. Run this BEFORE OpenROAD: anything Verilator
# or Yosys complains about here comes back later as a much more confusing
# problem in the flow.
#
# STRICT (fails the checkpoint): the modules that were written/changed for
#   the ASIC build, with -Wall minus width-extension noise.
# INFO (printed only): whole GEMM_top, including untouched original code,
#   and a full width report. Read it once and make sure you understand it.
#
# usage:  sim/lint.sh [path/to/GEMM_32x32_KV260-main]
# ---------------------------------------------------------------------------
set -uo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
REPO=${1:-${REPO:-$KIT/../GEMM_32x32_KV260-main}}
R=$KIT/rtl_asic
QUIET="-Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY"

strict () {   # $1 = top module, rest = files
  local top=$1; shift
  echo "=== [strict] verilator: $top"
  verilator --lint-only -Wall $QUIET -Wno-WIDTHEXPAND -I"$R" --top-module "$top" "$@" \
    || echo "!!! lint issues in $top"
}
info () {
  local top=$1; shift
  echo "=== [info] verilator: $top"
  verilator --lint-only -Wall $QUIET -Wno-fatal -I"$R" --top-module "$top" "$@" 2>&1 | head -80
}

ARR="$R/PE_array.v $R/PE_row.v $R/PE.v $R/FeatureSkew.v $R/OutputDeskew.v $R/DelayLine.v"
strict ProcessingElement      $R/PE.v
strict ProcessingElementRow   $R/PE_row.v $R/PE.v
strict ProcessingElementArray $ARR
strict DelayLine              $R/DelayLine.v
strict sram_1r1w              $R/sram_1r1w.v
strict ResetSync              $R/ResetSync.v

info   GemmComputeCore        $R/Gemm_compute_core.v $ARR
info   GemmAccelerator        $R/*.v
info   GEMM_top               $REPO/rtl/GEMM_top.v $REPO/axi_ip/*.v $R/*.v

echo "=== yosys generic synth: ProcessingElement (cells + flops)"
yosys -q -p "read_verilog -I$R $R/PE.v; synth -top ProcessingElement -flatten; stat" | tail -40

echo "=== yosys: memories left in GemmAccelerator (expect only sram_1r1w instances)"
yosys -q -p "read_verilog -I$R $R/*.v; \
             hierarchy -top GemmAccelerator; proc; memory -nomap; select -list t:\$mem*" 2>&1 | head -40
