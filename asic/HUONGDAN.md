# Hướng dẫn chạy

Các lệnh dưới đây đã chạy trên máy build của dự án (Linux, 15,5 GB RAM, 32 GB swap). Chỗ nào chưa chạy
lại được thì có ghi "chưa kiểm".

## 1. Yêu cầu máy

- RAM: 16 GB. Run core lên đỉnh khoảng 13 GB (detailed route), global route khoảng 6 GB. Nên có thêm swap.
  Không chạy hai run OpenLane lớn cùng lúc.
- Ổ trống: 40 GB cho một run core (`core` tự dừng nếu thiếu). Một run core xong chiếm khoảng 20-25 GB.
- Thời gian (máy trên, các run thật):

| Tầng | Thời gian |
|---|---|
| sim | khoảng 6 phút |
| pe | 2 phút |
| row | 27 phút |
| array | 3 giờ 14 phút |
| core-sim | khoảng 2 phút |
| core-pre | khoảng 10 phút |
| core | khoảng 7-9,5 giờ (core_v9: 7h02m, route 3h22m; core_v11: 9h26m, route 5h44m) |
| core-gls | khoảng 40 phút cho 3 kích thước ma trận với row gate-level (core_v11: 327 s, khoảng 570 s, 1317 s); khoảng 13 phút nếu `ROW=rtl` |

## 2. Cài đặt

Docker:

    docker --version                     # máy build: Docker 29.8.2
    docker run --rm hello-world

OpenLane 1.0.2 (commit ff5509f6) vào ~/OpenLane. `make` kéo image và cài PDK sky130A vào ~/.ciel bằng ciel
(chưa kiểm lại trên máy mới; máy build đã cài sẵn theo cách này):

    git clone --depth 1 -b 1.0.2 https://github.com/The-OpenROAD-Project/OpenLane.git ~/OpenLane
    make -C ~/OpenLane

Kiểm tra:

    git -C ~/OpenLane log -1 --format=%H        # ff5509f65b17bfa4068d5336495ab1718987ff69
    docker images | grep openlane               # ghcr.io/the-openroad-project/openlane:ff5509f6...
    ~/OpenLane/venv/bin/ciel ls --pdk sky130    # 0fe599b2afb6708d281543108caf8310912f54af
    ls ~/.ciel/sky130A/libs.ref/sky130_sram_macros/lef/sky130_sram_2kbyte_1rw1r_32x512_8.lef

Công cụ trên máy (ngoài Docker):

    iverilog -V | head -1                       # máy build: Icarus Verilog 13.0
    python3 --version                           # máy build: 3.12

Mã nguồn: repo này và repo gốc GEMM_32x32_KV260 (lấy testbench) đặt cạnh nhau, tên thư mục repo gốc là
GEMM_32x32_KV260-main (hoặc đặt biến REPO trỏ tới nó):

    mkdir -p ~/gemm_asic && cd ~/gemm_asic
    git clone -b hierarchical-openlane-flow https://github.com/HoangNhan2412-ICD/GEMM32-ASIC-sky130.git
    # repo gốc: giải nén hoặc clone vào ~/gemm_asic/GEMM_32x32_KV260-main
    cd GEMM32-ASIC-sky130

## 3. Chạy từng tầng

Mỗi tầng chỉ chạy khi tầng trước đã PASS (ghi trong openlane/LOG.md). Mỗi lần chạy in `STAGE <tầng> PASS`
hoặc `FAIL` ở cuối. Run của OpenLane nằm ở ~/OpenLane/designs/<design>/runs/<tag>.

| Lệnh | Làm gì | Dấu hiệu PASS | Kết quả |
|---|---|---|---|
| `openlane/run_flow.sh sim` | RTL ASIC chạy testbench gốc, so với RTL FPGA | OVERALL PASS, trùng chu kỳ mọi kết quả | openlane/logs/sim_* |
| `openlane/run_flow.sh pe` | Harden một PE, đo diện tích | PASS, ghi diện tích PE | gemm_pe/runs/pe_v1 |
| `openlane/run_flow.sh row` | Macro 32 PE; kiểm LEF và so netlist với RTL | "row netlist = RTL" | gemm_row/runs/row_v1 |
| `openlane/run_flow.sh array` | FeatureSkew + 32 row + OutputDeskew | 32 macro đặt đúng, DRC/LVS sạch | gemm_array/runs/array_v1 |
| `openlane/run_flow.sh core-sim` | RTL core với model SRAM OpenRAM, 3 kích thước | OVERALL PASS, trùng chu kỳ | openlane/logs/core_sim_* |
| `openlane/run_flow.sh core-pre` | Lint, synthesis, floorplan của core | 80 SRAM, 32 row, macro đặt đủ | gemm_core/runs/core_pre |
| `openlane/run_flow.sh core` | Run core đầy đủ | xem mục 5 | gemm_core/runs/core_v11 |
| `openlane/run_flow.sh core-gls` | Testbench gốc trên netlist cuối của core, 3 kích thước | OVERALL PASS, trùng chu kỳ cả 3 | openlane/logs/core_gls_* |

