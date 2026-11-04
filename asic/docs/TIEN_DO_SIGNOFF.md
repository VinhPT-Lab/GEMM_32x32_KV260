# Tiến độ signoff IP gemm_ip

**Trạng thái: signoff xong** (ngày 20/10/2026) cho layout ECO cuối, theo đúng chính sách bên dưới. Mọi con số trong tài liệu này là của layout cuối, đo bằng công cụ của OpenLane 1.0.2.

## Mục tiêu và chính sách

IP `gemm_ip` gồm core GEMM 32x32 và vỏ AXI, chạy 50 MHz (chu kỳ 20 ns) ở corner TT. Layout gốc là run `ip_v3r` của OpenLane 1.0.2, với vòng route 1 được giữ lại.

Một layout được coi là signoff khi đạt đủ các điều kiện sau:
- **Antenna:** ARC báo 0 chân.
- **DRC:** router 0 lỗi; Magic 0 lỗi thật. Cờ Magic cạnh macro được kiểm lại trên GDS đầy đủ bằng `magic_macro_check.sh`.
- **LVS:** khớp hoàn toàn.
- **Mô phỏng gate-level:** PASS ở cả 3 kích thước ma trận.
- **Clock:** slew tại chân clock SRAM và `S_AXI_ACLK` ≤ 0,75 ns ở TT (RC nom) và ≤ 1,0 ns ở SS (RC max).
- **Timing**, tính bằng lib của mọi macro, propagated clock và SPEF signoff:
  - TT: setup và hold ≥ 0 cho mọi path nội bộ;
  - FF (RC min và max): hold ≥ 0 cho mọi path nội bộ, kể cả path chạm macro;
  - SS: hold ≥ 0 cho path nội bộ. Setup ở SS chỉ báo kèm, để biết fmax;
  - path I/O: báo riêng ở mọi corner, không dùng để đánh trượt IP.
- **DRV:** không net nào vượt giới hạn của lib (mức của SDC chặt hơn và chỉ được báo số lượng).

## Vì sao phải ECO bằng OpenROAD mới

OpenLane 1.0.2 không có detailed route tăng dần. `repair_antennas` của nó chỉ chạy trên kết quả global route, nên mỗi vòng ECO antenna phải route lại cả chip. Mỗi lần route lại như vậy lại sinh vi phạm mới. Ở `ip_v3r`:

| Vòng ECO | Antenna (chân) | Ghi chú |
|---|---|---|
| 0 | 1136 | |
| 1 | 446 | vòng được giữ |
| 2 | 293 | 266 chân là chân mới, không có ở vòng 1; thêm 1 lỗi DRT Metal Spacing cạnh một SRAM |

Vì vậy, ECO được làm bằng OpenROAD trong image LibreLane 3.0.16 (OpenROAD `dcf36133`). Bản này giữ nguyên các net còn dây và chỉ route những net bị sửa. Sau đó DEF được đưa về OpenLane 1.0.2 để kiểm lại bằng đúng công cụ và PDK cũ. Luồng làm và các script nằm ở `tools/eco/README.md`.

Để chạy được trên DEF, cần dựng lại route guide cho mọi net nhiều chân từ chính dây trong DEF, vì DEF không mang guide. Bước kiểm khớp đạt các điểm sau:
- đọc DEF rồi ghi lại cho ra file giống hệt từng byte;
- `check_antennas` của bản mới cho 450 chân, so với 446 chân của ARC trong OL1, trùng nhau 444 chân;
- ECO rỗng (không sửa gì) chỉ làm DRT mới tự sửa 3 chỗ Metal Spacing mà DRT của OL1 không báo, và Magic đã kiểm 3 chỗ đó sạch.

## Kết quả signoff

