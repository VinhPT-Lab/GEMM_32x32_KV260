# GEMM 32x32 INT8 trên SKY130
link Drive dự án: https://drive.google.com/drive/u/0/folders/1rQGXBQMxBw7CRs1iQ_FK7p_eN03Ah15e

## Hồ sơ cho giám khảo

Quy ước phiên bản: **v0** là bản demo `core_v11`, **v1** là bản sạch đầu tiên (IP `gemm_ip`, signoff ở 50 MHz), **v2** là bản đang làm. Số liệu nộp cuộc thi là của v1.

| Cần xem | Ở đâu |
|---|---|
| Kết quả signoff v1 (DRC, LVS, antenna, timing, công suất) | mục "Bản v1" bên dưới, `docs/TIEN_DO_SIGNOFF.md` |
| RTL đầy đủ của bản ASIC | `rtl_asic/` (vỏ AXI ở `rtl_asic/axi/`) |
| Testbench và script mô phỏng | `sim/` |
| Dạng sóng RTL, log GLS, so với golden model Python | `docs/evidence/` |
| Gói số liệu và hình của layout (IR drop, slack, mật độ, ECO) | `docs/paper/` (`SUMMARY.md`, `data/`, `figures/`) |
| Flow OpenLane và script ECO | `openlane/`, `tools/eco/` |
| Bản FPGA KV260 (RTL gốc, testbench gốc, golden model, tích hợp llama.cpp) | https://github.com/VinhPT-Lab/GEMM_32x32_KV260 |
| Website giới thiệu, có layout 3D từ GDS/DEF thật | https://nguyen-ky2910.github.io/WEB_GEMM_32x32_FPGT/ |

Kiểm chứng tóm tắt:
- RTL ASIC chạy testbench gốc của bản KV260 (2 job 64×64×64): PASS, 8192/8192 phần tử khớp golden model Python (`sim/run_wave.sh`).
- GLS trên netlist cuối của v1: 64×64×64, 8×32×544, 16×992×32 đều PASS; ở 64×64×64 có 0 mismatch và khớp golden model Python.
- Layout v1: Magic DRC 0, LVS khớp, antenna 0, KLayout XOR 0, DRV 0.

Tệp layout lớn không đưa vào git: `GEMM_top.gds` (708,7 MiB), `GEMM_top.def` (469,1 MiB), netlist `GEMM_top.nl.v` (196,5 MiB), cùng LEF, Liberty, SDC và các báo cáo DRC/LVS/STA. Tải ở thư mục `final` của v1 trên Drive (ai có link đều xem được): https://drive.google.com/drive/folders/1SNKjXqcsqroH8pAdLk6_jX4fOtAbhqEZ. GDS cuối có sha256 `87286b9408d1a706d1f47a2925317ed5ed702c0700b780edbdda0a22e8b068fa`.

Bộ tăng tốc nhân ma trận INT8 32x32 kiểu weight-stationary. Bản gốc chạy trên FPGA KV260;
repo này đưa nó ra layout trên SKY130 bằng OpenLane 1.0.2. Thiết kế được harden theo tầng:
PE, row (32 PE), array, rồi core GemmAccelerator gồm 32 row macro và 80 SRAM OpenRAM.

## Bản v0 (demo, core_v11)

Bảng này là của run core_v11 chạy riêng, ở chu kỳ 10 ns (100 MHz). STA của run này chưa kiểm các path đi qua
macro (SRAM, row). Khi kiểm đủ, fmax ở tt chỉ khoảng 53 MHz, nên mọi con số tính ở 100 MHz dưới đây là **giả định**
**100 MHz**, không phải tần số đã đạt. Kết quả đã signoff là của IP gemm_ip ở 50 MHz, ở phần sau.