GDS của core: ~/OpenLane/designs/gemm_core/runs/<tag>/results/final/gds/GemmAccelerator.gds.

`core` chạy với cấu hình của core_v11 (giống core_v9, chỉ khác row macro đã chạy lại), không cần biến môi trường. TAG đặt tên run khác (mặc định core_v11).
`core-gls` dùng run core mới nhất có results/final; TAG chọn run khác. Mặc định row được mô phỏng bằng netlist
gate-level của row (`ROW=gl`, đỉnh 3,1 GB RAM): chỉ cách này mới thấy lỗi trong netlist row. `ROW=rtl` dùng RTL
của row, nhanh hơn, chỉ để thử nhanh.

## 4. Theo dõi khi chạy core

Run core dài nên chạy nền, tách khỏi terminal (nếu không, đóng terminal là run chết):

    setsid nohup openlane/run_flow.sh core > ~/core_out.txt 2>&1 < /dev/null &

Xem tiến độ (chỉ đọc file, chạy lúc nào cũng được):

    openlane/run_flow.sh core-status

Lệnh này in bước đang chạy, log mới nhất, overflow của global route, số lỗi detailed route, RAM và ổ trống.
Log đầy đủ: openlane/logs/gemm_core_<tag>_<thời điểm>.log và ~/OpenLane/designs/gemm_core/runs/<tag>/logs/.
RAM theo thời gian: openlane/logs/mem_gemm_core_<tag>_<thời điểm>.txt.

## 5. Đọc kết quả

Tổng hợp (miễn timing ở cổng I/O vì đây là core, chưa có vòng pad):

    python3 openlane/check_openlane_run.py --waive-io-timing ~/OpenLane/designs/gemm_core/runs/core_v11

core_v11 cho (chu kỳ 10 ns, STA chưa gồm path qua macro): router 0 lỗi, LVS 0 lỗi, setup nội bộ +1,21 ns, hold nội bộ +0,27 ns, 219 pin / 205 net antenna,
RAM đỉnh 13,5 GB. Script vẫn ghi RESULT: FAIL vì hai mục dưới.

Antenna (core_v11 chạy riêng; IP gemm_ip đã về 0 nhờ ECO tăng dần bằng tools/eco): còn 205 net, đa số vượt nhẹ (trung vị 1,4 lần giới hạn), không net nào trên chân SRAM. Router của
OpenROAD bản này không tính antenna khi đi dây và không có chế độ ECO. Flow chèn diode ở global route, rồi
sau detailed route chạy 3 vòng ECO (đặt diode cạnh cổng vi phạm và route lại). Mỗi lần route lại sinh vi phạm
mới ở chỗ khác, nên con số dừng quanh 200.

Magic DRC: Magic đọc SRAM và row macro bằng view abstract, trong đó vùng OBS là kim loại đặc. Dây đi sát
mép macro bị báo lỗi khoảng cách kim loại rộng (met4.5b, met2.3b) mà layout thật không có. Kiểm lại từng cờ
trên GDS đầy đủ:

    tools/magic_macro_check.sh ~/OpenLane/designs/gemm_core/runs/core_v11

core_v11: 48 cờ (đều met4.5b), cả 48 nằm sát macro, 0 lỗi trên layout đầy đủ, RESULT: PASS. Báo
cáo: reports/signoff/magic_macro_check.rpt. Lệnh cần vài GB RAM, không chạy cạnh detailed route.

Timing nhiều corner (setup ở ss/100°C/1,60V, hold ở ff/-40°C/1,95V, RC min và RC max):

    python3 tools/sta_corners.py ~/OpenLane/designs/gemm_core/runs/core_v11

core_v11: setup -7,61 ns (RC max) và -6,35 ns (RC min) ở corner chậm, tức khoảng 57 MHz (cũng chưa kiểm path qua macro); hold sạch với cả RC min
và RC max. Lưu ý: STA này và con số 100 MHz ở tt chưa kiểm các path đi qua macro (SRAM, row). Kiểm đủ với lib của mọi macro
thì fmax ở tt chỉ khoảng 53 MHz. Với IP gemm_ip, setup ss của path chạm macro là −4,94 ns ở chu kỳ 20 ns (chỉ báo). IP gemm_ip vì vậy được signoff ở 50 MHz, và đó là con số "TT theo lib": SRAM chỉ có
lib TT, timing của SRAM là ngoại suy (lib chỉ đặc tính hoá slew 1,25–40 ps), SRAM OpenRAM đo trên silicon khoảng 34–40 MHz,
hold của path I/O chỉ báo, và điện dung RCX lớn hơn ước lượng sau global route khoảng 2 lần. Số liệu signoff của IP:
docs/TIEN_DO_SIGNOFF.md.