| Mục | Tiêu chí | Kết quả | Đạt |
|---|---|---|---|
| Antenna (ARC, OL1) | 0 chân | 0 | đạt |
| DRC router (DRT) | 0 | 0 | đạt |
| Magic DRC (cell chuẩn view đầy đủ) | 0 lỗi thật | COUNT 0 | đạt |
| `magic_macro_check.sh` | PASS | PASS | đạt |
| `spot_check.sh` (33 cửa sổ: 30 cell mới cách macro dưới 20 µm, `eco_clk_20`, 2 chỗ cũ) | 0 lỗi thật | 0 (lỗi còn lại đều do cắt ở mép cửa sổ, đã kiểm lại bằng cửa sổ nới rộng) | đạt |
| LVS (netgen) | khớp | Circuits match uniquely, 122 879 thiết bị, 151 960 net | đạt |
| KLayout XOR (GDS của Magic so với GDS của KLayout) | 0 khác biệt | 0 trên 52/52 lớp (6 lớp chế độ phẳng, 46 lớp chế độ tiling; 81/14 bỏ qua như flow) | đạt |
| Mô phỏng gate-level (64×64×64, 8×32×544, 16×992×32) | PASS | PASS; 258/274/34 sự kiện, trùng từng chu kỳ với RTL cùng cấu hình (SRAM, shell lean_cg) và với ip_v3r | đạt |
| Setup TT nội bộ | ≥ 0 | +1,428 ns (chạm macro, RC max); cell→cell +11,235 ns | đạt |
| Hold TT nội bộ | ≥ 0 | +0,319 ns | đạt |
| Hold FF nội bộ (RC min / nom / max) | ≥ 0 | +0,171 / +0,134 / +0,126 ns | đạt |
| Hold SS nội bộ | ≥ 0 | +0,231 ns | đạt |
| Endpoint nội bộ không ràng buộc | 0, trừ khi có giải thích | 1124, đều là hằng số (dưới đây); trùng với ip_v3r | đạt |
| DRV cell chuẩn, TT và SS, mọi RC | 0 net | 0 ở 9/9 corner | đạt |
| Slew chân clock SRAM (TT nom / SS max) | ≤ 0,75 / 1,0 ns | 0,739 / 0,998 ns | đạt |
| Slew `S_AXI_ACLK` (TT nom / SS max) | ≤ 0,75 / 1,0 ns | 0,469 / 0,673 ns | đạt |
| Mô hình timing của IP | có | `GEMM_top.tt.lib` (`write_timing_model` của OL1, TT, SPEF RC nom, propagated clock) | có |

Chỉ báo, không dùng để đánh trượt:
- Setup SS chạm macro (RC max): −4,944 ns, 1308 endpoint.
- Path I/O:
  - hold ở SS âm tại 607/905 endpoint, tệ nhất −4,041 ns (RC max);
  - setup SS RC max −0,431 ns (1 endpoint);
  - TT và FF không âm.
- SRAM dout vượt tải: 1 net ở FF RC max.

Endpoint không ràng buộc (1124, giống nhau ở mọi corner và giống hệt ip_v3r):
- 1088 chân do `conb_1` (hằng số) lái: `i_partial_sum_vector` của row đầu, `wmask`/`web`/`csb` của SRAM;
- 36 cổng ra `result_axis_tstrb[31:0]`, `S_AXI_BRESP`, `S_AXI_RRESP`. Chúng nối qua buffer đầu ra từ chân của AXI shell, mà các chân đó không có cung timing trong lib của shell (hằng số bên trong shell).

Hold I/O âm vì SDC coi clock bên ngoài là lý tưởng (độ trễ clock tới cổng bằng 0), trong khi bên trong IP độ trễ clock vào khoảng 6–7 ns. **Người tích hợp dùng `GEMM_top.tt.lib`** để tính phần I/O với clock thật của hệ thống.

Công suất ở 50 MHz (TT, SPEF RC nom) theo hoạt động từ GLS: 745,1 mW theo VCD cả job (64x64x64; 8x32x544: 751,0; 16x992x32: 753,5 mW; SRAM tính theo lib, là cận trên; nếu lấy SRAM cận dưới thì khoảng 623–626 mW). Ở 64x64x64: 15,9 GOPS hiệu dụng, 21,4 GOPS/W, 93,5 pJ/MAC (25,5 GOPS/W nếu lấy SRAM cận dưới); đỉnh 102,4 GOPS chia công suất đo là 137 GOPS/W (cận trên). Chi tiết và giới hạn: docs/paper/SUMMARY.md.

Số tham khảo, vectorless (activity mặc định của OpenSTA): 1377,6 mW (1,38 W). Phân theo nhóm:

| Nhóm | Công suất (mW) |
|---|---|
| Row | 759,0 |
| SRAM | 224,0 |
| Core | 386,2 |
| Vỏ AXI | 8,5 |

## ip_v3r so với layout cuối

