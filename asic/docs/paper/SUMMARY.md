# Gói bằng chứng: IP gemm_ip (GEMM 32x32 INT8, SKY130) sau ECO signoff

**Đây là số sau layout, lấy từ mô phỏng và phân tích tĩnh, chưa phải số đo trên silicon.** Đường dẫn file tính từ thư mục làm việc ECO (`$ECO_DIR`). Trong repo, gói này nằm ở `docs/paper/`, chỉ gồm các file dưới 5 MB; báo cáo theo từng instance (`*.inst.rpt`, `*.act`) chỉ có ở `$ECO_DIR/paper/data/power/` (nén gzip). Mọi con số dưới đây đều ghi kèm file nguồn (trong `paper/data/` trừ khi ghi khác) và điều kiện đo.

Đối tượng là layout cuối `s7E/a5.def` (bản sao ở `final/GEMM_top.def`) cùng run OpenLane 1.0.2 `s5/final_a5`.
- Clock 20 ns (50 MHz). SDC: `final/GEMM_top.sdc`.
- SPEF signoff: RC nom, trích bằng OpenRCX của OpenLane 1.0.2.
- Cell chuẩn: lib `sky130_fd_sc_hd`. SRAM: lib OpenRAM `sky130_sram_2kbyte_1rw1r_32x512_8`, chỉ có bản TT, nên dùng cho mọi corner.

## Giới hạn đã biết (đọc trước khi dùng số)
- **50 MHz là "TT theo lib".**
  - SRAM chỉ có lib TT. Timing của SRAM là ngoại suy, vì lib chỉ đặc tính hoá slew 1,25–40 ps.
  - Theo các báo cáo đã công bố, SRAM OpenRAM trên silicon chạy được khoảng 34–40 MHz.
  - Setup ở SS của các path chạm macro âm (−4,94 ns, RC max), chỉ báo.
- **Hold I/O ở SS âm** (607 endpoint, tệ nhất −4,04 ns), chỉ báo. Nguyên nhân là SDC coi clock bên ngoài là lý tưởng; người tích hợp tính lại bằng `final/GEMM_top.tt.lib`.
- **Công suất SRAM là cận trên.** Lib OpenRAM tính cùng một năng lượng cho mọi cạnh clock, dù SRAM có được chọn hay không. Ở cửa sổ 64×64×64, SRAM chiếm 224 mW (28 %).
  - *Cập nhật:* nay báo thành khoảng, cận dưới theo số chu kỳ SRAM được chọn đếm từ VCD: 96–105 mW (mục 3.4).
- **Công suất theo hoạt động lấy từ GLS unit-delay, không có glitch.** Mỗi kích thước chỉ dùng một cửa sổ 400 chu kỳ trong pha tính. Năng lượng mỗi GEMM giả định công suất của cửa sổ đó đúng cho cả job; pha nạp và xuất dữ liệu có thể tốn ít hơn.
  - *Cập nhật:* giả định cửa sổ đã được thay bằng số đo cả job 2 và theo từng pha (mục 3). Số cửa sổ cũ còn bị lỗi đọc VCD (xem "Thay đổi so với bản trước"), nên không dùng nữa. Vẫn là GLS unit-delay, không có glitch.
- **Điện dung RCX lớn hơn ước lượng sau global route khoảng 1,5–2,7 lần** trên các net dài (`cap_ratio_rcx_grt.csv`).
- **IR drop:**
  - phân tích tĩnh;
  - row và vỏ AXI được mô hình bằng công suất trung bình không đổi, gắn vào macro (lý do và cách làm ở mục IR drop);
  - điểm cấp nguồn do PSM tự đặt trên chân vccd1/vssd1 của IP, chưa có lưới bump hay pad.
  - *Cập nhật (đợt 3):* cận bi quan VDD − VSS là khoảng 1,50 V, không phải 1,56 V như đợt 2 (mục 5.3).
  - *Cập nhật:* câu trên sai. Lần chạy đầu dùng mẫu bàn cờ mặc định của PSM (bump cách 140 µm trên toàn vùng core, cảnh báo PSM-0016/0065), không phải chân của IP. Bản mới chạy hai mô hình nguồn (bàn cờ, và nguồn ở hai đầu các dải met5 là chân của IP), và tính thêm IR drop bên trong row (mục 5).
- **Kiểm tương đương PE** là kiểm có giới hạn (BMC 20 chu kỳ), chưa phải chứng minh đầy đủ (mục 8).
  - *Cập nhật:* đã chứng minh đầy đủ bằng `equiv_induct` khi ghép thanh ghi theo tên. Kết quả giống nhau trên Yosys 0.62 và Yosys 0.30 (mục 8).
- **Thông lượng đo bằng testbench gốc**, testbench này tự chèn chu kỳ trống trên luồng vào và hạ TREADY của luồng kết quả. Số "full-rate" (luồng một beat mỗi chu kỳ) ở mục 2 là cận trên của chính phần cứng, đo bằng RTL.
- **row_count = 1 (M = 1) cho kết quả sai trong RTL** (sai giá trị, thừa beat kết quả). Đây là một giới hạn của thiết kế; host phải đệm lên 2 hàng (mục 2.3).
  - *Cập nhật (đợt 3):* đã tìm ra nguyên nhân (file:dòng), có test có chủ đích, và GLS xác nhận netlist cuối giống RTL. Xem mục 9 ERRATA, cùng lỗi dung lượng bộ đệm.

## Thay đổi ở đợt 3
- **`tools/power/vcd2act.py` của repo** đã sửa giống bản trong gói này: mỗi mã id VCD cập nhật mọi tên của net.
  - Đo lại công suất VCD của core_v11 (100 MHz, chu kỳ 2300–3200, 13 phút 46 giây; kết quả ở `data/core_v11_vcd_recheck/`): **1529,70 mW, giống hệt số cũ**.
  - Ở netlist core, lỗi chỉ làm mất activity của 63 chân `clkbuf_*` đưa clock vào row. OpenSTA tính các chân này theo clock, nên tổng không đổi. Số 1,53 W trong README và HUONGDAN vẫn đúng.
  - `tools/power.sh` có thêm `POWER_OUT` / `POWER_BUILD` để chạy mà không ghi vào thư mục run.
- **Mục 9 ERRATA mới:**
  - nguyên nhân hai lỗi theo file:dòng;
  - `sim/run_errata.sh` (11 ca RTL);
  - GLS trên netlist cuối cho các ca nhỏ;
  - so sánh với bản FPGA và driver.
  - Phát hiện thêm: job có đúng 512 từ kết quả không treo mà **ra kết quả sai**.
- **Mục 2:** tách rõ số (T) và (F); thêm pha "nạp lại K-block" (bản trước gộp vào "xuất"; ở 16×992×32 đó là 1020 chu kỳ), giới hạn kiến trúc, và ước tính chồng pha.
- **Mục 3.5 mới:** phần theo clock và theo dữ liệu, đo bằng một lần chạy chỉ có clock. 711,8 trong 745,1 mW chạy theo clock.
- **Mục 5:** sửa số tại macro row (bản trước chỉ lấy nút cuối của mỗi macro); viết phép cộng từng bước; cận bi quan là 1,50 V, không phải 1,56 V. Thêm STA ở ss_100C_1v40.