Công suất của core ở tt/25°C/1,80V, giả định 100 MHz, không đạt khi kiểm đủ path qua macro (IP gemm_ip ở 50 MHz: 745,1 mW theo VCD cả job (64x64x64; 8x32x544: 751,0; 16x992x32: 753,5 mW; SRAM tính theo lib, là cận trên; nếu lấy SRAM cận dưới thì khoảng 623–626 mW); 1377,6 mW vectorless chỉ để tham khảo; xem docs/TIEN_DO_SIGNOFF.md):

    tools/power.sh ~/OpenLane/designs/gemm_core/runs/core_v11                  # activity mặc định của OpenSTA
    tools/power.sh ~/OpenLane/designs/gemm_core/runs/core_v11 --vcd 2300 3200  # activity từ mô phỏng

core_v11: 2,89 W với activity mặc định; 1,53 W với activity từ VCD (đo lại bằng `tools/power/vcd2act.py` đã sửa lỗi alias: không đổi; mô phỏng gate-level kích thước 64x64x64,
row gate-level, chu kỳ 2300-3200 là pha tính của job thứ hai). Trong 1,53 W: SRAM 0,45 W (80 macro), row 0,78 W,
phần còn lại của core 0,30 W. Thư viện OpenRAM cho cùng năng lượng mỗi cạnh clock dù SRAM có được chọn hay không, nên phần
SRAM là cận trên. Mô phỏng không có trễ cổng nên không tính glitch. Với giả định 100 MHz, không đạt khi kiểm đủ path qua macro: đỉnh 204,8 GOPS
(2 x 32 x 32 x 100 MHz), tức 134 GOPS/W và 2,83 GOPS/mm². IP gemm_ip ở 50 MHz (công suất VCD, tt, SPEF RC nom): 64x64x64 15,9 GOPS hiệu dụng, 21,4 GOPS/W, 93,5 pJ/MAC; đỉnh 102,4 GOPS chia 745,1 mW là 137 GOPS/W (cận trên). Chi tiết: docs/paper/SUMMARY.md. Bản --vcd mất khoảng 15 phút (core_v11: 13m27s, cửa sổ 900 chu kỳ), cần khoảng 8 GB RAM (mô phỏng đỉnh 7,0 GB) và 0,7 GB ổ.

Mô phỏng gate-level: `core-gls` in PASS và số sự kiện trùng chu kỳ cho từng kích thước. core_v11 với row
gate-level: PASS cả 3 kích thước (64x64x64, 8x32x544, 16x992x32), trùng chu kỳ 258, 274 và 34 sự kiện với RTL
FPGA. Log ở openlane/logs/core_gls_<thời điểm>/. Bản core_v9 cũ sai cột 23 khi mô phỏng với row gate-level, do
row macro bị resizer đổi chân một cell (NHATKY.md); flow hiện tại chặn lỗi này ở tầng row.

## 6. Xem GDS bằng KLayout

Máy có KLayout:

    klayout -nn ~/.ciel/sky130A/libs.tech/klayout/tech/sky130A.lyt \
            -l ~/.ciel/sky130A/libs.tech/klayout/tech/sky130A.lyp \
            ~/OpenLane/designs/gemm_core/runs/core_v11/results/final/gds/GemmAccelerator.gds

Máy không cài được thì dùng KLayout 0.28.2 trong image OpenLane (cần X11; máy build dùng cách này):

    xhost +local:
    docker run --rm -it -e DISPLAY=$DISPLAY -v /tmp/.X11-unix:/tmp/.X11-unix -v $HOME:$HOME \
        --user $(id -u):$(id -g) \
        ghcr.io/the-openroad-project/openlane:ff5509f65b17bfa4068d5336495ab1718987ff69-amd64 \
        klayout -nn ~/.ciel/sky130A/libs.tech/klayout/tech/sky130A.lyt \
                -l ~/.ciel/sky130A/libs.tech/klayout/tech/sky130A.lyp \
                ~/OpenLane/designs/gemm_core/runs/core_v11/results/final/gds/GemmAccelerator.gds

