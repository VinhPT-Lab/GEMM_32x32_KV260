# Minh chứng mô phỏng và kiểm chứng (bản v1)

Thư mục này gom các hình và log trả lời tiêu chí "Kết quả mô phỏng và kiểm chứng" của cuộc thi: dạng sóng RTL, kết quả GLS có số mismatch, và đối chiếu với golden model Python. Mọi số liệu ở đây là của bản v1 (IP `gemm_ip`, signoff ở 50 MHz).

Quy ước phiên bản: v0 là bản demo `core_v11`, v1 là bản sạch đầu tiên (`ip_eco_probe`), v2 là bản đang làm.

## Các hình

| Tệp | Nội dung |
|---|---|
| `img/rtl_wave_overview.png` | Dạng sóng RTL của cả hai job 64×64×64 |
| `img/rtl_wave_result_beats.png` | Phóng to các beat kết quả đầu tiên của job 1 |
| `img/rtl_golden_compare.png` | Log mô phỏng RTL và kết quả so với golden model Python |
| `img/gls_golden_compare.png` | Kết quả GLS trên netlist cuối và so với golden model Python |

Chú thích dưới đây viết sẵn để dán vào báo cáo; số hình đổi theo chương.

**Dạng sóng RTL, toàn bộ hai job.** Mô phỏng RTL của bản ASIC (`rtl_asic/`, vỏ AXI cấu hình thin) bằng Icarus Verilog 12, xem bằng GTKWave, với testbench gốc của bản KV260 (`tb_GEMM_2_job_64x64.sv`: hai job 64×64×64 liên tiếp, không reset giữa hai job). Mỗi job gồm ba bước. Đầu tiên host cấu hình qua AXI-Lite (`S_AXI_AWVALID`). Sau đó IP nhận 128 beat feature và 128 beat weight qua AXI-Stream, rồi trả 128 beat kết quả. `result_axis_tlast` đánh dấu beat cuối của mỗi job. Clock của testbench có chu kỳ 10 ns. Đây là mô phỏng chức năng, không kiểm timing.

**Dạng sóng RTL, các beat kết quả đầu tiên.** Phóng to quanh chu kỳ 1491, khi job 1 bắt đầu trả kết quả. Mỗi beat rộng 256 bit, chứa 32 giá trị INT8 của một nửa hàng ma trận C (cột 0–31, rồi cột 32–63). Hình hiện lane 0–3 và lane 31 dạng số có dấu. Một beat chỉ được nhận khi `tvalid` và `tready` cùng ở mức cao. Nhiều giá trị là 127 hoặc −128 vì kết quả được bão hòa về INT8 sau bước dịch (SHIFT = 0), và golden model cũng tính như vậy. Beat đầu tiên trùng với hàng 0 của ma trận kết quả: 127, −128, 127, −128, …, cột 31 là −128.

**So với golden model Python (RTL).** Testbench in ma trận kết quả của hai job. Script `golden_model/compare_gemm_txt.py` của repo FPGA tự sinh lại ma trận A, B và tính C độc lập. Kết quả là 8192/8192 phần tử khớp và 0 mismatch. Testbench cũng báo 0 lỗi giao thức và TLAST đúng ở cả hai job.

**GLS trên netlist cuối.** Mô phỏng mức cổng trên netlist cuối của IP v1, unit-delay, SRAM dùng model OpenRAM. Ba kích thước 64×64×64, 8×32×544 và 16×992×32 đều PASS. Với 64×64×64, testbench báo 0 mismatch và 0 lỗi giao thức ở cả hai job. Ma trận GLS in ra cũng khớp 8192/8192 với golden model Python. GLS không có SDF nên không kiểm timing; timing được kiểm bằng STA (xem `docs/TIEN_DO_SIGNOFF.md`).

## Log và dữ liệu

| Tệp | Nguồn |
|---|---|
| `logs/sim_rtl_64x64x64.log` | Log đầy đủ của mô phỏng RTL, tạo lại bằng `sim/run_wave.sh` |
| `logs/golden_compare_rtl.txt` | Kết quả `compare_gemm_txt.py` trên ma trận RTL |
| `logs/gls_summary.txt` | Tóm tắt ba ca GLS trên netlist cuối |
| `logs/gls_64_64_64.log` | Log GLS 64×64×64 trên netlist cuối (chỉ bỏ đường dẫn thư mục máy ở dòng cuối) |
| `logs/golden_compare_gls.txt` | Kết quả `compare_gemm_txt.py` trên ma trận GLS |
| `wave/rtl_64x64x64.vcd` | Dạng sóng RTL (các tín hiệu ở cấp testbench) |
| `wave/overview.tcl`, `wave/result_beats.tcl` | Script GTKWave dựng lại hai hình dạng sóng |

## Tạo lại

Cần iverilog ≥ 11 và python3. Repo FPGA `GEMM_32x32_KV260` đặt cạnh repo này, hoặc truyền đường dẫn của nó:

    sim/run_wave.sh ../GEMM_32x32_KV260
    gtkwave -S docs/evidence/wave/overview.tcl sim/build_wave/wave.vcd
    gtkwave -S docs/evidence/wave/result_beats.tcl sim/build_wave/wave.vcd

Script in `OVERALL PASS` của testbench, rồi `TOTAL MISMATCH : 0` của golden model. Nó dừng với mã lỗi nếu một trong hai không đạt.

Các ca giới hạn đã biết (M = 1, bộ đệm đầy đúng 512/1024 từ) nằm ở mục ERRATA của README và trong `docs/paper/data/gls_errata.txt`. Các ca đó không thuộc ba kích thước kể trên.
