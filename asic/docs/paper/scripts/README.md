# Script của gói bằng chứng

Các script đọc đường dẫn từ biến môi trường. Script Tcl đọc qua `$::env(...)`. Trong bản sao ở repo, các đường dẫn cố định đã được thay bằng `${ECO_DIR}`, `${REPO}`... và cần đặt lại trước khi chạy.

| Biến | Ý nghĩa |
|---|---|
| `ECO_DIR` | thư mục làm việc ECO: `final/`, `s5/final_a5/`, `lib/`, `lef/`, `paper/` |
| `REPO` | repo này (cần `rtl_asic/`, `sim/run_ip_gls.sh`, `tools/power/`) |
| `KV260` | repo GEMM_32x32_KV260 (testbench gốc) |
| `OL` | OpenLane 1.0.2 |
| `PDK_ROOT` | PDK của flow OpenLane 1.0.2 (có `sky130A/` bên dưới) |

Thứ tự chạy, mỗi lúc một job nặng:

1. `static_stats.py` (DEF của IP, row, AXI), rồi `perf.py` (log GLS), `phys_cost.py` (diode, buffer hold, NAND2).
2. `job_power.sh <M,K,N> <JOB_2_START-1> <RESULT_ACCEPT cuối của job 2>` cho từng kích thước. Script này gọi `vcd_job_ip.py`, `vcd2act_phases.py` (đọc VCD, có xử lý alias) và `power_phases.tcl`. Sau đó chạy `job_energy.py`, `sram_range.py`, rồi `leak_blocks.sh` (leakage theo khối).
   - `vcd_power.sh` và `vcd2act_ip.py` là bản cũ, đã thay thế (lỗi alias), chỉ giữ để truy vết.
3. `perf_rtl.py` (mô phỏng RTL nhiều kích thước, qua `run_system_paper.sh` và `phases.py`), rồi `plots_perf.py`.
4. `pe_harden.sh`, `block_fmax.tcl`, `block_sim_power.sh pe|row`, `pe_equiv2.ys` (Yosys 0.62 hoặc 0.30). `pe_equiv.ys` là bản cũ, kiểm có giới hạn.
5. `ir_drop.tcl` (có thể đặt `VSRC`), `ir_row.tcl`, rồi `ir_map.py <dir> <vccd1.csv> <vssd1.csv> <tag>`. File VSRC mỗi dòng có dạng `x,y,size,voltage`, phải ngăn cách bằng dấu phẩy.
6. `klayout_shots.py`, `or_shots.tcl`, `density_maps.py`, `block_maps.py`.
7. `plots.py`. Cần matplotlib 3.9.2; image OpenLane không có, nên tạo venv riêng.
8. Đợt 3:
   - `perf_overlap.py`: ước tính chồng pha, dựa trên log của `perf_rtl.py`;
   - `sta_ss140.sh`: STA ở ss_100C_1v40, gọi `sta_ss140.tcl` và `block_fmax.tcl`;
   - `gls_errata.sh <M,K,N>...`: GLS trên netlist cuối, so từng dòng với log RTL của `sim/run_errata.sh`;
   - `phases.py` nay tách thêm pha `tile_reload`.