Trong KLayout: Display > Full Hierarchy (phím `*`) để thấy bên trong macro; View > bỏ chọn Show Texts để tắt
chữ. GDS core khoảng 670 MB, mở mất vài phút và vài GB RAM. (Phần thao tác trong giao diện chưa kiểm lại
trong lần viết này.)

## 7. Lỗi hay gặp

Hết ổ: `core` và `core-route` kiểm ổ trước khi chạy và dừng nếu dưới 40 GB, kèm số GB còn trống. Xoá
runs/<tag>/tmp và results của các run cũ. `MIN_DISK_GB=<n>` hạ ngưỡng nếu chắc đủ.

Thiếu RAM: kernel giết OpenROAD ở detailed route, log dừng ngang không có lỗi. Kiểm tra bằng
`openlane/run_flow.sh core-triage` (đọc log, tìm thông báo OOM của kernel). Tắt chương trình khác, thêm swap.

Run bị ngắt giữa chừng (mất điện, đóng terminal) sau khi đã qua CTS: không cần chạy lại từ đầu.
core-route lấy layout sau CTS của run đó, route và signoff lại trong run mới <tag>r:

    FROM=core_v11 openlane/run_flow.sh core-route

Net xuyên macro: sau global route, macro_cross.py tìm net mà global route vạch xuyên lòng macro hơn 50 um
(SRAM chặn met1-met4 và met5 trên SRAM bị cấm, nên detailed route chắc chắn tạo short ở đó). Có net như vậy
thì run dừng ngay, báo cáo ở runs/<tag>/reports/routing/macro_cross.rpt. Cách xử lý là đổi floorplan hoặc
giảm nghẽn, không phải đổi seed.

Detailed route còn lỗi với mọi seed: lỗi ở cùng một chỗ qua nhiều seed là lỗi hình học. Xem vùng quanh lỗi:

    python3 tools/def_window.py <def> <run>/tmp/merged.nom.lef <x> <y> 12 <net...>

## 8. AXI accelerator IP (GEMM_top)

Phần này biến core thành một IP có giao tiếp chuẩn: AXI4-Lite để điều khiển, ba cổng AXI4-Stream 256 bit
(feature vào, weight vào, result ra). Core giữ nguyên. Bản KV260 vốn đã là một AXI IP như vậy (`rtl/GEMM_top.v`
và `axi_ip/` của repo gốc), nên ở đây chỉ chép wrapper đó sang `rtl_asic/axi/`, sửa cho hợp ASIC, rồi đo phần
nó tốn thêm.

    rtl_asic/axi/GEMM_top.v            top của IP, cùng tên, cổng (thêm irq), tham số với bản KV260
    rtl_asic/axi/GemmAxiShell.v        mọi thứ trừ core: ResetSync, thanh ghi AXI4-Lite, cờ busy/done,
                                       bộ đếm chu kỳ, 3 cổng AXIS
    rtl_asic/axi/AxiLiteControlRegs.v  thanh ghi 0x00-0x24, handshake như template Xilinx của bản KV260
    rtl_asic/axi/AxisSkidBuffer.v      register slice hai ô (mọi cổng ra từ flop)
    rtl_asic/axi/AxisFwdSlice.v        register slice một ô (TREADY qua một cổng logic)
    rtl_asic/axi/AxisClockGate.v       clock gate cho dãy flop dữ liệu (cell dlclkp của sky130)

Register map. 0x00-0x0C giữ nguyên bản KV260 nên driver KV260 (FPGA_GEMM.cpp) và testbench gốc dùng được
ngay. Phần mới cần bus địa chỉ 6 bit của IP; testbench gốc nối 4 bit nên không chạm tới chúng.

| Địa chỉ | Tên | Kiểu | Nội dung |
|---|---|---|---|
| 0x00 | SHIFT / STATUS | RW | ghi [9:0] shift, [16] xoá done; đọc [9:0] shift, [24] busy, [25] done, [26] idle, [27] clear được nhận, [28] clear bị từ chối |
| 0x04 | ROW_COUNT | RW | [8:0] số hàng (F_length) |
| 0x08 | K_BLOCKS | RW | [4:0] số khối K |
| 0x0C | N_BLOCKS | RW | [4:0] số khối N |
| 0x10 | IRQ_ENABLE | RW | [0] ngắt khi job xong, [1] ngắt khi có lỗi |
| 0x14 | IRQ_STATUS | R/W1C | [0] job xong, [1] có lỗi; ghi 1 để xoá |
| 0x18 | ERROR | R/W1C | [0] beat feature thiếu TSTRB, [1] beat weight thiếu TSTRB, [2] lệnh xoá done bị từ chối vì đang bận |
| 0x1C | JOB_CYCLES | RO | số chu kỳ của job gần nhất, từ beat vào đầu tiên tới beat kết quả cuối (job không chồng nhau, như driver KV260 chạy) |
| 0x20 | IP_ID | RO | 0x47454D4D ("GEMM") |
| 0x24 | IP_VERSION | RO | [31:24] major, [23:16] minor, [15:8] kích thước mảng, [7:0] độ rộng dữ liệu |

