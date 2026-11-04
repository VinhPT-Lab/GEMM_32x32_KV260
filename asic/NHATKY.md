# Nhật ký các lần chạy

Run nằm ở ~/OpenLane/designs/<design>/runs/<tag>. Thời gian là thời gian OpenLane báo trong metrics.csv.

## PE, row, array

| Run | Thay đổi | Kết quả |
|---|---|---|
| pe_v1 | Một PE, đo diện tích để tính kích thước row | PASS, 6604 um², 2 phút |
| row_v1 | 32 PE, macro 3517,6 x 133,3 um, chặn met1-met4, chân trên/dưới thẳng hàng | PASS, 27 phút. Bản đầu có lỗi chức năng do resizer (xem mục cuối); chạy lại 04/10 với -skip_pin_swap |
| array_v1 | FeatureSkew + 32 row + OutputDeskew | PASS sau 10 lần chạy, 3h14m, 19,9 mm², timing I/O miễn |

## Core (GemmAccelerator: 32 row + 80 SRAM)

| Run | Thay đổi | Kết quả |
|---|---|---|
| core_v1 | Floorplan đầu: SRAM gom thành khối | Global route crash (FastRoute gặp đường vòng quá dài vì nghẽn) |
| core_v1r | Route lại từ sau CTS | Vẫn nghẽn, khoảng 390 nghìn cạnh gcell tràn. Chuỗi FeatureSkew/OutputDeskew phải vắt qua macro |
| (layout v2, v3) | Đặt mỗi SRAM cạnh logic dùng nó; vùng B dưới chồng row | Thử bằng core-probe, không có run riêng |
| core_v4 | Layout v3, SYNTH_BUFFERING 0 (ABC dựng cây buffer không biết vị trí) | Overflow từ 321 nghìn xuống khoảng 6,8 nghìn; 9,5 nghìn short ở DRT do cell kẹt giữa các row |
| core_v5 | Nới dải FeatureSkew 320 lên 1000 um | Không đổi |
| core_v6 | keep_rows_clear.tcl đẩy cell ra khỏi khe giữa row; die 7,06 x 10,24 mm | Overflow 575, DRT còn 1 short met5; LVS chạy 7 giờ vì short |
| core_v6r | Route lại với seed 7, 23, 101 | Cả 3 seed ra cùng short met5 trên SRAM: lỗi hình học, không phải do seed. Setup -1,24 ns ở RightShifter |
| core_v7 | RightShifter viết lại (bỏ bộ cộng 32 bit khỏi đường dữ liệu); cấm met5 trên SRAM; met1 giữ 50 % dung lượng | Dừng giữa DRT để thêm Magic DRC đọc layout đầy đủ của cell chuẩn |
| core_v7r | Route lại từ sau CTS của v7 | Short met5 hết, setup nội bộ sạch, hold -0,01. DRT 23 lỗi: một net phải băng qua SRAM mà không còn lớp nào |
| core_v8 | Tắt diode heuristic | Overflow 46 (v7r: 515), không net nào xuyên macro. Dừng sau global route để thêm dữ liệu antenna cho SRAM |
| core_v9 | LEF SRAM có ANTENNAGATEAREA / ANTENNADIFFAREA; 3 vòng ECO antenna | DRT 0, LVS khớp, setup/hold nội bộ sạch ở typical (+1,01 / +0,11), còn 209 net antenna, Magic 47 cờ giả quanh macro. 7h02m, RAM 13,0 GB |
| core_v10 | Hold margin 0.7, GRT_ANT_MARGIN 50 | Hold sạch mọi corner, nhưng setup typical -0,06 ns, corner chậm tệ thêm 1,4 ns; antenna 219 net. Giữ v9 |
| core_v11 | Cấu hình v9, row_v1 chạy lại (không còn đổi chân) | DRT 0, LVS khớp, setup/hold nội bộ sạch ở typical (+1,21 / +0,27), hold sạch mọi corner, 205 net antenna. 9h26m, RAM 13,5 GB |

Các kiểm tra thêm vào flow trong quá trình này:

- Thử nhiều seed DRT trong một run, giữ lần ít lỗi nhất; route còn lỗi thì bỏ LVS.
- macro_cross.py sau global route: dừng nếu có net đi xuyên lòng macro hơn 50 um.
- magic_macro_check.sh: cờ Magic quanh macro (do view abstract) được kiểm lại trên GDS đầy đủ.
- need_disk: dừng trước khi chạy nếu ổ còn dưới 40 GB (core_v7r từng chết vì hết ổ).

## Timing nhiều corner của core_v9

| Corner | Path nội bộ |
|---|---|
| tt/25°C/1,80V | setup +1,01 ns, hold +0,11 ns |
| ss/100°C/1,60V, RC max | setup -7,46 ns, chu kỳ tối thiểu khoảng 17,5 ns |
| ss/100°C/1,60V, RC min | setup -6,29 ns |
| ff/-40°C/1,95V, RC min | hold sạch |
| ff/-40°C/1,95V, RC max | hold -0,12 ns, 1 path trong delay line OutputDeskew |