## Thay đổi so với bản trước của SUMMARY (đợt 2)
- **Công suất:** bộ đọc VCD cũ (`vcd2act_ip.py`) chỉ giữ tên cuối của mỗi mã id. iverilog dùng một mã id cho mọi tên của cùng một net (net ở top và cổng row/AXI mà nó nối tới), nên driver của các net ở biên row/AXI nhận 0 toggle với duty 0. Với các pin đó, OpenSTA tự suy ra activity thay vì dùng số đo.
  - Đã sửa trong `vcd2act_phases.py` và đo lại cả job.
  - 64×64×64: công suất cả job **745 mW** (bản cũ 800 mW, cửa sổ); **21,4 GOPS/W**, 93,5 pJ/MAC (bản cũ 19,9 GOPS/W, 100,4 pJ/MAC). AXI: 2,8 mW (bản cũ 8,8 mW).
  - Số cũ chuyển sang `data/superseded_alias_bug/`.
  - `vcd2act_flat.py` (công suất PE/row ở mục 4) đã xử lý alias từ trước, nên không bị ảnh hưởng.
  - `tools/power/vcd2act.py` của repo (công suất core trước đây) có cùng lỗi này.
- **IR drop:** đo lại với activity đã sửa và mô hình row/AXI mới (12,69 / 3,28 mW). Mô hình bàn cờ cho 137,1 / 153,6 mV, gần như không đổi. Thêm mô hình nguồn ở mép die và IR bên trong row.
- **Hiệu năng:** thêm phân pha, các kích thước lớn, mô phỏng full-rate và roofline. Phát hiện giới hạn bộ đệm thật là 511 / 1023 / 511 từ, và lỗi khi M = 1.
- **PE:** có 82 flop (66 `dfxtp` + 16 `dfrtp`), không phải 66; số 66 là metric `DFF` của OpenLane, chỉ đếm flop không reset. Nhận định "netlist có 16 flop thừa" ở bản trước là sai. Tương đương PE nay đã chứng minh đầy đủ.
- **Leakage:** thêm bảng tách theo khối, mỗi khối chạy riêng; tổng khớp với bảng cũ.

## 1. Số liệu tĩnh
Nguồn: `ip_summary.csv`, `ip_groups.csv`, `cells_by_block.csv`, `wires_by_block.csv`; script `scripts/static_stats.py`. Kích thước lấy từ LEF.

| Mục | Giá trị |
|---|---|
| Die | 7274,90 × 10493,76 µm = **76,34 mm²** |
| Vùng core (khung bao các hàng) | 76,07 mm² |
| Macro | 38,72 mm²: 80 SRAM 22,76; 32 row 15,00; vỏ AXI 0,95 |
| Cell chuẩn ở top, trừ filler/decap/tap | 1,61 mm² |
| Mật độ (macro + cell chuẩn) / core | 53,0 % |
| Cổng quy đổi NAND2 (diện tích logic / diện tích `nand2_1` 3,7536 µm²) | top 404 130 + 32 × 58 839 (row) + 26 011 (AXI) = **2,313 triệu** (gồm buffer hold và cây clock, không gồm diode; các biến thể ở mục 1.1) |
| Flop | top 22 109 + 32 × 2 616 + 1 158 = **106 979** |
| Instance trong DEF top | 3 697 759 |
| PE | 1024 (32 row × 32) |

Số cell theo khối, tính trên cả IP (top phẳng + 32 row + AXI), nguồn `cells_by_block.csv`:

| Nhóm | Số cell | Diện tích (µm²) |
|---|---|---|
| logic tổ hợp | 573 932 | 4 239 816 |
| flop | 106 979 | 2 260 065 |
| buffer hold (dlygate, `hold*`) | 134 939 | 1 348 521 |
| buffer của resizer và I/O | 84 101 | 617 724 |
| cây clock | 8 270 | 202 264 |
| buffer ECO (`eco_*`) | 1 593 | 9 459 |
| tie | 1 126 | 4 227 |
| diode | 533 405 | 1 334 793 |
| filler/decap | 4 082 038 | 38 085 687 |
| tap | 723 449 | 905 180 |
| SRAM / row / AXI macro | 80 / 32 / 1 | |

Cell do ECO thêm so với DEF vòng 1 của ip_v3r: 2968 cell (1220 diode, 1742 buffer, 6 dlygate); 794 cell đổi cỡ; 187 diode bị xoá. Nguồn: `netdiff` trong `BAOCAO.md`.

Chiều dài dây tín hiệu (không tính lưới nguồn), cả IP, nguồn `wires_by_block.csv`:

| Lớp | Dây (m) | Via ở lớp cut ngay trên |
|---|---|---|
| met1 | 17,41 | via 3 271 001 |
| met2 | 18,39 | via2 231 441 |
| met3 | 6,21 | via3 36 732 |
| met4 | 1,95 | via4 1 020 |
| met5 | 0,17 | – |
| li1 | – | mcon 3 359 796 |

Mật độ dây sau route của top, tính theo ô 50 µm (`routing_utilisation.csv`): met1 38 %, met2 68 %, met3 73 % (3 ô vượt 70 %), met4 66 %.

### 1.1 Chi phí vật lý: diode, buffer hold, NAND2
Nguồn: `diodes_by_block_origin.csv`, `nand2_hold_by_block.csv`, `diode_config_by_design.csv`; script `scripts/phys_cost.py`.

Nguồn gốc diode được nhận theo tên instance:
- `ANTENNA_<inst>_<pin>`: diode của flow trước route (DIODE_ON_PORTS và chèn heuristic).
- `ANTENNA_<số>`: `repair_antennas` của global route.
- `ANTFIX<k>_…`: `ant_eco.py` của flow, chèn theo báo cáo ARC giữa các vòng route.
- Ở top, mọi diode không có trong DEF vòng 1 của ip_v3r là của ECO. Các vòng ECO cũng gọi `repair_antennas` và đánh số giống flow, nên phải tách theo DEF vòng 1 chứ không theo tên.

| Khối | Diode | Trước route (cổng + heuristic) | repair_antennas lúc GRT | ant_eco.py (flow) | ECO |
|---|---|---|---|---|---|
| top | 37 085 | 0 | 34 652 | 1 213 | 1 220 |
| một row | 15 271 | 15 252 | 19 | 0 | 0 |
| 32 row | 488 672 | 488 064 | 608 | 0 | 0 |
| vỏ AXI | 7 648 | 4 607 | 14 | 3 027 | 0 |
| **IP** | **533 405** | 492 671 | 35 274 | 4 240 | 1 220 |

ECO cũng xoá 187 diode của DEF vòng 1 (trên net clock, bước 7B).

Cấu hình chèn diode, giá trị đã resolve trong `config.tcl` của từng run:

| Thiết kế (run) | DIODE_ON_PORTS | Heuristic | Ngưỡng (µm) | GRT_REPAIR_ANTENNAS | GRT_MAX_DIODE_INS_ITERS | GRT_ANT_MARGIN |
|---|---|---|---|---|---|---|
| gemm_pe (paper_pe) | none | 0 | 90 | 1 | 1 | 10 |
| gemm_row (row_v1) | in | 1 | 50 | 1 | 1 | 30 |
| gemm_core (core_v11) | none | 0 | 50 | 1 | 3 | 30 |
| gemm_ip (ip_v3r) | none | 0 | 50 | 1 | 3 | 30 |
| gemm_ip_shell (ip_shell5) | in | 1 | 50 | 1 | 3 | 30 |
| gemm_array (chỉ có config, không còn run; không nằm trong IP) | – | 1 | 50 | – | 3 | 30 |

Buffer hold và cổng quy đổi NAND2 (diện tích / 3,7536 µm²). "Logic" gồm logic tổ hợp, flop, tie, buffer của resizer/I/O và buffer ECO:

| Khối | Buffer hold | Cây clock | Diode | NAND2: chỉ logic | + hold | + hold + clock | + hold + clock + diode |
|---|---|---|---|---|---|---|---|
| top | 47 000 | 4 257 | 37 085 | 249 918 | 375 750 | 404 130 | 428 853 |
| 32 row | 82 368 | 3 776 | 488 672 | 1 639 381 | 1 858 837 | 1 882 859 | 2 208 640 |
| vỏ AXI | 5 571 | 237 | 7 648 | 10 554 | 24 527 | 26 011 | 31 110 |
| **IP** | **134 939** | 8 270 | 533 405 | **1 899 853** | 2 259 114 | **2 313 000** | **2 668 603** |

Buffer hold chiếm 15,9 % diện tích logic có hold của IP (1,35 / 8,48 mm²). Riêng ở top, chúng chiếm 33 %.

## 2. Hiệu năng ở 50 MHz
Có **hai loại số**, đừng trộn lẫn:
- **(T) testbench gốc:** đo bằng GLS trên netlist cuối, và RTL cho ra đúng từng chu kỳ như vậy. Testbench tự chèn 0–3 (feature) và 0–4 (weight) chu kỳ trống trước mỗi beat. Nó hạ TVALID sau mỗi beat, nên mỗi luồng vào nhiều nhất 1 beat mỗi 2 chu kỳ. TREADY của luồng kết quả thấp ở 1/7 + 1/11 số chu kỳ. Số này bị **TVALID của testbench** giới hạn, không phải do IP.
- **(F) full-rate:** cùng RTL (`asic-sram`, WRAP=lean, AXIS_CG=1, đã trùng GLS từng chu kỳ trên 3 kích thước). Bản sao testbench được vá: không có chu kỳ trống, TVALID giữ liền, TREADY kết quả luôn cao (`run_system_paper.sh`, FULLRATE=1). Đây là giới hạn của **chính phần cứng** khi luồng chạy đủ tốc độ.

Đỉnh: 102,4 GOPS (2 × 1024 PE × 50 MHz). Tỉ lệ dùng PE = MAC / (1024 × chu kỳ). Một job tính từ JOB_START tới RESULT_ACCEPT cuối (job 2, không reset giữa hai job).

### 2.1 Ba kích thước GLS
Nguồn: `perf_gls_50MHz.csv` (T, GLS; script `scripts/perf.py`), `perf_rtl_shapes.csv` (F).

| Kích thước (M×K×N) | MAC | (T) chu kỳ | (T) GOPS | (T) dùng PE | (F) chu kỳ | (F) GOPS | (F) dùng PE |
|---|---|---|---|---|---|---|---|
| 64×64×64 | 262 144 | 1645 | **15,94** | 15,6 % | 1226 | **21,38** | 20,9 % |
| 8×32×544 | 139 264 | 5330 | 2,61 | 2,6 % | 3661 | 3,80 | 3,7 % |
| 16×992×32 | 507 904 | 9654 | 5,26 | 5,1 % | 6675 | 7,61 | 7,4 % |

### 2.2 Chia chu kỳ theo pha, luồng dữ liệu
Nguồn: `perf_rtl_subjobs.csv`, `power/job_*/job_*.phases.csv`; script `scripts/phases.py`, `vcd_job_ip.py`.

Mỗi chu kỳ thuộc đúng một pha, lấy theo trạng thái FSM của BufferFeeder và các dòng của testbench:
- **cấu hình:** IDLE trước beat vào đầu tiên (AXI-Lite);
- **nạp:** IDLE từ beat vào đầu tiên tới tile đầu tiên. Gồm feature và weight vào SRAM, xen kẽ nhau, cộng thêm lần chuyển K-block đầu tiên sang bộ nhớ tile;
- **nạp weight:** SET_WEIGHT, mỗi tile 32×32 tốn 34 chu kỳ;
- **tính:** SET_FEATURE;
- **nạp lại K-block:** IDLE giữa hai tile, khi K-block kế tiếp chuyển từ InputBuffer sang bộ nhớ tile;
- **xuất:** IDLE sau tile cuối.

Pha "nạp lại K-block" mới tách trong lần này; bản trước gộp nó vào "xuất". Bảng công suất theo pha ở mục 3.2 vẫn dùng cách gộp cũ.

| Kích thước | Cấu hình | Nạp | Nạp weight (tile) | Tính | Nạp lại K-block | Xuất | Job |
|---|---|---|---|---|---|---|---|
| 64×64×64 (T) | 49 | 579 | 136 (4) | 646 | 66 | 169 | 1645 |
| 64×64×64 (F) | 47 | 197 | 136 (4) | 646 | 66 | 134 | 1226 |
| 8×32×544 (T) | 49 | 2723 | 578 (17) | 1801 | 0 | 179 | 5330 |
| 8×32×544 (F) | 47 | 1093 | 578 (17) | 1801 | 0 | 142 | 3661 |
| 16×992×32 (T) | 49 | 4001 | 1054 (31) | 3503 | 1020 | 27 | 9654 |
| 16×992×32 (F) | 47 | 1029 | 1054 (31) | 3503 | 1020 | 22 | 6675 |

AXI-Stream:
- 3 luồng (feature vào, weight vào, kết quả ra), mỗi luồng 256 bit (32 byte INT8) mỗi beat.
- Ở 50 MHz: 1,6 GB/s mỗi luồng; 3,2 GB/s cho hai luồng vào, 4,8 GB/s cho cả ba.
- AXI-Lite 32 bit, 4 thanh ghi cấu hình.

| Kích thước | Beat feature / weight / kết quả | Byte vào / ra mỗi job | Băng thông vào đạt được (T / F) |
|---|---|---|---|
| 64×64×64 | 128 / 128 / 128 | 8192 / 4096 | 0,249 / 0,334 GB/s |
| 8×32×544 | 8 / 544 / 136 | 17 664 / 4352 | 0,166 / 0,241 GB/s |
| 16×992×32 | 496 / 992 / 16 | 47 616 / 512 | 0,247 / 0,357 GB/s |

### 2.3 Giới hạn kiến trúc
1. **Các pha chạy nối tiếp, không chồng nhau.**
   - Nạp, nạp weight, tính, nạp lại K-block và xuất chạy lần lượt. Không có beat kết quả nào được nhận trong lúc tính (0 ở mọi kích thước).
   - Luồng vào của job sau không thể chạy trong lúc job trước đang tính.
2. **Đổ đầy pipeline cho mỗi tile.**
   - Mọi lần chạy RTL đều cho pha tính = số tile × (M + 97,5) chu kỳ.
   - Mỗi tile trả khoảng 97 chu kỳ đổ đầy và xả mảng 32×32 cho chỉ M hàng.
   - Với M = 64, riêng pha tính đã chỉ dùng 64 / 161,5 = 40 % PE.
3. **Nạp weight theo tile không chồng với tính:** 34 chu kỳ mỗi tile. PE đã có cặp thanh ghi `r_weight_shift` / `r_weight_value`, nhưng bộ điều khiển không dùng nó để nạp trước tile sau.
4. **Dung lượng bộ đệm:** mỗi job M·Kb ≤ 511, 32·Kb·Nb ≤ 1023, M·Nb ≤ 511 (ERRATA E1), và K ≤ 992. Ma trận lớn hơn phải chia thành nhiều job con, mỗi job con gửi lại toán hạng và trả lại chi phí cấu hình.
5. **M = 1 không dùng được** (ERRATA E2): host phải đệm lên 2 hàng.

### 2.4 Kích thước lớn và kiểu LLM (mô phỏng RTL)
Nguồn: `perf_rtl_shapes.csv`, `perf_rtl_subjobs.csv`; script `scripts/perf_rtl.py`, `run_system_paper.sh`; đồ thị `figures/roofline.*`, `figures/pe_utilisation.*`.
- Ma trận lớn hơn một job được host chia theo M và N thành các job con gần bằng nhau, chạy liền nhau. Tổng chu kỳ bằng tổng chu kỳ các job con.
- Mọi job đều có 0 lệch dữ liệu. Với các job rất ngắn, testbench báo OVERALL FAIL chỉ vì không kịp thấy cờ busy.

