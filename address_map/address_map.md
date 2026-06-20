# Address Map - GEMM 32x32 KV260

This document records the hardware memory map and software register usage for the GEMM 32x32 INT8 accelerator project on KV260/K26.

## 1. Target Platform

| Item | Value |
|---|---|
| Board | Xilinx KV260 Vision AI Starter Kit |
| SOM / Device | K26, `xck26-sfvc784-2LV-c` |
| Board part | `xilinx.com:kv260_som:part0:1.4` |
| Tool version used | Vivado / Vitis 2022.2 |
| Processing system | Zynq UltraScale+ MPSoC |
| CPU used by bare-metal app | `psu_cortexa53_0` |
| UART used | `psu_uart_1`, 115200 baud |

## 2. High-Level Data Path

The design uses three AXI DMA IP blocks and one custom GEMM IP.

```text
DDR memory
   |
   |  AXI MM2S
   v
axi_dma_0  -------------------->  GEMM_top.feature_axis
                                  |
DDR memory                        |
   |                              |
   |  AXI MM2S                    |
   v                              v
axi_dma_1  -------------------->  GEMM_top.weight_axis

GEMM_top.result_axis ---------->  axi_dma_2
                                      |
                                      | AXI S2MM
                                      v
                                  DDR memory
```

Control is done through AXI-Lite:

```text
Cortex-A53
   |
   | AXI-Lite
   v
AXI Interconnect
   |
   +--> axi_dma_0/S_AXI_LITE
   +--> axi_dma_1/S_AXI_LITE
   +--> axi_dma_2/S_AXI_LITE
   +--> GEMM_top/S_AXI
```

## 3. Main Address Map

These addresses are generated in `xparameters.h` after exporting the hardware platform and building the Vitis platform.

| Block | Purpose | Base Address | Macro |
|---|---|---:|---|
| `axi_dma_0` | Feature input DMA, MM2S only | `0xA0000000` | `XPAR_AXI_DMA_0_BASEADDR` |
| `axi_dma_1` | Weight input DMA, MM2S only | `0xA0010000` | `XPAR_AXI_DMA_1_BASEADDR` |
| `axi_dma_2` | Result output DMA, S2MM only | `0xA0020000` | `XPAR_AXI_DMA_2_BASEADDR` |
| `GEMM_top_0` | Custom GEMM control registers | `0xA0030000` | `XPAR_GEMM_TOP_0_BASEADDR` |

Recommended aliases in `Defines.h`:

```c
#define MM_ADDR             XPAR_GEMM_TOP_0_BASEADDR

#define FEATURE_DMA_ADDR    XPAR_AXI_DMA_0_BASEADDR
#define WEIGHT_DMA_ADDR     XPAR_AXI_DMA_1_BASEADDR
#define RESULT_DMA_ADDR     XPAR_AXI_DMA_2_BASEADDR

#define A_SIZE 32
```

## 4. GEMM Control Register Map

`GEMM_top` is controlled through AXI-Lite. The current software uses the following offsets:

| Register | Offset | Address expression | Meaning |
|---|---:|---|---|
| `SHIFT` | `0x00` | `MM_ADDR + 0x00` | Right shift amount after MAC accumulation |
| `F_length` | `0x04` | `MM_ADDR + 0x04` | Number of feature rows |
| `F_width_block_num` | `0x08` | `MM_ADDR + 0x08` | Number of feature width blocks |
| `W_width_block_num` | `0x0C` | `MM_ADDR + 0x0C` | Number of weight/output width blocks |

For the current 32x32 test:

| Parameter | Value |
|---|---:|
| `A_SIZE` | `32` |
| `F_length` | `32` |
| `F_width_block_num` | `1` |
| `W_width_block_num` | `1` |
| `SHIFT` | `0` |

## 5. AXI DMA Register Offsets

The software uses the standard Xilinx AXI DMA register layout.

### MM2S channel

Used by:

- `axi_dma_0` for feature matrix A
- `axi_dma_1` for weight matrix B