Chân `irq` = IRQ_STATUS AND IRQ_ENABLE, mức cao, ra từ flop. Thanh ghi 0x04-0x0C chỉ lưu số bit core dùng (9, 5,
5), bit cao đọc ra 0; phần mềm ghi giá trị hợp lệ thì đọc lại vẫn như cũ. Có ResetSync trên S_AXI_ARESETN (bản
FPGA có proc_sys_reset lo việc này).

Biến thể cổng stream, chọn bằng `GEMM_AXIS_REG` và `GEMM_AXIS_CG` trong gemm_asic_cfg.vh. Mặc định của IP là lean
có clock gating (REG=2, CG=1), chọn sau lần axi-shell ngày 10/10: diện tích bằng khoảng một nửa reg, công suất thấp
hơn reg ở mọi cách đo, mà phía ra vẫn toàn flop.

| | thin (REG=0) | reg (REG=1) | lean (REG=2) |
|---|---|---|---|
| Feature / weight vào | nối thẳng vào core | AxisSkidBuffer (2 ô) | AxisFwdSlice (1 ô) |
| Result ra | nối thẳng ra core | AxisSkidBuffer | AxisSkidBuffer |
| TREADY của luồng vào | tổ hợp từ core và TSTRB | ra từ flop | qua một cổng logic từ ready của core |
| Flop thêm | 0 | khoảng 1550 | khoảng 1030 |
| Timing ở cổng | bằng timing cổng của core (core_v11 đang miễn) | ngắn | ngắn |

`GEMM_AXIS_CG=1` (chỉ với reg, lean) đặt clock gate trước mỗi dãy flop dữ liệu: dãy nào không nạp beat thì không
có cạnh clock. Hành vi giữ nguyên từng chu kỳ. Ngoài công suất clock, nó còn bỏ được bộ mux enable trước mỗi flop dữ
liệu (flop có enable được thay bằng flop thường), nên diện tích cũng nhỏ đi: lean 47 632 um², lean_cg 32 765 um².
Lý do lean chỉ cần slice một ô ở phía
vào: dữ liệu feature/weight đi thẳng vào chân ghi của SRAM, còn ready của core là phép so sánh bộ đếm trên flop
(In_buffer.v), nên phía vào của core vốn gần như đã có thanh ghi. Phía ra đi qua bộ dịch tổ hợp nên giữ skid hai ô.

Beat có TSTRB không đủ byte (driver KV260 không bao giờ gửi) không bao giờ vào core, luồng dừng ở đó cho tới khi
reset, và bit ERROR[0] hoặc [1] bật lên. Với thin, TREADY ở mức thấp nên master vẫn giữ beat; với reg và lean,
slice đã nhận beat đó rồi mới dừng. Lỗi chỉ được ghi một lần ở chu kỳ đầu tiên beat xuất hiện, nên master cứ giữ
beat thì ISR xoá (W1C) xong bit vẫn ở 0, irq không bật lại liên tục. Cờ busy/done lấy theo handshake ở cổng của IP, để "done" nghĩa là beat kết
quả cuối đã ra khỏi IP. TREADY của các slice ở mức thấp suốt lúc reset và một chu kỳ sau đó, vì reset bên trong
nhả muộn hơn cổng hai chu kỳ (ResetSync).

### ERRATA (IP v1)
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

### Chạy

| Lệnh | Làm gì | Dấu hiệu PASS | Thời gian |
|---|---|---|---|
| `openlane/run_flow.sh axi-sim` | Test riêng hai loại slice (có và không clock gating); test shell với model core cho thin, reg, reg+cg, lean, lean+cg (thanh ghi, ngắt, lỗi, JOB_CYCLES, dữ liệu dưới backpressure ngẫu nhiên); testbench gốc với thin, reg, reg+cg, lean, lean+cg, và lean+cg + model OpenRAM (3 kích thước) | `AXI IP RTL: ALL PASS` | khoảng 2 phút |
| `openlane/run_flow.sh axi-shell` | Harden riêng GemmAxiShell cho thin, reg, lean, lean_cg (`AXI_SHELL_VARIANTS` để đổi), mỗi biến thể hai run (đo clock latency rồi chạy thật); công suất vectorless và theo VCD (chu kỳ 2300-3200 như core, và cả testbench); in bảng overhead | các run sạch DRC/LVS, có bảng (antenna còn vài chục chân, xem dưới) | 1:10 cho 4 biến thể |
| `openlane/run_flow.sh axi-gls` | Testbench gốc trên GEMM_top (mặc định lean + clock gating; `AXI_GLS_WRAP`, `AXI_GLS_CG` để đổi) bọc netlist cuối của core, row gate-level | OVERALL PASS | 5:50 một kích thước |