| Hình dạng | M×K×N | Số job con | GOPS (T / F) | Tỉ lệ dùng PE (T / F) | ops/byte AXIS |
|---|---|---|---|---|---|
| vuông | 128×128×128 | 2 | 17,24 / 23,43 | 16,8 / 22,9 % | 64,0 |
| vuông | 256×256×256 | 15 | 14,80 / 20,43 | 14,5 / 20,0 % | 56,9 |
| vuông | 512×512×512 | 272 | 9,38 / 13,27 | 9,2 / 13,0 % | 30,1 |
| attention Q·Kᵀ, 1 head (128 token, d 64) | 128×64×128 | 2 | 16,21 / 21,90 | 15,8 / 21,4 % | 51,2 |
| attention P·V, 1 head | 128×128×64 | 2 | 17,08 / 23,12 | 16,7 / 22,6 % | 51,2 |
| chiếu QKV/out, d_model 768, 128 token (prefill) | 128×768×768 | 168 | 5,95 / 8,57 | 5,8 / 8,4 % | 22,9 |
| FFN lên 768→3072, 128 token | 128×768×3072 | 672 | 5,95 / 8,57 | 5,8 / 8,4 % | 22,9 |
| chiếu, decode batch 8 | 8×768×768 | 24 | 2,70 / 3,95 | 2,6 / 3,9 % | 12,7 |
| chiếu, decode batch 1 (GEMV), đệm lên M = 2 | 1×768×768 | 24 | 0,34 / 0,51 | 0,3 / 0,5 % | 1,9 |

- Roofline: trần tính 102,4 GOPS; trần băng thông 4,8 GB/s × ops/byte. Mọi điểm nằm dưới cả hai trần nhiều lần. IP bị giới hạn bởi các pha nối tiếp và độ trễ đổ đầy mỗi tile (mục 2.3), không phải bởi băng thông.
- K > 992 (ví dụ d_model 4096) không chạy đúng được nếu không cộng dồn phần chia K ở host trước khi lượng tử hoá; phần cứng hiện không hỗ trợ.

### 2.5 Ước tính nếu chồng pha (double buffering) — ĐÂY LÀ ƯỚC TÍNH, không phải mô phỏng thiết kế đã sửa
Nguồn: `perf_overlap_estimate.csv`; script `scripts/perf_overlap.py`.

Cách ước tính:
- Lấy số chu kỳ từng pha mà RTL v1 thật sự tốn cho mỗi job con, ở chế độ (F).
- Từ đó tính thời gian mỗi job theo từng mô hình chồng pha, rồi cộng trên mọi job con. Ký hiệu:
  - L_stream = max(beat feature, beat weight);
  - L_xfer = phần còn lại của pha nạp; phần này vẫn nằm phía tính.

Các mô hình:
- **v1 nối tiếp:** C + L + W + P + R + D (đúng như đo).
- **chồng job:** max(C + L_stream, L_xfer + W + P + R, D). Job sau nạp và job trước xuất trong lúc job này tính.
- **+ nạp trước weight:** bỏ W ra khỏi phía tính.
- **cận trên, tile liền nhau:** max(C + L_stream, số tile × M + 97, D). Đổ đầy mảng chỉ một lần mỗi job.

Hai trường hợp bộ đệm:
- **SRAM hiện tại:** 80 macro chia đôi để làm ping-pong, mỗi job chỉ dùng tối đa 255 / 511 / 255 từ.
- **SRAM gấp đôi:** mỗi nửa ping-pong bằng bộ đệm hiện nay, 511 / 1023 / 511 từ.

| Hình dạng | v1 nối tiếp (F) | Chồng job, SRAM hiện tại | Chồng job, SRAM gấp đôi | + nạp trước weight, SRAM gấp đôi | Cận trên: tile liền nhau, SRAM gấp đôi |
|---|---|---|---|---|---|
| 64×64×64 | 20,9 % | 27,9 % | 27,9 % | 32,8 % | 72,5 % |
| 8×32×544 | 3,7 % | 4,6 % | 4,6 % | 5,8 % | 23,0 % |
| 16×992×32 | 7,4 % | không vừa (K > 480) | 8,8 % | 10,9 % | 47,7 % |
| 128×128×128 | 22,9 % | 20,6 % | 28,0 % | 32,9 % | 91,4 % |
| 256×256×256 | 20,0 % | 14,7 % | 23,7 % | 28,2 % | 91,8 % |
| 512×512×512 | 13,0 % | không vừa | 15,4 % | 18,7 % | 83,2 % |
| chiếu d 768, prefill 128 | 8,4 % | không vừa | 10,0 % | 12,2 % | 53,9 % |
| decode batch 8 | 3,9 % | không vừa | 4,6 % | 5,8 % | 23,6 % |

- Chỉ chồng job thì tỉ lệ dùng PE tăng ít (khoảng 1,2–1,4 lần). Phần lớn thời gian nằm ở phía tính, do mỗi tile trả độ trễ đổ đầy pipeline.
- Ping-pong trong SRAM hiện tại còn làm job nhỏ đi, nên có hình dạng chậm hơn v1 (128³: 20,6 so với 22,9 %). Với K > 480, job không còn vừa bộ đệm.
- Muốn lên 50–90 % thì phải cho các tile chạy liền nhau, tức nạp trước weight và không xả mảng giữa các tile, và có bộ đệm đủ lớn. Đây là hướng cho v2.

## 3. Công suất và năng lượng cả job (TT 25 °C 1,80 V, SPEF RC nom, 50 MHz)
Nguồn: `energy_job_50MHz.csv`, `power_by_phase_50MHz.csv`, `power/job_*/` (`*.groups.txt`, `*.design.rpt`, `*.phases.csv`, `*.sram.csv`); script `scripts/job_power.sh`, `vcd_job_ip.py`, `vcd2act_phases.py`, `power_phases.tcl`, `job_energy.py`.

Cách làm:
- GLS trên netlist cuối (unit delay), dump VCD mọi net ở độ sâu 1 của top, 32 row và AXI;
- cửa sổ là **toàn bộ job 2**, từ JOB_START tới RESULT_ACCEPT cuối;
- mỗi chu kỳ gắn với một pha (mục 2.2); toggle đếm riêng theo pha; duty lấy theo cả job và dùng chung cho mọi pha;
- `report_power` của OpenSTA cho cả job và cho từng pha, với netlist và SPEF của từng macro;
- VCD 541 / 1252 / 2510 MB, mỗi lúc một file, xoá ngay sau khi tính.

### 3.1 Cả job
| Kích thước | Chu kỳ | Công suất (mW) | Năng lượng / GEMM (µJ) | pJ/MAC | GOPS | GOPS/W | Cận dưới SRAM: mW / µJ / pJ/MAC / GOPS/W |
|---|---|---|---|---|---|---|---|
| 64×64×64 | 1645 | **745,1** | **24,51** | **93,5** | 15,94 | **21,4** | 626,1 / 20,60 / 78,6 / 25,5 |
| 8×32×544 | 5330 | 751,0 | 80,06 | 574,9 | 2,61 | 3,5 | 622,8 / 66,39 / 476,7 / 4,2 |
| 16×992×32 | 9654 | 753,5 | 145,48 | 286,4 | 5,26 | 7,0 | 626,5 / 120,96 / 238,1 / 8,4 |