| Register | Offset | Meaning |
|---|---:|---|
| `MM2S_DMACR` | `0x00` | MM2S control |
| `MM2S_DMASR` | `0x04` | MM2S status |
| `MM2S_SA` | `0x18` | Source address low 32 bits |
| `MM2S_SA_MSB` | `0x1C` | Source address high 32 bits |
| `MM2S_LENGTH` | `0x28` | Transfer length in bytes |

### S2MM channel

Used by:

- `axi_dma_2` for result matrix C

| Register | Offset | Meaning |
|---|---:|---|
| `S2MM_DMACR` | `0x30` | S2MM control |
| `S2MM_DMASR` | `0x34` | S2MM status |
| `S2MM_DA` | `0x48` | Destination address low 32 bits |
| `S2MM_DA_MSB` | `0x4C` | Destination address high 32 bits |
| `S2MM_LENGTH` | `0x58` | Transfer length in bytes |

Common status values seen during testing:

| Value | Meaning |
|---:|---|
| `0x00000001` | DMA halted before transfer |
| `0x00001002` | Transfer done; IOC interrupt bit set and channel idle |

## 6. Matrix Transfer Sizes

For 32x32 INT8 GEMM:

| Buffer | Matrix | Size calculation | Bytes |
|---|---|---:|---:|
| Feature input | A, 32x32 INT8 | `32 * 32 * 1` | `1024` |
| Weight input | B, 32x32 INT8 | `32 * 32 * 1` | `1024` |
| Result output | C, 32x32 INT8 | `32 * 32 * 1` | `1024` |

The AXI Stream data width is 256 bits, so one AXIS beat is 32 bytes. Therefore, each 1024-byte matrix corresponds to:

```text
1024 / 32 = 32 AXI Stream beats
```

## 7. DMA Start Order

The recommended order is:

```text
1. Write GEMM control registers.
2. Flush CPU cache for feature, weight, and result buffers.
3. Start DMA2 S2MM first, so the result channel is ready to receive data.
4. Start DMA0 MM2S for feature matrix A.
5. Start DMA1 MM2S for weight matrix B.
6. Wait for DMA0, DMA1, and DMA2 done.
7. Invalidate result buffer cache.
8. Compare hardware result with software result.
```

This order avoids the GEMM result stream being blocked because S2MM is not ready.

## 8. Important Software Workaround

During debugging, the first run produced:

```text
DMA0 feature done
DMA1 weight done
DMA2 result done
C_hw all zero
COMPARE FAIL
```

After forcing the GEMM control registers to change once before writing the real configuration, the design produced correct results:

```c
volatile u32 delay;

Xil_Out32(SHIFT_ADDR, 1);
Xil_Out32(FL_ADDR, 31);
Xil_Out32(FWBN_ADDR, 2);
Xil_Out32(WWBN_ADDR, 2);

for (delay = 0; delay < 100000; delay++);

Xil_Out32(SHIFT_ADDR, 0);
Xil_Out32(FL_ADDR, 32);
Xil_Out32(FWBN_ADDR, 1);
Xil_Out32(WWBN_ADDR, 1);

for (delay = 0; delay < 100000; delay++);
```

This is a software workaround. The suspected RTL issue is that some internal config registers in the GEMM core are only updated when the input value changes. If the reset/default internal value and the first software value cause no detected change, the real config may not latch as expected.

Long-term RTL recommendation:

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

Do not rely forever on the software workaround if this project is developed further.

## 9. Reset / Clock Note

The AXI-Lite bus originally hung at the first DMA register read. The issue was related to the reset system. The `proc_sys_reset` block must have `dcm_locked` driven high.

Required connection:

```text
xlconstant dout = 1'b1  --->  rst_ps8_0_99M/dcm_locked
```

Without this, PL reset may remain active, causing AXI-Lite transactions to hang.

## 10. Known Vitis GUI Issue

The Vitis GUI Run Configuration sometimes produced:

```text
can't read "map": no such variable
```

The workaround is to run through XSCT manually:

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

## 11. Final Verified Output

The project was verified with the following result:

```text
DMA0 feature done, status=0x00001002
DMA1 weight done, status=0x00001002
DMA2 result done, status=0x00001002
COMPARE PASS
```

This confirms that the 32x32 INT8 GEMM hardware result matched the software result.