| Mục | Kết quả |
|---|---|
| Die | 7,06 x 10,24 mm (72,3 mm²) |
| Tần số | 100 MHz ở tt/25°C/1,80V là giả định, không đạt khi kiểm đủ path qua macro (kiểm đủ thì khoảng 53 MHz ở tt). Khoảng 57 MHz ở ss/100°C/1,60V, cũng chưa kiểm path qua macro |
| DRC | router 0; Magic 0 lỗi thật (48 cờ do view abstract của macro, đã kiểm lại trên layout đầy đủ) |
| LVS | khớp |
| Setup / hold | ở chu kỳ 10 ns, chưa gồm path qua macro; path nội bộ ở tt: setup +1,21 ns, hold +0,27 ns; hold sạch ở ff với cả RC min và RC max |
| Antenna | core_v11 chạy riêng còn 219 pin trên 205 net, vượt nhẹ (trung vị 1,4 lần giới hạn), không chân SRAM nào |
| Mô phỏng gate-level | netlist core cùng netlist gate-level của 32 row: PASS cả 3 kích thước ma trận (64x64x64, 8x32x544, 16x992x32), trùng từng chu kỳ với RTL FPGA |
| Công suất | tt/25°C/1,80V, giả định 100 MHz, không đạt khi kiểm đủ path qua macro: 1,53 W với activity từ VCD (mô phỏng gate-level cả core lẫn row, pha tính của ma trận 64x64x64); đo lại bằng bộ đọc VCD đã sửa lỗi alias (đợt 3): không đổi, 1529,70 mW; 2,89 W với activity mặc định của OpenSTA |
| Hiệu suất | giả định 100 MHz, không đạt khi kiểm đủ path qua macro: đỉnh 204,8 GOPS (2 x 32 x 32 x 100 MHz), 134 GOPS/W (theo 1,53 W), 2,83 GOPS/mm² |

## Bản v1: IP gemm_ip (core + vỏ AXI), signoff ở 50 MHz

IP đã signoff ở **50 MHz (chu kỳ 20 ns), TT theo lib**, trên layout ECO cuối. Chi tiết ở `docs/TIEN_DO_SIGNOFF.md`.

| Mục | Kết quả |
|---|---|
| Antenna, DRC, LVS | ARC 0; DRT 0; Magic 0; LVS khớp; KLayout XOR 0 |
| Setup / hold nội bộ | tt: setup +1,43 ns, hold +0,32 ns; hold ff +0,13 ns; hold ss +0,23 ns |
| DRV | 0 net cell chuẩn vượt giới hạn lib ở tt và ss |
| Mô phỏng gate-level | PASS cả 3 kích thước, trùng từng chu kỳ với RTL cùng cấu hình |
| Công suất | 745,1 mW theo VCD cả job (64x64x64; 8x32x544: 751,0; 16x992x32: 753,5 mW; SRAM tính theo lib, là cận trên; nếu lấy SRAM cận dưới thì khoảng 623–626 mW), tt, SPEF RC nom, 50 MHz; tham khảo: 1377,6 mW vectorless (activity mặc định của OpenSTA) |
| Hiệu suất | đỉnh 102,4 GOPS (2 x 32 x 32 x 50 MHz). Hiệu dụng theo GLS và công suất VCD: 64x64x64 15,9 GOPS, 21,4 GOPS/W, 93,5 pJ/MAC (8x32x544: 3,5 GOPS/W; 16x992x32: 7,0 GOPS/W); năng lượng đo trên cả job. Đỉnh chia công suất đo: 137 GOPS/W, chỉ là cận trên. Chi tiết: docs/paper/SUMMARY.md |
| Mô hình timing | `GEMM_top.tt.lib` cho người tích hợp (phần I/O) |

Giới hạn:
- 50 MHz là con số **TT theo lib**. SRAM OpenRAM chỉ có lib TT, và timing của SRAM là ngoại suy, vì lib chỉ đặc tính hoá slew 1,25–40 ps.
- SRAM OpenRAM đo trên silicon chạy được khoảng 34–40 MHz.
- Setup ss của path chạm macro (−4,94 ns ở chu kỳ 20 ns) và hold của path I/O chỉ được báo kèm.

## Chạy