- Tổng năng lượng theo từng pha khớp với số cả job: 24,54 / 80,55 / 145,31 µJ.
- Đỉnh 102,4 GOPS chia cho công suất cho 136–137 GOPS/W. Đây chỉ là cận trên lý thuyết, không đạt được (mục 2.3).
- Theo khối, cả job 64×64×64: SRAM 224,0; 32 row 376,5; cell ở top 141,7; AXI 2,8 mW. Cây clock (top + row + AXI) chiếm 199,6 mW trong đó.
- Vectorless (hoạt động mặc định của OpenSTA) cho 1377,6 mW; chỉ là số tham khảo.

### 3.2 Theo pha (mW)
| Kích thước | Cấu hình | Nạp | Nạp weight | Tính | Xuất (gồm cả nạp lại K-block) | Cả job |
|---|---|---|---|---|---|---|
| 64×64×64 | 712,8 | 715,8 | 717,7 | **785,5** | 734,8 | 745,1 |
| 8×32×544 | 754,8 | 755,6 | 754,2 | 755,9 | 756,8 | 751,0 |
| 16×992×32 | 746,2 | 747,9 | 746,9 | 761,2 | 747,4 | 753,5 |

- Công suất gần như không đổi giữa các pha. Khoảng 650 mW (SRAM theo lib 224, chân clock của flop, cây clock) chạy theo clock chứ không theo dữ liệu, vì row không có clock gating.
- Chênh lệch lớn nhất là ở 64×64×64: pha tính cao hơn pha cấu hình 73 mW (row 406 so với 357 mW; cell ở top 152 so với 129 mW).
- Các số "cả job" của 8×32×544 và 16×992×32 hơi khác trung bình có trọng số của các pha, vì duty dùng chung; độ chênh dưới 1 %.

### 3.3 Leakage theo khối, 3 corner
Nguồn: `leakage_by_block_3corners.csv`; script `scripts/leak_blocks.sh`, `leak_blocks.tcl`, `leak_blocks.py`. Mỗi khối chạy riêng với netlist và SPEF của nó, cell chuẩn ở đúng corner; SRAM dùng lib TT ở mọi corner. Top chạy với row/AXI dưới dạng lib trừu tượng.

| Corner | Cell ở top | 32 row | Vỏ AXI | SRAM (lib TT) | Tổng |
|---|---|---|---|---|---|
| tt_025C_1v80 | 0,0026 | 0,0040 | 0,0001 | 2,836 | **2,843 mW** |
| ff_n40C_1v95 | 0,0049 | 0,0080 | 0,0002 | 2,836 | **2,849 mW** |
| ss_100C_1v60 | 1,022 | 4,494 | 0,067 | 2,836 | **8,420 mW** |

- Cột cell đã gồm filler/decap/tap; phần này chỉ 0,001–0,002 mW. Một row: 0,13 µW (TT), 0,14 mW (SS).
- Tổng khớp với bản chạy phân cấp trước (`leakage_3corners.csv`: 2,843 / 2,849 / 8,415 mW).

### 3.4 SRAM: số chu kỳ được chọn, khoảng công suất
Nguồn: `sram_range_50MHz.csv`, `power/job_*/job_*.sram.csv`; script `scripts/sram_range.py`.
- Lấy mẫu `csb0`/`csb1`/`web0` của từng macro ở cuối mỗi chu kỳ, đúng giá trị macro chốt ở cạnh clock.
- Lib tính 27,6 pJ mỗi cổng mỗi chu kỳ bất kể `csb`. Cận trên là số lib: 80 × 2 cổng × 27,6 pJ × 50 MHz + leakage = 223,8 mW.
- Cận dưới: chỉ những chu kỳ cổng được chọn mới tốn năng lượng đó.

| Kích thước | Cổng 0 được chọn (đều là ghi) | Cổng 1 (đọc) được chọn | SRAM cận dưới – cận trên |
|---|---|---|---|
| 64×64×64 | 13,3 % | 79,2 % | **105,0 – 223,8 mW** |
| 8×32×544 | 4,4 % | 79,7 % | 95,8 – 223,8 mW |
| 16×992×32 | 5,2 % | 80,0 % | 97,0 – 223,8 mW |

- Cổng đọc của 64 trong 80 macro được chọn ở mọi chu kỳ, vì RTL để read enable luôn bằng 1 ("read every cycle"). Vì vậy cận dưới vẫn khoảng 100 mW, và đó là một chỗ có thể tiết kiệm trong thiết kế.

### 3.5 Phần chạy theo clock và phần theo dữ liệu (căn cứ cho clock gating ở v2)
Nguồn: `power_clock_vs_data_64.csv`, `power/job_64x64x64/job_64x64x64.clockonly.groups.txt`.

Cách đo:
- Chạy lại `report_power` của job 64×64×64 với cùng file activity, nhưng mọi chân driver không thuộc clock đặt toggle = 0; duty giữ nguyên.
- Chân clock được giữ toggle là `clkbuf_*`, `clkload*`, `eco_clk_*` và GCLK của ICG.
- Kết quả là công suất do riêng clock gây ra (sàn); phần theo dữ liệu = cả job − sàn.

| Phần | Cả job (mW) | Chỉ clock (mW) | Theo dữ liệu (mW) |
|---|---|---|---|
| cây clock (top + row + AXI) | 199,6 | 199,6 | 0 |
| flop trong 32 row | 193,6 | 183,4 | 10,2 |
| flop ở top | 52,9 | 44,5 | 8,3 |
| flop trong AXI | 1,0 | 0,8 | 0,3 |
| logic tổ hợp trong row | 52,1 | 42,5 | 9,7 |
| logic tổ hợp ở top | 21,2 | 16,6 | 4,6 |
| logic tổ hợp trong AXI | 0,6 | 0,4 | 0,2 |
| SRAM (lib: năng lượng theo cạnh clock) | 224,0 | 224,0 | 0 |
| **Tổng** | **745,1** | **711,8 (95,5 %)** | **33,2 (4,5 %)** |

- Ở 50 MHz, **95 % công suất chạy theo clock, không theo dữ liệu.**
  - Cây clock: 200 mW.
  - Chân clock của flop: khoảng 228 mW (183 trong row + 45 ở top).
  - SRAM theo lib: 224 mW. Nếu lấy cận dưới theo số chu kỳ được chọn thì còn khoảng 105 mW (mục 3.4).
- Phần "logic tổ hợp" vẫn còn khoảng 59 mW khi toggle dữ liệu bằng 0. Đó là các cell nằm trên mạng clock nhưng không mang tên `clkbuf_*`, và công suất internal phụ thuộc duty. Chưa tách chi tiết hơn.
- **Căn cứ cho clock gating ở v2:**
  - Row không có clock gating. Trong job 64×64×64, mảng PE chỉ làm việc 40 % số chu kỳ (tính 646/1645), và ngồi không suốt cấu hình, nạp và xuất.
  - Chặn clock của 32 row ngoài lúc tính, kể cả nhánh cây clock của row, có thể bớt tối đa khoảng 60 % × (183 + 131) ≈ 190 mW. Đây là ước tính bậc nhất, chưa trừ chi phí ICG.
  - Read enable của SRAM luôn bật (mục 3.4) là chỗ tiết kiệm thứ hai.

## 4. PE và row
Nguồn: `blocks_pe_row.csv`, `fmax_*.rpt`, `power/block_*`; script `scripts/block_sim_power.sh`, `block_fmax.tcl`, `sim/tb_block_rand.v`.
- **PE** được harden riêng bằng cấu hình `gemm_pe` của flow hiện tại (run `gemm_pe/runs/paper_pe`). DRC 0, LVS 0 lỗi, antenna 0.
- **Row** dùng run `row_v1`, chính là row nằm trong IP.
- **Mô phỏng:** dữ liệu ngẫu nhiên; netlist gate-level so với RTL từng chu kỳ (PE 1229 lần so, row 1198 lần so, 0 lệch); cửa sổ 1000 chu kỳ.
- **Công suất** đo ở TT, SPEF RC nom, clock đặt lại 20 ns. Đường này dùng `vcd2act_flat.py`, vốn đã xử lý alias, nên không bị lỗi ở mục "Thay đổi".
- **fmax** tính theo path flop→flop, SPEF RC nom, propagated clock, fmax = 1/(T − slack).

