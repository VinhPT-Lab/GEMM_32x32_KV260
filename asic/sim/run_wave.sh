#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# RTL ASIC + testbench gốc 2 job 64x64x64, có dump VCD, rồi đối chiếu kết quả
# với golden model Python của repo FPGA (golden_model/compare_gemm_txt.py).
# Dùng để tạo lại các hình trong docs/evidence.
#
# usage:  sim/run_wave.sh [path/to/GEMM_32x32_KV260]
# output: sim/build_wave/ (wave.vcd, system.log, result_matrix.txt, golden_compare.txt)
# cần:    iverilog >= 11, python3; gtkwave nếu muốn xem dạng sóng
# ---------------------------------------------------------------------------
set -euo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
REPO=${1:-${REPO:-$KIT/../GEMM_32x32_KV260-main}}
OUT=$KIT/sim/build_wave
mkdir -p "$OUT"
[ -f "$REPO/tb/tb_GEMM_2_job_64x64.sv" ] || { echo "không thấy testbench gốc ở $REPO/tb"; exit 1; }

# giống sim/run_system.sh: bỏ 'automatic' (Icarus), weight buffer 1024 như bản ASIC
sed -e 's/task automatic run_one_job/task run_one_job/' \
    -e "s/\.P_WEIGHT_BUFFER_DEPTH(P_BUFFER_DEPTH)/.P_WEIGHT_BUFFER_DEPTH(1024)/" \
    "$REPO/tb/tb_GEMM_2_job_64x64.sv" > "$OUT/tb_icarus.sv"
cat > "$OUT/wave_dump.v" <<'V'
`timescale 1ns/1ps
module wave_dump;
  initial begin
    $dumpfile("wave.vcd");
    $dumpvars(1, tb_GEMM_top_axi_two_job_64x64_verify_copy_matrix);
  end
endmodule
V
# vỏ AXI bản ASIC ở cấu hình thin (GEMM_AXIS_REG=0): cùng chu kỳ kết quả với bản KV260
iverilog -g2012 -DGEMM_AXIS_REG=0 -DGEMM_AXIS_CG=0 -I "$KIT/rtl_asic" -o "$OUT/system.vvp" \
    "$OUT/tb_icarus.sv" "$OUT/wave_dump.v" "$KIT"/rtl_asic/axi/*.v "$KIT"/rtl_asic/*.v
( cd "$OUT" && vvp -n system.vvp > system.log )
grep -E "OVERALL (PASS|FAIL)" "$OUT/system.log"

awk '/MATRIX_BEGIN/{f=1} f{print} /MATRIX_END/{f=0}' "$OUT/system.log" > "$OUT/result_matrix.txt"
cp "$REPO/golden_model/compare_gemm_txt.py" "$OUT/"
( cd "$OUT" && python3 compare_gemm_txt.py | tee golden_compare.txt | tail -3 )
grep -q "OVERALL        : PASS" "$OUT/golden_compare.txt"
echo "xem dạng sóng: gtkwave -S docs/evidence/wave/overview.tcl $OUT/wave.vcd"