Cần OpenLane 1.0.2 (Docker) ở ~/OpenLane, PDK sky130A, iverilog và python3. Repo gốc
GEMM_32x32_KV260 đặt cạnh thư mục này (dùng testbench của nó). Cài đặt, thời gian, cách đọc
kết quả và lỗi hay gặp: HUONGDAN.md.

    openlane/run_flow.sh sim        # RTL ASIC so với RTL FPGA
    openlane/run_flow.sh pe
    openlane/run_flow.sh row
    openlane/run_flow.sh array
    openlane/run_flow.sh core-sim   # RTL core với model SRAM OpenRAM
    openlane/run_flow.sh core-pre
    openlane/run_flow.sh core       # khoảng 7-9,5 giờ, cần 16 GB RAM và 40 GB ổ trống
    openlane/run_flow.sh core-gls   # mô phỏng gate-level netlist cuối

AXI accelerator IP (core bọc AXI4-Lite + 3 cổng AXI4-Stream; thanh ghi 0x00-0x0C như bản KV260, thêm ngắt
`irq`, IRQ_ENABLE/IRQ_STATUS, ERROR, JOB_CYCLES, IP_ID/IP_VERSION ở 0x10-0x24; HUONGDAN.md mục 8):

    openlane/run_flow.sh axi-sim    # slice, shell + model core, testbench gốc với thin/reg/lean(+clock gating)
    openlane/run_flow.sh axi-shell  # harden riêng phần AXI cho thin, reg, lean, lean_cg; bảng overhead so với core
    openlane/run_flow.sh axi-gls    # GEMM_top (lean + clock gating) bọc netlist cuối của core

Mỗi tầng chỉ chạy khi tầng trước đã qua. Kết quả ghi vào openlane/LOG.md,
GDS nằm ở ~/OpenLane/designs/gemm_core/runs/<tag>/results/final/gds/.

## Thư mục

    rtl_asic/   RTL cho ASIC (rtl_asic/axi: wrapper AXI của IP)
    sim/        so sánh với RTL FPGA, mô phỏng gate-level
    docs/evidence/  dạng sóng RTL, log GLS, đối chiếu golden model (bản v1)
    docs/paper/     gói số liệu và hình của layout v1
    openlane/   run_flow.sh và cấu hình từng tầng
    tools/      đọc log, kiểm tra DRC quanh macro, phân tích antenna, timing và công suất

## Ghi chú thiết kế

- Mỗi SRAM đặt sát phần logic dùng nó. Floorplan đầu gom SRAM thành khối lớn thì global route nghẽn tới mức crash.
- Cấm đi dây met5 trên SRAM: SRAM đã chặn met1-met4, dây đổi track trên met5 tạo short không sửa được.
- Sau global route có bước kiểm tra net đi xuyên lòng macro; có thì dừng sớm thay vì chạy DRT vô ích.
- Tắt diode heuristic (nguồn nghẽn chính); LEF của SRAM được bổ sung dữ liệu antenna để công cụ thấy chân SRAM.
- Magic DRC đọc cell chuẩn bằng layout đầy đủ, macro bằng abstract; cờ quanh macro được kiểm lại bằng tools/magic_macro_check.sh.
- repair_timing chạy với -skip_pin_swap, và tầng row so netlist cuối với RTL (sim/row_equiv.sh): LVS không bắt được lỗi đổi chân.

## ERRATA (IP v1)
Hai lỗi của RTL, có cả trong netlist cuối của IP. RTL và layout của v1 giữ nguyên; **sẽ sửa ở v2**. Test có chủ đích: `sim/run_errata.sh` (RTL đúng cấu hình đã build: `asic-sram`, WRAP=lean, AXIS_CG=1; 11 ca, mọi ca đúng như mô tả dưới đây). GLS trên netlist cuối cho M = 1, M = 2 và job 511 từ feature (73×224×32) giống RTL từng dòng, kể cả ở ca lỗi M = 1 (`docs/paper/data/gls_errata.txt`).

**E1. Mỗi bộ đệm chứa ít hơn độ sâu của nó 1 từ (511 / 1023 / 511 thay vì 512 / 1024 / 512).**
- Nguyên nhân: bộ đếm số từ rộng log2(depth) bit, nên số từ đúng bằng độ sâu quay về 0.
  - `rtl_asic/In_buffer.v:70-71`: `r_weight_words_expected` 10 bit, `r_feature_words_expected` 9 bit.
  - `In_buffer.v:106` và `:116-117`: tích `row_count × k_block_count` và `n_block_count × k_block_count × 32` bị cắt.
  - `In_buffer.v:88-89`: ready = `write_count < expected`.
  - `In_buffer.v:91`: bắt đầu đọc cần `expected != 0`.
  - `rtl_asic/Out_buffer.v:52` và `:285`: `r_result_words_expected` 9 bit = `row_count × n_block_count` bị cắt.