| | PE | Row (32 PE) |
|---|---|---|
| Diện tích | die 17 218 µm²; core 13 085 µm²; cell (tổng hợp) 6 604 µm² | die 468 800 µm²; cell 259 100 µm² |
| Flop | 82 (66 `dfxtp` + 16 `dfrtp`) | 2 616 |
| fmax TT / SS | 208,9 / 108,7 MHz | 172,3 / 90,2 MHz |
| Công suất ở 50 MHz, dữ liệu ngẫu nhiên | 0,666 mW | 22,13 mW |
| Năng lượng mỗi MAC | **13,3 pJ** | **13,8 pJ** |

- Trong IP, một row tiêu trung bình 11,8 mW cả job 64×64×64 và 12,7 mW ở pha tính, thấp hơn mức dữ liệu ngẫu nhiên.
- Năng lượng mỗi MAC của cả IP (79–575 pJ) cao hơn của PE nhiều, vì gồm SRAM, cây clock và thời gian PE không tính.

## 5. IR drop (tĩnh, TT, 50 MHz)
Nguồn: `irdrop_v2A_summary.csv`, `irdrop_v2B_summary.csv`, `irdrop_v2_by_class.csv`, `irdrop_ip_v2_summary.csv`, `irdrop_v2*_worst100.csv`, `irdrop_row.csv`, các log `irdrop_v2A.log`, `irdrop_v2B.log`, `irdrop_row.log`; script `scripts/ir_drop.tcl`, `ir_row.tcl`, `ir_map.py`.

### 5.1 Cả IP
- `analyze_power_grid` của OpenROAD trong OpenLane 1.0.2.
- Cell ở top: hoạt động VCD của pha tính, job 64×64×64. SRAM: lib OpenRAM.
- Row và vỏ AXI: công suất pha tính (12,69 mW mỗi row, 3,28 mW cho AXI), gắn vào bản sao lib dưới dạng `cell_leakage_power`, vì lib của hai macro này không có số công suất.
- Tổng công suất PSM dùng là 789 mW, khớp với 785,5 mW của mục 3.2.
- **Mô hình A:** bàn cờ bump mặc định của PSM (140 µm, 642 nguồn trên toàn core).
- **Mô hình B:** 406 nguồn ở hai đầu của 203 dải met5 là chân vccd1/vssd1 trong LEF của IP, tức dòng vào từ mép die. Đây là mô hình gần hơn với một IP được nối vào chip.

Tệ nhất theo loại instance (mỗi macro lấy giá trị lớn nhất trên mọi nút PSM của nó):

| Mô hình | Loại | VDD tệ nhất | VSS tệ nhất | VDD + VSS trên cùng một instance |
|---|---|---|---|---|
| A | macro row | 137,2 mV (row 0) | 153,7 mV (row 0) | 290,9 mV (row 0) |
| A | SRAM | 4,6 mV | 4,5 mV | 9,0 mV |
| A | cell ở top | 5,2 mV | 8,2 mV | 12,4 mV |
| B | macro row | **120,5 mV** (row 25) | **125,0 mV** (row 26) | **245,4 mV** (row 25: 120,5 + 124,9) |
| B | SRAM | 76,1 mV | 74,3 mV | 150,4 mV |
| B | cell ở top | 87,6 mV | 92,8 mV | 180,4 mV (`hold24927`) |

- Trung bình: A 1,65 / 1,58 mV; B 38,1 / 37,5 mV (vccd1 / vssd1).
- A dồn dòng của row vào chân macro, nên sụt áp tập trung ở góc row 0.
- B cho sụt áp lan rộng, lớn nhất ở giữa mảng row (ảnh `figures/irdrop_map_v2A.*`, `irdrop_map_v2B.*`).
- **Sửa so với bản trước:** bản trước ghi tại nút macro row theo B là 86,1 / 93,6 / 179,7 mV. Số đó sai, vì phép tính chỉ giữ nút cuối của mỗi macro. Số đúng là 120,5 / 125,0 / 245,4 mV.

### 5.2 Bên trong một row
- Chạy riêng `row_v1` với netlist và SPEF của nó, cùng hoạt động VCD của row 0 ở pha tính 64×64×64 (12,7 mW).
- Nguồn ở tâm mỗi dải met4 là chân vccd1 (4 dải) và vssd1 (4 dải) trong LEF của row; các dải cách nhau khoảng 876 µm.

| Lưới | Tệ nhất | Vị trí | Trung bình |
|---|---|---|---|
| vccd1 | **17,9 mV** | x 1765,6, y 13,6 µm (giữa hai dải) | 4,0 mV |
| vssd1 | **41,8 mV** | x 5,5, y 114,2 µm (mép trái; dải vssd1 đầu tiên ở x 882) | 6,1 mV |

Phần này cộng thêm vào mức sụt của lưới IP tại chân row.

### 5.3 Phép cộng ra điện áp tệ nhất, từng bước (mô hình B; A trong ngoặc)
| Bước | Đại lượng | mV | Vị trí |
|---|---|---|---|
| 1 | VDD tệ nhất ở mức IP, tại macro row | 120,5 (137,2) | row 25 (row 0) |
| 2 | VSS tệ nhất ở mức IP, tại macro row | 125,0 (153,7) | row 26 (row 0) |
| 3 | VDD + VSS trên **cùng một** row | 245,4 (290,9) | row 25 (row 0); hai giá trị là cực đại trên các nút của row đó, có thể không cùng nút |
| 4 | Bên trong row: VDD tệ nhất | 17,9 | x 1765,6 µm, gần mép dưới |
| 5 | Bên trong row: VSS tệ nhất | 41,8 | x 5,5 µm, mép trái, gần mép trên |
| 6 | Cộng bi quan 3 + 4 + 5 | **305,1 (350,6)** | giả định mọi điểm tệ nhất trùng nhau; thực tế bước 4 và 5 không cùng chỗ trong row |
| 7 | VDD − VSS còn lại | **1,495 V (1,449 V)** | |
| – | Chỉ phía VDD: 1 + 4 | 138,4 → còn 1,662 V (155,1 → 1,645 V) | |

- Lập luận của đề bài, 1,80 V − 139 mV = 1,66 V > 1,60 V, chỉ đúng khi tính riêng phía VDD.
- Tính cả độ nâng của VSS và giả định mọi điểm tệ nhất trùng nhau, cận bi quan là khoảng **1,50 V** (B), thấp hơn 1,60 V của corner SS.
- Báo cáo trước ghi 1,56 V vì dùng nhầm 179,7 mV ở bước 3.
- Ở TT, 25 °C, 1,50 V vẫn có thể nhanh hơn corner SS signoff (process SS, 1,60 V, 100 °C). Trường hợp process SS cộng thêm IR drop thì chưa được phân tích. Đây là phân tích tĩnh, chưa có IR động.

### 5.4 STA chỉ để báo: cell chuẩn ở ss_100C_1v40 (cận bi quan, không chấm)
Nguồn: `sta_ss140_summary.txt`; script `scripts/sta_ss140.sh`, `sta_ss140.tcl` (bản sao `scripts/sta6b.tcl` của signoff), `block_fmax.tcl`.
- 1,40 V tương ứng 400 mV sụt áp, lớn hơn cận bi quan 305 mV ở trên.
- Ở top, macro vẫn dùng lib duy nhất (typical) của chúng, nên chỉ path cell→cell là có nghĩa.

