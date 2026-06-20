# README - GEMM 32x32 KV260 Debug Notes

## 1. Muc dich cua file nay

File nay ghi lai trang thai debug hien tai cua project GEMM 32x32 tren KV260, loi da gap, cach tam thoi da giai quyet duoc, va cac luu y quan trong cho nguoi tiep tuc phat trien sau nay.

Day la README ban giao cho nguoi sau, de tranh viec lap lai cac loi cu nhu:

- Vitis GUI Run Configuration bi loi `can't read "map": no such variable`.
- AXI-Lite bi treo khi doc DMA register.
- DMA chay xong nhung ket qua GEMM toan bang 0.
- Nham cau hinh 24x24 voi 32x32.
- Nham luong DMA, clock, reset, cache, hoac register config cua GEMM core.

---

## 2. Trang thai hien tai cua he thong

Project hien tai da chay duoc GEMM 32x32 INT8 tren KV260 bang AXI DMA.

Cau hinh da test thanh cong:

```text
Board / SoC      : KV260 / K26
Tool             : Vivado + Vitis 2022.2
Matrix size      : 32 x 32
Data type        : INT8
Input A size     : 32 * 32 = 1024 bytes
Input B size     : 32 * 32 = 1024 bytes
Output C size    : 32 * 32 = 1024 bytes
AXIS data width  : 256-bit = 32 bytes/beat
AXI-Lite width   : 32-bit control register
```

Ket qua test thanh cong:

```text
DMA0 feature done, status=0x00001002
DMA1 weight done, status=0x00001002
DMA2 result done, status=0x00001002
COMPARE PASS
```

Y nghia:

```text
PS AXI-Lite -> DMA/GEMM control  : OK
DMA0 MM2S -> feature_axis        : OK
DMA1 MM2S -> weight_axis         : OK
GEMM core 32x32                  : OK trong test hien tai
GEMM result -> DMA2 S2MM -> DDR  : OK
Software result == Hardware result: PASS
```

---

## 3. So do ket noi phan cung hien tai

He thong dung 3 AXI DMA:

```text
DMA0: MM2S only
  DDR -> DMA0 -> GEMM_top/feature_axis

DMA1: MM2S only
  DDR -> DMA1 -> GEMM_top/weight_axis

DMA2: S2MM only
  GEMM_top/result_axis -> DMA2 -> DDR
```

AXI-Lite control:

```text
PS M_AXI_HPM -> AXI interconnect -> DMA0 S_AXI_LITE
                                  -> DMA1 S_AXI_LITE
                                  -> DMA2 S_AXI_LITE
                                  -> GEMM_top S_AXI
```

DDR data path:

```text
DMA M_AXI ports -> SmartConnect -> PS S_AXI_HPC0_FPD -> DDR
```

Clock/reset:

```text
Tat ca PL clock nen dung chung pl_clk0 ~100 MHz.
Tat ca reset active-low nen lay tu rst_ps8_0_99M/peripheral_aresetn.
```

Luu y rat quan trong:

```text
rst_ps8_0_99M/dcm_locked phai duoc noi voi constant 1'b1.
Neu dcm_locked bo trong, reset co the bi giu mai va AXI-Lite se treo.
```

---

## 4. Dia chi phan cung hien tai

Theo `xparameters.h`, cac base address hien tai la:

```c
#define FEATURE_DMA_ADDR    XPAR_AXI_DMA_0_BASEADDR   // 0xA0000000
#define WEIGHT_DMA_ADDR     XPAR_AXI_DMA_1_BASEADDR   // 0xA0010000
#define RESULT_DMA_ADDR     XPAR_AXI_DMA_2_BASEADDR   // 0xA0020000
#define MM_ADDR             XPAR_GEMM_TOP_0_BASEADDR  // 0xA0030000
```

Tuyet doi khong nen sua tay `xparameters.h`.
Neu doi Vivado block design hoac export XSA moi, hay doc lai `xparameters.h` de lay macro dung.

---

## 5. Loi da gap 1: Vitis GUI Run bi loi `map`

### Hien tuong

Khi bam Run / Launch Hardware trong Vitis GUI, co popup loi:

```text
can't read "map": no such variable
```

### Ket luan

Day khong phai loi code C, khong phai loi DMA, khong phai loi RTL GEMM.
Day la loi metadata / launch configuration cua Vitis workspace.

### Cach vuot qua

Dung XSCT Console de download ELF truc tiep, bo qua Run Configuration cua GUI.

Lenh da dung:

