#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Equivalence sim: original GemmComputeCore vs ASIC GemmComputeCore.
# Runs twice: with datapath reset (GEMM_DP_RESET=1, same as FPGA) and
# without (GEMM_DP_RESET=0, the low-reset-fanout ASIC option). Both must PASS.
# usage:  sim/run_equiv.sh [path/to/original/rtl]
# needs:  iverilog >= 11   (or see the verilator line at the bottom)
# The array size comes from rtl_asic/gemm_asic_cfg.vh (8 is fast, 32 is real).
# ---------------------------------------------------------------------------
set -euo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
ORIG=${1:-$KIT/../GEMM_32x32_KV260-main/rtl}
BUILD=$KIT/sim/build_equiv
mkdir -p "$BUILD"

# make ref_* copies of the original compute path so both versions coexist
for f in PE.v PE_row.v PE_array.v Gemm_compute_core.v; do
  sed -E 's/\b(GemmComputeCore|ProcessingElementArray|ProcessingElementRow|ProcessingElement)\b/ref_\1/g' \
      "$ORIG/$f" > "$BUILD/ref_$f"
done

status=0
for dp in 1 0; do
  echo "=== GEMM_DP_RESET=$dp"
  iverilog -g2012 -Wall -DGEMM_DP_RESET=$dp -I "$KIT/rtl_asic" -o "$BUILD/equiv_dp$dp.vvp" \
    "$KIT/sim/tb_compute_core_equiv.v" \
    "$KIT/sim/mult_IP_model.v" \
    "$BUILD"/ref_*.v \
    "$KIT/rtl_asic/Gemm_compute_core.v" \
    "$KIT/rtl_asic/PE_array.v" \
    "$KIT/rtl_asic/PE_row.v" \
    "$KIT/rtl_asic/PE.v" \
    "$KIT/rtl_asic/FeatureSkew.v" \
    "$KIT/rtl_asic/OutputDeskew.v" \
    "$KIT/rtl_asic/DelayLine.v"
  vvp -n "$BUILD/equiv_dp$dp.vvp" | tee "$BUILD/equiv_dp$dp.log"
  grep -q "EQUIVALENCE PASS" "$BUILD/equiv_dp$dp.log" || status=1
done
exit $status

# Verilator 5 alternative (same file list, add -DGEMM_DP_RESET=0/1):
#   verilator --binary --timing -Wno-fatal -I$KIT/rtl_asic --top-module tb_compute_core_equiv <files...>