Chạy riêng phần RTL không cần OpenLane: `sim/run_axi.sh`. Chọn wrapper cho các script cũ bằng biến WRAP:

    WRAP=lean AXIS_CG=1 sim/run_system.sh asic    # thin, reg, lean; fpga (mặc định) là wrapper của repo KV260
    WRAP=lean AXIS_CG=1 ROW=gl sim/run_gls.sh ~/OpenLane/designs/gemm_core/runs/core_v11

Điều mong đợi ở axi-sim: thin trùng chu kỳ từng sự kiện kết quả với RTL KV260, vì logic giống hệt. reg, lean ra
cùng dãy kết quả, trễ hơn vài chu kỳ; script in khoảng lệch. Testbench gốc chặn result 1/7 chu kỳ và có khoảng trống
ở hai luồng vào, nên skid buffer được thử cả lúc đầy lẫn lúc rỗng. tb_axis_skid.v thử thêm valid/ready ngẫu
nhiên 80 000 beat.

### Đọc bảng overhead

axi-shell ghi bảng vào openlane/logs/axi_overhead_<thời điểm>.md (tools/axi_overhead.py). Cột đầu là core_v11,
sau đó mỗi biến thể một cột (shell_thin, shell_reg, shell_lean, shell_lean_cg, theo `AXI_SHELL_VARIANTS`). Ô của
shell ghi dạng `giá trị (x %)`, x là phần trăm so với core ở cùng dòng. Ô "-" là không có số trong thư mục run;
script không bao giờ tự điền. Công suất của core lấy từ reports/power/ của run core_v11 (`tools/power.sh <run
core>` cho vectorless, `tools/power.sh <run core> --vcd 2300 3200` cho VCD). Chưa có thì cột core để trống.

- Diện tích: số cell sky130_fd_sc_hd sau synthesis nhân với diện tích từng cell trong liberty tt (script tự tìm
  dưới $PDK_ROOT, ~/.ciel, ~/.volare, hoặc `--lib`). Macro SRAM không bao giờ lọt vào con số này. Phía core được
  tính cả cell bên trong 32 row macro (lấy từ run row_v1), vì phần lớn logic của core nằm trong row; cell ở top
  core thôi chỉ là một phần nhỏ, so với nó thì phần trăm overhead bị phóng to nhiều lần. Die của run shell do
  ~1780 chân quyết định nên không có nghĩa (600 x 1500 um; bản 300 um đầu tiên nghẽn route ở mép Tây với reg).
  Dòng "placed area" (trước khi chèn filler) chia cho die core_v11 là phần die IP tốn thêm nếu đặt shell sát core.
  Cell dlclkp của bản _cg được tính như mọi cell khác.
- Timing: slack setup và hold ở cả ba corner, tách đường bên trong khối với đường chạm cổng. Với core_v11, đường
  chạm cổng đang được miễn (chưa có pad ring) nên chỉ đọc các dòng "inside the block". Shell dùng ngân sách cổng 30 % chu kỳ ở cả hai phía
  (GEMM_SHELL_IO_PCT trong config). Độ trễ ở cổng tính theo clock latency của chính shell, đo ở run hiệu chỉnh
  shell_<biến thể>_cal (cùng cách core.sdc làm với core). Không làm vậy thì mọi input của reg đều vi phạm hold
  bằng đúng latency, và resizer chèn delay cell vào cả ~560 input, làm phồng diện tích lẫn công suất. Latency đo
  ở corner typical và là một con số chung cho cả khối, nên slack ở cổng của corner Slowest có thể âm vài trăm ps
  (10/10: hold reg -0,29, lean_cg -0,56; setup reg -0,09, lean_cg -0,47 ns). Đó là do cách đặt ràng buộc, không phải
  lỗi trong khối: slack bên trong khối dương ở mọi corner. Hold của lean_cg lệch nhiều nhất vì flop sau clock gate
  có latency lớn hơn flop nối thẳng S_AXI_ACLK, nên một con số latency chung sai nhiều hơn (Typical còn -0,08 ns; cả
  hai đường hold xấu nhất đều từ chân feature_axis_tdata vào flop sau clock gate của feature slice).
  Đường setup xấu nhất ở Slowest (-0,47 ns) đi từ flop r_ready ra cổng o_result_ready: ba slice có ba flop r_ready
  giống hệt (cùng clock, reset, nhận hằng 1) nên Yosys gộp thành một flop, mang tên của feature slice, và flop đó cấp
  TREADY cho cả ba. Đây là đường ra cổng phía core với ngân sách 3 ns, Typical vẫn +2,16 ns. Ở bước 3 (chạy phẳng
  GEMM_top) cây clock của shell và core được dựng chung thì các con số ở cổng mới thật. Dòng "violating
  setup paths at a port" đếm theo báo cáo signoff ở corner Typical; ở đó cả bốn biến thể đều bằng 0.