| Phần | ss_100C_1v60 (signoff) | ss_100C_1v40 |
|---|---|---|
| Top, setup cell→cell, RC nom | đạt | tệ nhất **−6,71 ns**, 302 / 19 486 endpoint âm |
| Top, setup cell→cell, RC max | đạt | tệ nhất **−7,09 ns**, 302 / 19 556 endpoint âm |
| Top, hold cell→cell | đạt | đạt (tệ nhất +1,83 ns) |
| Row, flop→flop (SPEF nom), fmax | 90,2 MHz | **62,4 MHz** (vẫn trên 50 MHz) |
| PE, flop→flop, fmax | 108,7 MHz | 75,8 MHz |
| Vỏ AXI, flop→flop, fmax | 166,2 MHz | 117,2 MHz |

- Ở 1,40 V, đường dữ liệu bên trong row vẫn đạt 50 MHz.
- Logic điều khiển ở top thì không đạt. Path tệ nhất đi từ bộ đếm `u_input_buffer.r_weight_write_count` của InputBuffer qua logic cấu hình; có 89 endpoint chung một điểm đầu. Chưa phân tích chi tiết các path này.
- Như vậy, nếu sụt áp thật tiến gần cận bi quan ở các vùng có logic điều khiển, biên timing ở corner SS là không đủ. Kết luận này chỉ để báo, không thay đổi kết quả signoff.

## 6. Ảnh
| File | Nội dung |
|---|---|
| `figures/layout/chip_full.png` | KLayout, cả chip (độ sâu phân cấp 1) |
| `figures/layout/chip_blocks.png/.pdf` | cả chip, tô màu theo khối: SRAM, row, AXI, logic ở top, buffer hold, diode, cây clock (cell chuẩn vẽ rộng thêm 3 µm để thấy được; filler/decap/tap không vẽ). Script `scripts/block_maps.py` |
| `figures/layout/row_pe_map.png/.pdf` | một row, cell tô theo chỉ số PE, chỉ vẽ khung cell, không có dây |
| `figures/layout/row_pe_map_zoom_pe0_3.png/.pdf` | như trên, phóng to 4 PE đầu |
| `figures/layout/pe_about_one.png` | 110 µm đầu của row 0, khoảng 1 PE |
| `figures/layout/sram_macro.png` | một SRAM (`u_feature_tile_mem g_bank[0].g_lane[0]`) |
| `figures/layout/eco_clk_20.png` | vùng clkbuf ECO `eco_clk_20` |
| `figures/openroad/ip.layout.png` | OpenROAD, cả chip |
| `figures/openroad/ip.clocktree.png` | cây clock `S_AXI_ACLK` (trình xem cây clock của OpenROAD) |
| `figures/placement_density.*` | mật độ đặt cell, ô 10 µm (dữ liệu `ip.heatmap_Placement.csv.gz`) |
| `figures/routing_utilisation.*` | mật độ dây sau route theo lớp, ô 50 µm |
| `figures/irdrop_map_v2A.*`, `irdrop_map_v2B.*` | bản đồ IR drop vccd1 và vssd1, mô hình A và B |

- Ảnh row tô theo PE: row đã phẳng và tên instance là tên chung (`_12345_`, `holdN`), nên **chỉ số PE lấy từ tên net**, vì net còn giữ phân cấp `g_pe_column[k].u_processing_element.*`.
  - 9 710 cell nằm trực tiếp trên net như vậy.
  - Cell còn lại lấy chỉ số PE chiếm đa số của các cell chung net với nó (net có fanout ≤ 16), lặp đến khi không đổi. Kết quả: 24 351 / 24 581 cell logic có chỉ số.
  - Cell màu xám là cây clock, logic dùng chung, filler, tap và diode.
- Heatmap kẹt dây của OpenROAD không có: bản này không có RUDY, còn heatmap Routing cần dữ liệu global route. Thay vào đó dùng mật độ dây thật sau route.

## 7. Đồ thị (CSV + `scripts/plots.py`, `scripts/plots_perf.py`, PNG và PDF)
| Hình | Dữ liệu | Nội dung |
|---|---|---|
| `antenna_convergence` | `antenna_convergence.csv` | ECO route lại toàn bộ (OL1, ip_v3r: 1133 → 446 → 293, trong đó 266 chân mới; mỗi vòng route lại 100 % net) so với ECO tăng dần (446 → 37 → 6 → 3 → 1 → 0; mỗi vòng route lại 0,60 / 0,04 / 0,01 / 0,01 / 0,003 % net). Thời gian mỗi vòng: OL1 1749–5458 s, tăng dần 993–1089 s |
| `drv_by_eco_round` | `drv_by_eco_round.csv` | Net cell chuẩn vượt lib ở TT nom và SS max, qua từng lượt ECO: 435/1673 → 0/0 |
| `sram_clk_slew` | `sram_clk_slew_before_after.csv` | Slew chân clock SRAM. Trước khi sửa clock (layout a2): TT max 3,83 ns, 43 chân > 0,75 ns. Sau: TT max 0,739 ns, SS max 0,998 ns |
| `slack_histograms` | `slack_histogram_final.csv` | Histogram slack setup/hold của layout cuối, TT/FF/SS × RC max, theo loại path |
| `cap_ratio_rcx_grt` | `cap_ratio_rcx_grt.csv` | Điện dung RCX (max) so với ước lượng sau global route trên 85 net dài: 1,54–2,71 lần, trung vị 2,05 |
| `roofline` | `perf_rtl_shapes.csv` | Roofline: trần 102,4 GOPS và 4,8 GB/s (đường chấm: 3,2 GB/s chỉ tính luồng vào); điểm của 12 hình dạng, testbench gốc và full-rate |
| `pe_utilisation` | `perf_rtl_shapes.csv` | Tỉ lệ dùng PE theo hình dạng, và phần chu kỳ theo pha (full-rate) |

Ghi chú về số chân antenna của ip_v3r: báo cáo vòng 2 có 294 dòng nhưng chỉ 293 chân khác nhau, và 266 chân trong đó không có ở vòng 1. Đồ thị dùng số chân khác nhau.

## 8. Kiểm tương đương hình thức PE
Nguồn: `pe_equiv2_yosys062.log`, `pe_equiv2_yosys030.log` (bản mới), `pe_equiv.log` (bản cũ); script `scripts/pe_equiv2.ys`, `pe_equiv.ys`.
- **Đối tượng:** RTL `rtl_asic/PE.v` (P_DATAPATH_RESET = 0, như trong flow) so với netlist cuối của PE đã harden. Mô hình cell lấy từ liberty TT.
- **Số flop hai bên bằng nhau, 82 = 82.**
  - Có reset: `r_weight_shift` 8 và `r_weight_value` 8.
  - Không reset: `r_product` 16, `r_partial_sum_d1` 21, `o_partial_sum` 21, `o_feature_value` 8.
  - Bản trước so 82 flop của netlist với 66 flop không reset của RTL, nên kết luận sai rằng có flop thừa.
- **Lý do lần đầu không ghép được:** netlist tách bus thành dây một bit tên `\r_product[3] `, còn RTL giữ bus `r_product`. Ngoài ra 37 flop nối ra cổng qua buffer đầu ra, nên Q của chúng mang tên `netNN`.
- **Cách mới:** `splitnets` cho RTL để tên trùng với netlist, rồi `equiv_make` ghép:
  - 45 bit thanh ghi trong (`r_product`, `r_partial_sum_d1`, `r_weight_value`);
  - 37 bit đầu ra (`o_partial_sum`, `o_feature_value`, `o_weight_shift_out` = `r_weight_shift`);
  - 16 bit `w_product`.

  Sau đó chạy `equiv_simple -seq 5` và `equiv_induct -seq 5`.