- Điều kiện xảy ra:
  - feature M·Kb = 512: job treo; chỉ 1 beat được nhận, chính là beat do slice AXI giữ;
  - weight 32·Kb·Nb = 1024: job treo;
  - kết quả M·Nb = 512: sai giá trị và thừa beat (580 thay vì 512).
  - Các kích thước lớn hơn nằm ngoài giới hạn của host bên dưới.

**E2. M = 1 (row_count = 1) cho kết quả sai và thừa beat kết quả.** Kể cả job một tile 1×32×32 cũng sai. Nguyên nhân, xác định bằng vết mô phỏng RTL so M = 1 với M = 2:
- `rtl_asic/Buffer_feeder.v:109`: `input_feature_last = (feature_cnt == row_count − 1)`. Với row_count = 1, cờ này bằng 1 ở mọi chu kỳ `feature_cnt = 0` mà không kèm valid. `Buffer_feeder.v:130` đưa nó ra `r_compute_input_last` suốt trạng thái SET_FEATURE.
- `rtl_asic/Gemm_compute_core.v:147` đẩy `last` vào pipeline mà không AND với valid, nên ra nhiều xung `o_partial_last`. Khi đó `Buffer_feeder.v:103` (`total_last`) lặp lại, OutputBuffer kết thúc job nhiều lần, và `In_buffer.v:91-95` (`| i_compute_partial_last`) khởi động đọc lại.
- Thêm vào đó, `In_buffer.v:232-237`: `r_feature_read_row` được đặt bằng 1 rồi tăng mãi, vì phép so sánh với `row_count − 1 = 0` không bao giờ đúng. Địa chỉ feature của các K-block sau vì vậy sai.

**Ràng buộc cho host (driver) với IP v1:**
- **M ≥ 2:** với GEMV (M = 1), đệm thêm một hàng 0 và bỏ hàng kết quả thừa, hoặc chạy trên CPU.
- **Mỗi job:** M·Kb ≤ 511, 32·Kb·Nb ≤ 1023 (tức Kb·Nb ≤ 31), M·Nb ≤ 511, M ≤ 511, Kb ≤ 31, Nb ≤ 31, với Kb = ⌈K/32⌉, Nb = ⌈N/32⌉.
- **Ma trận lớn hơn:** chia theo M và N. Không chia theo K, vì kết quả là INT8 sau phép dịch.

## Hạn chế

- Resizer của bản OpenROAD này có thể đổi chân của cell không giao hoán (and2b) khi sửa timing, và LVS không bắt được
  vì layout khớp với netlist đã sai. Flow chặn bằng -skip_pin_swap và so netlist row với RTL (sim/row_equiv.sh) ở tầng row.
- Antenna: core_v11 chạy riêng còn 219 chân, vì router của OpenLane 1.0.2 không tính antenna khi đi dây và không có
  chế độ ECO tăng dần. IP gemm_ip đã về 0 nhờ ECO tăng dần bằng OpenROAD mới (tools/eco).
- Con số 100 MHz của core_v11 chưa kiểm các path đi qua macro (SRAM, row); kiểm đủ thì chỉ khoảng 53 MHz ở tt.
  Con số khoảng 57 MHz ở corner chậm cũng chưa kiểm path qua macro. IP signoff ở 50 MHz (tt theo lib); setup ss của
  path chạm macro là −4,94 ns ở chu kỳ 20 ns, chỉ báo.
- Timing ở cổng I/O được miễn vì core chưa có vòng pad (196 path, tệ nhất -0,81 ns ở tt); đây là core, chưa phải chip hoàn chỉnh.
- Công suất SRAM là cận trên: thư viện OpenRAM cho cùng năng lượng mỗi cạnh clock dù SRAM có được chọn hay không.

Lịch sử các lần chạy: NHATKY.md.