- Antenna: các run shell còn vài chục chân vi phạm (10/10: thin 6, reg 56, lean 38, lean_cg 12) dù đã có diode ở
  cổng và heuristic diode. Đây là run đo đạc nên chưa sửa tiếp; chúng không làm đổi diện tích hay công suất đáng kể.
  Bản IP nộp thật sẽ là bước 3, khi đó sửa antenna cùng với core.
- Công suất, vectorless: OpenSTA activity mặc định ở cả hai bên, cùng cách với con số 2,89 W của core. Bản _cg thấp
  hơn nhiều (10/10: lean 32,65 mW, lean_cg 6,91 mW): phần Combinational giảm vì hết mux enable, phần Sequential giảm
  từ 9,3 xuống 2,2 mW với cùng 1158 flop, tức ở chế độ này OpenSTA có tính phần clock bị chặn. Con số theo hoạt động
  thật là dòng VCD.
- Công suất, VCD: chạy testbench gốc trên GEMM_top với netlist cuối của shell và RTL của core, lấy activity từng
  net của shell, rồi OpenSTA tính như với core. Khác core một điểm: activity của các cổng vào cũng lấy từ VCD (shell
  gần như toàn logic sát cổng; đo ngày 10/10 thì tổng chỉ đổi dưới 0,1 %).
  Chỗ cần biết với bản _cg: trong chu kỳ 2300..3200 cả bốn chân GCLK đứng yên (0 lần đổi), vậy mà OpenSTA của image
  OpenLane vẫn tính flop sau clock gate và net GCLK như đang nhận clock đủ mọi chu kỳ (flop sau gate tốn đúng bằng
  flop nối thẳng S_AXI_ACLK; đặt activity rất nhỏ thay cho 0 cũng không đổi). Ở cửa sổ 0..end, khi GCLK có đổi, nó
  tính đúng (flop sau gate tốn khoảng 1/10, đã kiểm từng instance). Nên số 2300..3200 của bản _cg là cận trên. Đã
  thử xoá clock trong STA để mọi chân lấy activity từ VCD, nhưng khi không có clock thì phần switching ra đúng 1e-8
  lần giá trị thường, nên bỏ cách đó.
  Có hai cửa sổ. Chu kỳ 2300..3200 là cửa sổ core_v11 đã dùng (pha
  tính của job 2; theo log testbench, không có beat nào qua cả ba cổng stream trong khoảng này), nên ô `(x %)` ở dòng này so cùng một khoảng thời gian; cộng số của shell với số của core là
  công suất của cả IP trong khoảng đó. Cửa sổ 0..end là cả testbench (nạp dữ liệu, tính, đọc kết quả của hai job);
  core không có số cho cửa sổ này nên ô core để trống, chỉ so các biến thể với nhau. Clock gating chỉ bớt công
  suất ở những chu kỳ một cổng stream không nạp beat; tỷ lệ chu kỳ đó ở hai cửa sổ khác nhau, nên phần bớt được ở
  hai dòng cũng khác nhau.

Giới hạn của cách đo này: shell được harden riêng nên cây clock của nó không cân với cây clock của core, và
path giữa shell với core chưa được phân tích thật. Muốn có timing của cả IP thì cần bước 3 bên dưới.

Với bản _cg nên mở thêm log CTS của run (`logs/cts/*cts.log`, dòng `Clock net ... has N sinks`): mỗi clock gate
phải có một dòng riêng cho net GCLK của nó. Nếu chỉ thấy net S_AXI_ACLK thì TritonCTS không dựng cây sau clock
gate, net GCLK lớn (khoảng 258 flop) chỉ được resizer chèn buffer thường, và slack hold bên trong khối sẽ là chỗ lộ ra.
Lần 10/10 TritonCTS dựng đủ: S_AXI_ACLK 132 sink, bốn net GCLK 257-258 sink mỗi net.

### Kết quả 10/10/2026

core_v11 so với shell của bốn biến thể (openlane/logs/axi_overhead_20261010-133311.md). Phần trăm là so với core
ở cùng dòng; diện tích core gồm cả 32 row macro.