## Lỗi chức năng trong row_v1 (phát hiện 04/10)

GLS của core trước đây mô phỏng row bằng RTL nên không thấy. Khi mô phỏng với netlist gate-level của row,
cột 23 của kết quả sai. So một row RTL với netlist bằng kích thích ngẫu nhiên (sim/row_equiv.sh) thấy chỉ PE 23
sai, ở bit 12-15 của tích.

Chia theo từng bước của row_v1: netlist sau CTS và sau bước 15 đúng, sau bước 17 (resizer timing sau global
route) sai. Log bước đó có "Swapped pins on 1 instances": repair_timing đổi chỗ chân A_N và B của một cell
and2b_1, mà cell này không giao hoán. LVS vẫn khớp vì layout khớp với netlist đã sai.

Cả 32 row của core_v9 và core_v10 là cùng macro này, nên layout hai bản đó tính sai cột 23. Core không có pin
swap nào (bước resizer sau global route của core đã tắt sẵn).

Đã sửa trong flow: run_flow.sh thêm -skip_pin_swap cho repair_timing ở mọi tầng, và tầng row so netlist cuối với
RTL (sim/row_equiv.sh). Row và core đã chạy lại, xem mục dưới.

## Row chạy lại và core_v11 (04-05/10)

row_v1 chạy lại với -skip_pin_swap, ghi đè bản cũ. Bước resizer sau global route không còn đổi chân
("Swapped pins" 0 dòng; bản cũ 1). sim/row_equiv.sh so netlist cuối với RTL: 2000 chu kỳ, 0 bit lệch (bản cũ
sai PE 23). DRT, Magic, LVS, antenna đều 0; setup tt +4,20 ns, hold +0,29 ns; 76 554 cell, 27 phút, RAM 2,4 GB.
Kích thước macro không đổi (3517,62 x 133,28 um), nên core dùng lại floorplan của core_v9.

core_v11 chạy với đúng cấu hình của core_v9, chỉ khác row macro:

| Mục | core_v9 | core_v11 |
|---|---|---|
| DRT | 0 | 0 |
| LVS | 0 lỗi | 0 lỗi |
| Magic | 47 cờ quanh macro (met4.5b 42, met2.3b 5), 0 lỗi thật | 48 cờ quanh macro (met4.5b), 0 lỗi thật |
| ECO antenna | 872, 365, 227, 225 | 855, 360, 289, 219 |
| Antenna cuối (pin / net) | 221 / 209 | 219 / 205 |
| Antenna trên chân SRAM | 0 | 0 |
| Setup nội bộ, tt | +1,01 ns | +1,21 ns |
| Hold nội bộ, tt | +0,11 ns | +0,27 ns |
| Setup I/O, tt (miễn) | 185 path, -1,18 ns | 196 path, -0,81 ns |
| Setup ss/100°C/1,60V, RC max | -7,46 ns | -7,61 ns |
| Setup ss/100°C/1,60V, RC min | -6,29 ns | -6,35 ns |
| Hold ff/-40°C/1,95V, RC min | sạch | sạch |
| Hold ff/-40°C/1,95V, RC max | -0,12 ns, 1 path | sạch |
| Net xuyên macro | 0 | 0 |
| RAM đỉnh | 13,0 GB | 13,5 GB |
| Thời gian (tổng / route) | 7h02m / 3h22m | 9h26m / 5h44m |

core_v11 lâu hơn chủ yếu ở hai vòng detailed route đầu (56 và 62 phút, v9 khoảng 21 phút mỗi vòng): CPU time
gấp khoảng 3 lần, RAM đỉnh gần như không đổi, nên là router tốn công hơn chứ không phải do swap.

Mô phỏng gate-level của core_v11 với netlist gate-level của 32 row (lần đầu chạy được với row gate-level): PASS
cả 3 kích thước, trùng chu kỳ với RTL FPGA (64x64x64: 258 sự kiện, 327 s; 8x32x544: 274 sự kiện, khoảng 570 s;
16x992x32: 34 sự kiện, 1317 s). RAM đỉnh của mô phỏng 3,1 GB. Lỗi cột 23 không còn.

Công suất core_v11 ở tt/25°C/1,80V, 100 MHz (tools/power.sh):

| Nhóm (mW) | Activity mặc định | VCD, chu kỳ 2300-3200 |
|---|---|---|
| SRAM (80 macro) | 445 | 445 |
| Row: tuần tự / cây clock / tổ hợp | 802 / 262 / 634 | 402 / 262 / 118 |
| Core: tuần tự / cây clock / tổ hợp | 269 / 136 / 343 | 120 / 136 / 46 |
| Tổng | 2 892 | 1 530 |

Gần như trùng với core_v9 (2,89 W và 1,53 W): hai bản chỉ khác một cell trong row. Đỉnh 204,8 GOPS, tức 134 GOPS/W
theo VCD, 70,8 GOPS/W theo activity mặc định, 2,83 GOPS/mm². Bản --vcd mất 13m27s, mô phỏng đỉnh 7,0 GB RAM.