- **Kết quả:** 98/98 ô `$equiv` đã chứng minh, `equiv_status -assert` đạt, trên cả Yosys 0.62 (image LibreLane, có eqy và sby nhưng không cần) và Yosys 0.30 (OpenLane 1.0.2).
- **Kết luận:** netlist PE tương đương tuần tự với RTL. Điều kiện là các thanh ghi tương ứng xuất phát cùng giá trị: thanh ghi có reset thì sau reset; thanh ghi dữ liệu không reset thì giả định trạng thái đầu giống nhau, như mọi phép ghép thanh ghi.
- Mô phỏng ngẫu nhiên ở mục 4 cũng không thấy lệch nào giữa netlist và RTL của PE và row.

## 9. ERRATA của IP v1 và bản FPGA
Nguồn: `errata_rtl_tests.txt` (`sim/run_errata.sh` của repo), `gls_errata.txt` (script `scripts/gls_errata.sh`), vết mô phỏng `errata_trace_M1_1x32x32.txt`, `errata_trace_M2_2x32x32.txt` (module `sim/errata_trace_mon.v`). RTL và layout của v1 không sửa. Nội dung ERRATA (nguyên nhân theo file:dòng, điều kiện xảy ra, ràng buộc cho host) giống mục ERRATA trong README, HUONGDAN và `docs/TIEN_DO_SIGNOFF.md`.

### 9.1 Test có chủ đích trên RTL (cấu hình đã build: asic-sram, WRAP=lean, AXIS_CG=1)
| Ca | M,K,N | Từ feature / weight / kết quả | Kết quả |
|---|---|---|---|
| M1 | 1,32,32 | 1 / 32 / 1 | SAI: thừa beat, 99 dòng FAIL |
| M1_K2 | 1,64,32 | 2 / 64 / 1 | SAI: sai giá trị, 124 dòng FAIL |
| M2 | 2,32,32 | 2 / 32 / 2 | đúng |
| M2_K2 | 2,64,32 | 4 / 64 / 2 | đúng |
| F511 | 73,224,32 | **511** / 224 / 73 | đúng |
| F512 | 256,64,32 | **512** / 64 / 256 | TREO: nhận 1 / 512 beat feature |
| W992 | 2,992,32 | 62 / **992** / 2 | đúng (weight lớn nhất hợp lệ là 992, vì luôn là bội của 32) |
| W1024 | 2,512,64 | 32 / **1024** / 4 | TREO: nhận 1 / 1024 beat weight |
| O511 | 511,32,32 | 511 / 32 / **511** | đúng |
| O512 | 256,32,64 | 256 / 64 / **512** | SAI: 580 beat thay vì 512, sai giá trị |
| 128³ chia làm 2 job | 64,128,128 | 256 / 512 / 256 | đúng (mỗi nửa của 128×128×128 là một job như vậy) |

### 9.2 GLS trên netlist cuối
Netlist cuối (`final_a5`, unit delay, row và AXI cũng ở mức gate) so với RTL của cùng hình dạng. So từng dòng về dữ liệu và thời điểm: các dòng ACCEPT, RESULT_VALID_FIRST, FAIL, ma trận kết quả in ra, số lệch và số beat.

| Ca | Thời gian GLS | Số dòng so | GLS so với RTL | Dòng FAIL (GLS / RTL) |
|---|---|---|---|---|
| M1 (1,32,32) | 103 s | 234 | **giống hệt** | 99 / 99 (lỗi E2 có cả trong netlist) |
| M2 (2,32,32) | 120 s | 123 | **giống hệt** | 2 / 2 (chỉ là dòng kiểm cờ busy của testbench; dữ liệu đúng) |
| F511 (73,224,32) | 592 s | 1809 | **giống hệt** | 0 / 0 |

Không chạy GLS cho các ca treo (F512, W1024), vì testbench chỉ dừng sau 180 000 chu kỳ. O512 cũng chưa chạy GLS.

### 9.3 Bản FPGA (`GEMM_32x32_KV260-main`, chỉ đọc, không build)
- **E2 (M = 1): cùng nguồn gốc.** RTL FPGA có đúng các dòng gây lỗi:
  - `rtl/Buffer_feeder.v:104` (`input_feature_last = feature_cnt == row_count − 1`);
  - `rtl/Buffer_feeder.v:125` (đưa cờ đó ra `r_compute_input_last`);
  - `rtl/Gemm_compute_core.v:160` (pipeline `last` không kèm valid);
  - `rtl/In_buffer.v:217-218` (`r_feature_read_row`).

  Bản ASIC chỉ thay bộ nhớ, không đổi logic này. Chưa thử trên board.
- **E1 (dung lượng): cùng kiểu mã, nhưng không xảy ra với cấu hình FPGA.**
  - Bộ đếm cũng rộng log2(depth) bit (`rtl/In_buffer.v:64-65`, `:100`, `:111`; `rtl/Out_buffer.v:37`, `:266`).
  - Bản FPGA dùng độ sâu mặc định 2400 (`rtl/GEMM_top.v:10-12`; block design không ghi đè). Bộ đếm vì vậy 12 bit, chỉ quay vòng ở 4096, trong khi driver giới hạn mỗi bộ đệm ≤ 2400 từ.
  - Lỗi chỉ lộ ra ở bản ASIC, vì ở đó chọn độ sâu luỹ thừa 2 (512 / 1024 / 512).
- **Driver và host (llama.cpp):**
  - `software/ggml-cpu/ggml-cpu.c:1316` cho phép `M >= 1`. `software/FPGA/FPGA_GEMM.cpp` (`fpga_gemm_run`, dòng 535–562) chỉ kiểm M ≤ 511, Kb và Nb ≤ 31, và số từ ≤ 2400.
  - Không có chỗ nào đệm M = 1 lên 2 hàng, cũng không có chỗ nào chuyển GEMV sang CPU. Vì vậy lúc decode (ne11 = 1) phép nhân sẽ được gửi sang FPGA với row_count = 1.
  - Theo phân tích RTL ở trên, kết quả khi đó sẽ sai. Chưa kiểm trên board.
  - Ma trận có K > 992 (Kb > 31) thì rơi về CPU.
- **Kết luận:** chưa sửa gì. Cần quyết định có đệm M = 1 trong driver (hoặc chuyển sang CPU) và có kiểm lại trên board không.

## 10. Tái lập
Nguồn: `reproducibility.csv` (thời gian và RAM từng bước), `machine.csv` (máy, image, phiên bản), `final/TOOLS.txt`, `final/MANIFEST`.
- **Máy:** Intel i7-14700HX (28 luồng), 15 GiB RAM cùng 32 GiB swap, AlmaLinux 10.2, Docker 29.8.2. Mọi container giới hạn 10g/40g.
- **Image OpenLane 1.0.2:** `sha256:832662c8…779a`; OpenROAD 41a51eaf, Magic 8.3.413, Netgen 1.5.255, KLayout 0.28.2, Yosys 0.30+48, OpenSTA 2.4.0.
- **Image ECO:** LibreLane 3.0.16 `sha256:4bc9042b…5051` (OpenROAD dcf36133; Yosys 0.62, eqy, sby).
- **PDK:** open_pdks 0fe599b2. Icarus Verilog 13.0. matplotlib 3.9.2 trong `paper/.venv`.
- **GDS cuối:** `final/GEMM_top.gds`, sha256 `87286b9408d1a706d1f47a2925317ed5ed702c0700b780edbdda0a22e8b068fa`.
- **Repo:** nhánh `eco-signoff-wip`; script ECO ở `tools/eco`, gói này ở `docs/paper`.