| | thin | reg | lean | lean_cg |
|---|---|---|---|---|
| Cell sau synthesis | 1 366 (0,20 %) | 6 297 (0,93 %) | 4 114 (0,61 %) | 2 201 (0,32 %) |
| Flop | 123 | 1 676 | 1 158 | 1 158 |
| Diện tích std-cell (um²) | 10 372 (0,14 %) | 72 708 (0,95 %) | 47 632 (0,62 %) | 32 765 (0,43 %) |
| Placed area (um², % die core) | 51 858 (0,07 %) | 159 101 (0,22 %) | 123 163 (0,17 %) | 100 931 (0,14 %) |
| Setup trong khối, Slowest (ns) | +5,31 | +0,95 | +0,40 | +3,01 |
| Setup ở cổng, Typical (ns) | +2,11 | +3,39 | +2,18 | +2,16 |
| Hold trong khối, Typical (ns) | +0,36 | +0,30 | +0,30 | +0,31 |
| Công suất vectorless (mW) | 3,86 (0,13 %) | 44,4 (1,54 %) | 32,7 (1,13 %) | 6,91 (0,24 %) |
| Công suất VCD, cả testbench (mW) | 1,79 | 14,3 | 9,87 | 3,02 |
| Công suất VCD, chu kỳ 2300..3200 (mW) | 3,13 (0,20 %) | 16,6 (1,09 %) | 11,9 (0,78 %) | ≤ 12,1 (≤ 0,79 %) |
| Chu kỳ trễ so với KV260 | 0 | 1-3 | 1-3 | 1-4 |

Core để so: 7 684 240 um² std-cell, 105 821 flop, die 72,3 mm², 2,89 W vectorless, 1,529 W VCD ở 2300..3200 (cả hai ở giả định 100 MHz). Cả
bốn biến thể giữ một beat mỗi chu kỳ trên mỗi luồng. DRC và LVS sạch; antenna còn 6 / 56 / 38 / 12 chân (run đo
đạc). Chức năng: axi-sim ALL PASS (thin trùng chu kỳ với RTL KV260 ở cả 258 sự kiện kết quả), axi-gls lean_cg bọc
netlist cuối của core_v11 PASS.

Đọc gọn: lớp AXI tốn dưới 1 % diện tích std-cell của core ở mọi biến thể, và dưới 1 % công suất ở mọi biến thể trừ
reg (1,1-1,5 %). Clock gating trên lean bớt 31 % diện
tích (hết mux enable) và 69 % công suất theo VCD cả testbench (9,87 xuống 3,02 mW). Ô ≤ 12,1 mW là cận trên vì giới
hạn của OpenSTA nói ở trên: trong cửa sổ đó cả ba luồng đứng yên và mọi clock gate đều đóng, nên số thật thấp hơn
(riêng 1030 flop sau các clock gate đã chiếm khoảng 4,4 mW trong con số đó). Slack âm ở cổng tại corner Slowest và hold -0,08 ns ở cổng của lean_cg là do ràng buộc ở biên khối (mục Timing
ở trên), sẽ có số thật ở bước 3.

### Bước 3 (chưa làm): chạy phẳng GEMM_top

Cho ra một GDS IP hoàn chỉnh: chạy lại core flow với top là GEMM_top, khoảng 9,5 giờ như core_v11. Những chỗ
cần sửa, đã đếm trên code hiện tại:

- gen_core_files.py: tên chân theo AXI (`feature_axis_tdata` thay `i_feature_data`...), thêm 3 x 32 chân TSTRB
  và 96 chân AXI4-Lite ở nhóm cfg/clk, tên macro trong macro.cfg có thêm tiền tố `u_gemm_accelerator.`
- config.tcl và core.sdc: DESIGN_NAME, VERILOG_FILES, CLOCK_PORT S_AXI_ACLK, false path cho S_AXI_ARESETN;
  cfg_shift_mcp.sdc tìm net `r_cfg_shift*` ở top, sau khi flatten phải tìm theo tên có tiền tố
- run_flow.sh có 63 chỗ ghi cứng gemm_core/GemmAccelerator; core_full.tcl, resume.tcl, route_signoff.tcl,
  keep_rows_clear.tcl, preflight.tcl cũng có. Nên làm design riêng gemm_axi thay vì sửa gemm_core, để không
  phá flow core đang sạch
- Với reg, các cổng AXIS đều ra/vào từ flop, nên bỏ được `--waive-io-timing` và đặt ngân sách cổng thật

Nên chạy axi-sim, axi-shell, axi-gls trước. Số overhead ở bước 2 đủ cho báo cáo; bước 3 cần khi muốn nộp
một IP có GDS hoàn chỉnh hoặc muốn số timing của cả IP.