| Mục | ip_v3r | Cuối |
|---|---|---|
| Antenna (ARC, OL1) | 446 chân | 0 |
| DRT | 0 | 0 |
| Magic DRC COUNT | 7 | 0 |
| LVS | khớp, 120 318 thiết bị | khớp, 122 879 thiết bị |
| Setup TT nội bộ, tệ nhất (RC max) | +1,025 ns | +1,428 ns |
| Hold FF nội bộ, tệ nhất (RC max) | **−0,056 ns** (1 path) | +0,126 ns |
| Hold SS nội bộ, tệ nhất | +0,194 ns | +0,231 ns |
| Setup SS cell→cell (RC max) | +0,484 ns | +1,216 ns |
| Setup SS chạm macro (RC max), chỉ báo | −5,416 ns, 1321 endpoint | −4,944 ns, 1308 endpoint |
| Hold I/O SS RC max, chỉ báo | −3,044 ns, 607 endpoint | −4,041 ns, 607 endpoint |
| DRV cell chuẩn (TT nom / TT max / SS max) | 435 / 535 / 1673 net | 0 / 0 / 0 |
| SRAM dout vượt tải (TT nom) | 539 net | 0 |
| SRAM addr/wmask slew (miễn trừ) | 1440 net | 1440 net |
| Mô phỏng gate-level | PASS | PASS, cùng từng chu kỳ |
| Công suất 50 MHz vectorless | 1375,4 mW | 1377,6 mW |
| Net có dây thay đổi so với ip_v3r | – | 6066 (4,15 % số net có dây) |
| Cell thêm | – | 2968: 1220 diode, 1742 buffer (47 clkbuf: 35 trên đường clock, 12 trên net dữ liệu), 6 dlygate |
| Cell bị xoá / đổi cỡ | – | 187 diode trên net clock / 794 cell đổi cỡ |

Hold âm duy nhất của ip_v3r nằm ở chân `csb1` của SRAM `weight_mem g_bank[0].g_lane[3]`, trên path từ `_56646_/Q`. Path này đã được sửa bằng một `dlygate4sd3_1` nối tiếp một `buf_4` sát chân, nên dlygate không lái thẳng chân SRAM.

Hold I/O ở SS tệ hơn ip_v3r vì độ trễ clock bên trong IP tăng thêm sau khi sửa slew của cây clock. Phần này chỉ báo và được tính bằng `GEMM_top.tt.lib`.

## Bản giao

Layout cuối là `s7E/a5.def` trong thư mục ECO. Các file giao nằm ở `$ECO_DIR/final/`, kèm `SHA256SUMS` và `TOOLS.txt` (phiên bản công cụ, digest image):
- GDS: `GEMM_top.gds`, 743 143 076 B, sha256 `87286b9408d1a706d1f47a2925317ed5ed702c0700b780edbdda0a22e8b068fa`. Không đưa lên git vì quá lớn.
- DEF, netlist thường và netlist có chân nguồn, SPEF min/nom/max, SDC, LEF, `GEMM_top.tt.lib`;
- báo cáo DRC, LVS, XOR, STA, GLS và công suất.

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

## Giới hạn cần biết

- **50 MHz chỉ đúng ở corner TT theo lib.** SRAM OpenRAM chỉ có lib TT, nên mọi corner đều dùng lib TT cho SRAM. Corner FF và SS chỉ đổi lib của cell chuẩn.
- **Thực tế đo trên silicon:** SRAM OpenRAM mới được đo chạy được khoảng 34–40 MHz. Con số 50 MHz là theo lib, chưa phải con số đã kiểm trên chip.
- **Không dùng để đánh trượt:** setup ở SS của các path chạm macro, và hold của path I/O, chỉ được báo kèm.
- **Miễn trừ slew ở chân addr/wmask của SRAM:** lib của SRAM chỉ được đặc tính tới slew 40 ps. Mọi chân addr/wmask đều vượt mức này, kể cả chân chỉ nối dây dài 13 µm, nên đây là giới hạn của lib chứ không phải lỗi thiết kế.
- **Hold I/O chỉ báo:** hold của path I/O âm ở SS vì SDC coi clock ngoài là lý tưởng; người tích hợp tính lại bằng `GEMM_top.tt.lib`.
- **Tỉ số RCX/GRT:** điện dung trích bằng RCX lớn hơn ước lượng sau global route khoảng 1,5–2,7 lần (trung vị 2,05) trên các net dài, nên mọi ước lượng trước khi route cần margin lớn.
- **Con số 100 MHz cũ của `core_v11`** chưa kiểm các path đi qua macro; khi kiểm đủ, fmax ở TT chỉ khoảng 53 MHz. Con số khoảng 57 MHz ở corner chậm của core_v11 cũng chưa kiểm path qua macro. Các con số 204,8 GOPS, 134 GOPS/W và 1,53 W của core_v11 là giả định 100 MHz.
- **Antenna:** core_v11 chạy riêng còn 219 chân; IP gemm_ip về 0 nhờ ECO tăng dần (`tools/eco`).