```tcl
connect
targets

targets -set -filter {name =~ "*PSU*"}
source {E:/VITIS_2022/gemm_top_caoky/export/gemm_top_caoky/hw/psu_init.tcl}
psu_init
psu_ps_pl_isolation_removal
psu_ps_pl_reset_config

fpga -f {E:/Everything_with_VIVADO/MM_final/MM_final.runs/impl_1/GEMM_BD_wrapper.bit}

targets -set -filter {name =~ "Cortex-A53 #0"}
rst -processor
dow {E:/VITIS_2022/gemm_test_app/Debug/gemm_test_app.elf}
con
```

Neu sau nay muon sua tan goc loi GUI, nen tao workspace moi hoan toan, vi app moi trong workspace cu van co the bi loi `map`.

---

## 6. Loi da gap 2: AXI-Lite bi treo khi doc DMA register

### Hien tuong

Code dung o dong:

```text
Read DMA0 DMASR...
```

Khong in tiep duoc `DMA0 DMASR = ...`.

### Ket luan

Luc do CPU khong doc duoc AXI-Lite register trong PL. Nghia la duong AXI-Lite PS -> PL chua thong.

### Nguyen nhan co kha nang cao

Reset PL bi giu do `rst_ps8_0_99M/dcm_locked` chua duoc noi dung.

### Cach da sua

Trong Vivado block design:

```text
Them xlconstant = 1'b1
Noi xlconstant/dout -> rst_ps8_0_99M/dcm_locked
```

Sau do generate bitstream moi, export XSA moi, update platform trong Vitis, build lai, program lai bitstream.

### Test xac nhan AXI-Lite da OK

Code test:

```c
xil_printf("AXI-Lite bus test\r\n");
xil_printf("DMA0 base = 0x%08X\r\n", FEATURE_DMA_ADDR);
xil_printf("Read DMA0 DMASR...\r\n");

u32 dma0_sr = Xil_In32(FEATURE_MM2S_DMASR);

xil_printf("DMA0 DMASR = 0x%08X\r\n", dma0_sr);

xil_printf("GEMM base = 0x%08X\r\n", MM_ADDR);
xil_printf("Write GEMM SHIFT...\r\n");

Xil_Out32(SHIFT_ADDR, 0);

xil_printf("Write GEMM SHIFT done\r\n");
```

Output da dat duoc:

```text
AXI-Lite bus test
DMA0 base = 0xA0000000
Read DMA0 DMASR...
DMA0 DMASR = 0x00000001
GEMM base = 0xA0030000
Write GEMM SHIFT...
Write GEMM SHIFT done
```

Y nghia:

```text
AXI-Lite path da thong.
CPU doc duoc DMA0 register.
CPU ghi duoc GEMM_top register.
```

---

## 7. Loi da gap 3: DMA done nhung C_hw toan 0

### Hien tuong

DMA chay xong het:

```text
DMA0 feature done, status=0x00001002
DMA1 weight done, status=0x00001002
DMA2 result done, status=0x00001002
```

Nhung ket qua hardware toan 0:

```text
C_hw sample 8x8:
0 0 0 0 0 0 0 0
0 0 0 0 0 0 0 0
...
COMPARE FAIL
```

### Ket luan

Luc nay AXI-Lite va DMA khong con la loi chinh nua.
Vi DMA0/DMA1/DMA2 deu done, AXIS handshake va TLAST da di qua.
Loi nam o phan GEMM core/config/output scaling.

### Nguyen nhan nghi ngo cao nhat

Trong RTL `GEMM_core`, cac config register co kha nang dang duoc latch theo kieu chi cap nhat khi input thay doi, vi du:

```verilog
always @(posedge clk) begin
    if (shift_in_delay1 != shift_in)
        shift <= shift_in;
end
```

Kieu nay nguy hiem vi:

1. Neu gia tri reset/default cua internal register khong dung, lan ghi dau co the khong cap nhat nhu mong doi.
2. Neu `shift` ban dau khong phai 0, Right_shifter co the dich qua lon lam ket qua thanh 0.
3. CPU doc lai AXI-Lite register thay dung chua chac internal GEMM_core da latch dung.
4. Neu config duoc ghi qua AXI-Lite trong luc core/reset/FSM chua san sang, core co the dung config cu.

Bang chung: Sau khi force config register thay doi mot lan roi ghi lai gia tri that, ket qua PASS.

Luu y: Chua the ket luan 100% neu chua xem waveform/ILA, nhung bang chung hien tai cho thay loi lien quan rat manh den cach latch config register trong RTL.

---

## 8. Workaround da dung trong software

Trong `gemm_hard()`, truoc khi ghi config that, ghi mot bo config gia de ep register thay doi:

```c
volatile u32 delay;

// Force control registers to change once
Xil_Out32(SHIFT_ADDR, 1);
Xil_Out32(FL_ADDR, 31);
Xil_Out32(FWBN_ADDR, 2);
Xil_Out32(WWBN_ADDR, 2);

for (delay = 0; delay < 100000; delay++);

// Write real config for 32x32
Xil_Out32(SHIFT_ADDR, R_SHIFT);          // usually 0
Xil_Out32(FL_ADDR, F_length);            // 32
Xil_Out32(FWBN_ADDR, F_width_block_num); // 1
Xil_Out32(WWBN_ADDR, W_width_block_num); // 1

for (delay = 0; delay < 100000; delay++);

xil_printf("Readback SHIFT = %lu\r\n", (unsigned long)Xil_In32(SHIFT_ADDR));
xil_printf("Readback FL    = %lu\r\n", (unsigned long)Xil_In32(FL_ADDR));
xil_printf("Readback FWBN  = %lu\r\n", (unsigned long)Xil_In32(FWBN_ADDR));
xil_printf("Readback WWBN  = %lu\r\n", (unsigned long)Xil_In32(WWBN_ADDR));
```

Sau workaround nay, ket qua da PASS:

```text
Readback SHIFT = 0
Readback FL    = 32
Readback FWBN  = 1
Readback WWBN  = 1
...
COMPARE PASS
```

### Muc do an toan cua workaround

Workaround nay dung de demo va debug tiep.
Tuy nhien day khong phai cach sua RTL sach.
Neu nguoi sau phat trien tiep, nen sua RTL config latch de khong can force write nua.

---

## 9. De xuat sua RTL lau dai

### Khong nen dung cach latch chi khi input thay doi

Can tranh kieu:

```verilog
always @(posedge clk) begin
    if (shift_in_delay1 != shift_in)
        shift <= shift_in;
end
```

### Cach sua don gian hon

Neu AXI-Lite register va GEMM core dung chung clock/reset, co the latch truc tiep moi chu ky:

```verilog
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        shift             <= 0;
        F_length          <= 0;
        F_width_block_num <= 0;
        W_width_block_num <= 0;
    end else begin
        shift             <= shift_in;
        F_length          <= F_length_in;
        F_width_block_num <= F_width_block_num_in;
        W_width_block_num <= W_width_block_num_in;
    end
end
```

### Cach tot hon cho thiet ke san pham

Nen co them thanh ghi `start` hoac `config_valid`:

```text
CPU ghi SHIFT/FL/FWBN/WWBN
CPU ghi START = 1
GEMM_core latch config tai canh START
GEMM_core chay
GEMM_core set DONE = 1 khi xong
CPU doc DONE/STATUS
```

Model nay sach hon vi config chi duoc lay tai thoi diem bat dau job, tranh config thay doi giua luc core dang chay.

### Luu y khi sua RTL

Sau khi sua RTL:

1. Chay simulation RTL neu co testbench.
2. Run synthesis/implementation lai.
3. Generate bitstream moi.
4. Export XSA moi co bitstream.
5. Update platform trong Vitis.
6. Build lai app.
7. Chay lai 3 test:
   - UART hello.
   - AXI-Lite read/write.
   - GEMM 32x32 compare pass.

Khong chi export XSA neu chua generate bitstream moi, vi sua RTL bat buoc phai co bitstream moi.

---

## 10. Thu tu chay DMA dung

Thu tu trong software can giu nhu sau:

```text
1. Ghi config GEMM register:
   SHIFT, F_length, F_width_block_num, W_width_block_num

2. Flush cache cho A_buf, B_buf, C_hw.

3. Reset DMA channels neu can.

4. Start DMA2 S2MM truoc de san sang nhan result.

5. Start DMA0 MM2S gui feature/A.

6. Start DMA1 MM2S gui weight/B.

7. Wait DMA0 done.

8. Wait DMA1 done.

9. Wait DMA2 done.

10. Invalidate cache cho C_hw.

11. Compare C_hw voi C_sw.
```

Neu start input DMA truoc output DMA, co the output stream bi backpressure/tac neu DMA2 chua san sang.

---

## 11. Luu y ve DMA va cache

AXI DMA dang dung stream width 256-bit, tuc 32 bytes/beat.

Nen khai bao buffer can 32 hoac 64 byte:

```c
static data_t A_buf[MATRIX_A_BYTES] __attribute__((aligned(64)));
static data_t B_buf[MATRIX_B_BYTES] __attribute__((aligned(64)));
static data_t C_hw[MATRIX_C_BYTES]  __attribute__((aligned(64)));
```

Neu DCache bat:

```c
Xil_DCacheFlushRange((UINTPTR)A_buf, MATRIX_A_BYTES);
Xil_DCacheFlushRange((UINTPTR)B_buf, MATRIX_B_BYTES);
Xil_DCacheFlushRange((UINTPTR)C_hw, MATRIX_C_BYTES);

// Sau khi DMA2 done:
Xil_DCacheInvalidateRange((UINTPTR)C_hw, MATRIX_C_BYTES);
```

Neu debug kho, co the tam thoi tat cache:

```c
Xil_DCacheDisable();
```

Nhung khi do performance se giam. De demo correctness thi chap nhan duoc.

---

## 12. Register DMA can biet

MM2S channel:

```c
#define MM2S_DMACR       0x00U
#define MM2S_DMASR       0x04U
#define MM2S_SA          0x18U
#define MM2S_SA_MSB      0x1CU
#define MM2S_LENGTH      0x28U
```

S2MM channel:

```c
#define S2MM_DMACR       0x30U
#define S2MM_DMASR       0x34U
#define S2MM_DA          0x48U
#define S2MM_DA_MSB      0x4CU
#define S2MM_LENGTH      0x58U
```

Status hay gap:

```text
0x00000001 : halted
0x00001002 : IOC interrupt + idle, transfer done
```

Khi start DMA, nen ghi address truoc, LENGTH sau. Ghi LENGTH la hanh dong bat dau transfer.

---

## 13. Test nen giu lai cho nguoi sau

### Test 1: UART hello

Dung de xac nhan Vitis/XSCT/JTAG/UART OK.

Expected:

```text
Hello from new gemm_test_app
```

### Test 2: AXI-Lite bus test

Dung de xac nhan CPU doc/ghi duoc PL register.

Expected:

```text
AXI-Lite bus test
DMA0 base = 0xA0000000
Read DMA0 DMASR...
DMA0 DMASR = 0x00000001
GEMM base = 0xA0030000
Write GEMM SHIFT...
Write GEMM SHIFT done
```

### Test 3: GEMM 32x32 DMA test

Dung de xac nhan toan bo pipeline.

Expected:

```text
===== GEMM 32x32 DMA TEST START =====
...
DMA0 feature done, status=0x00001002
DMA1 weight done, status=0x00001002
DMA2 result done, status=0x00001002
Hardware GEMM done
COMPARE PASS
===== GEMM 32x32 DMA TEST END =====
```

### Test 4: Identity matrix

Nen them test:

```text
A = matrix bat ky
B = identity matrix
Expected C = A
```

Test nay de giai thich voi thay/co nguoi xem de hon vi nhin output co the hieu ngay.

---

## 14. Neu C_hw lai toan 0 thi kiem tra gi?

Kiem tra theo thu tu:

1. Log AXI-Lite readback:

```text
Readback SHIFT = 0
Readback FL    = 32
Readback FWBN  = 1
Readback WWBN  = 1
```

2. Da co force config write chua?

```c
Xil_Out32(SHIFT_ADDR, 1);
Xil_Out32(FL_ADDR, 31);
Xil_Out32(FWBN_ADDR, 2);
Xil_Out32(WWBN_ADDR, 2);
// delay
Xil_Out32(SHIFT_ADDR, 0);
Xil_Out32(FL_ADDR, 32);
Xil_Out32(FWBN_ADDR, 1);
Xil_Out32(WWBN_ADDR, 1);
```

3. DMA status co done khong?

```text
DMA0 status phai co 0x1000 hoac 0x1002
DMA1 status phai co 0x1000 hoac 0x1002
DMA2 status phai co 0x1000 hoac 0x1002
```

4. Cac buffer co aligned 64 byte khong?

5. Co flush/invalidate cache dung khong?

6. `A_SIZE` co la 32 khong?

7. `MATRIX_A_BYTES`, `MATRIX_B_BYTES`, `MATRIX_C_BYTES` co la 1024 khong?

8. Co dang dung bitstream moi nhat khong?

9. Co update platform/XSA moi nhat khong?

10. Neu van loi, can xem RTL waveform hoac chen ILA vao cac signal:

```text
feature_axis_tvalid/tready/tdata/tlast
weight_axis_tvalid/tready/tdata/tlast
result_axis_tvalid/tready/tdata/tlast
shift internal
F_length internal
F_width_block_num internal
W_width_block_num internal
GEMM FSM state
Out_buffer valid/last
```

---

## 15. Ket luan ban giao

He thong hien tai da chay pass GEMM 32x32 INT8 bang AXI DMA tren KV260.

Tuy nhien, co mot diem can canh giac trong RTL:

```text
Config register cua GEMM_core co the dang latch theo kieu chi update khi input thay doi.
```

Workaround software bang cach force write config da giup test PASS, nhung ve lau dai nen sua RTL de latch config ro rang theo reset/start/config_valid.

Khuyen nghi cho nguoi tiep tuc:

```text
1. Giu lai app PASS hien tai lam baseline.
2. Khong sua nhieu thu cung luc.
3. Neu sua RTL, chi sua config latch truoc.
4. Rebuild bitstream/XSA/app day du.
5. Chay lai UART -> AXI-Lite -> GEMM compare theo dung thu tu.
6. Them identity matrix test de lam demo/thuyet trinh.
```

