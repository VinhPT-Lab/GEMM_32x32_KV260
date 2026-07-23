# Software Programming Model

## 1. Scope

This document is the source of truth for software that controls the current `GEMM_top` IP. It defines the current AXI address map, GEMM registers, status behavior, stream layouts, matrix tiling, DMA programming order, cache requirements, and job lifecycle.

The accelerator computes a tiled signed INT8 matrix product:

```text
C[M, N] = A[M, K] x B[K, N]
```

The hardware array dimension is 32. K and N are represented as counts of 32-element blocks.

## 2. External Interfaces

| Interface | Direction at GEMM | Width | Purpose |
|---|---|---:|---|
| AXI4-Lite | Slave | 32-bit data | Configuration and status |
| Feature AXI4-Stream | Slave | 256-bit | Matrix A data |
| Weight AXI4-Stream | Slave | 256-bit | Matrix B data |
| Result AXI4-Stream | Master | 256-bit | Matrix C data |

There is no separate start bit. A job becomes active when the first feature or weight stream beat is accepted.

## 3. Current AXI Address Map

The addresses below are the verified baseline. They are generated in `xparameters.h` after exporting the Vivado hardware platform.

| Block | Function | Base address | Vitis macro |
|---|---|---:|---|
| `GEMM_DSP_IP_0` | GEMM configuration and status | `0xA0000000` | `XPAR_GEMM_DSP_IP_0_BASEADDR` |
| `axi_dma_0` | Feature MM2S | `0xA0010000` | `XPAR_AXI_DMA_0_BASEADDR` |
| `axi_dma_1` | Weight MM2S | `0xA0020000` | `XPAR_AXI_DMA_1_BASEADDR` |
| `axi_dma_2` | Result S2MM | `0xA0030000` | `XPAR_AXI_DMA_2_BASEADDR` |

Recommended aliases:

```c
#define GEMM_BASE_ADDR       XPAR_GEMM_DSP_IP_0_BASEADDR
#define FEATURE_DMA_ADDR     XPAR_AXI_DMA_0_BASEADDR
#define WEIGHT_DMA_ADDR      XPAR_AXI_DMA_1_BASEADDR
#define RESULT_DMA_ADDR      XPAR_AXI_DMA_2_BASEADDR
```

Do not edit `xparameters.h` manually. After a block-design or address-map change, regenerate the bitstream, export the hardware, rebuild the Vitis platform, and verify the generated macros.

## 4. GEMM Register Map

| Offset | Register | Access | Description |
|---:|---|---|---|
| `0x00` | `SHIFT_STATUS` | RW / RO mixed | Write shift and clear request; read shift and job status |
| `0x04` | `ROW_COUNT` / `F_length` | RW | Number of M rows |
| `0x08` | `K_BLOCK_COUNT` / `F_width_block_num` | RW | Number of 32-element K blocks |
| `0x0C` | `N_BLOCK_COUNT` / `W_width_block_num` | RW | Number of 32-column N blocks |

Use full-word writes (`WSTRB = 4'b1111`) unless byte writes are deliberately required.

### 4.1 `SHIFT_STATUS` write fields

| Bits | Name | Description |
|---:|---|---|
| `[9:0]` | `shift` | Arithmetic right-shift amount used for output quantization |
| `[16]` | `clear_done` | Write `1` to request status clear while idle |

To clear `done` without changing the shift value:

```c
write32(GEMM_BASE_ADDR + 0x00, (shift & 0x3FFu) | (1u << 16));
```

### 4.2 `SHIFT_STATUS` read fields

| Bits | Name | Description |
|---:|---|---|
| `[9:0]` | `shift` | Current stored shift value |
| `[23:10]` | Reserved | Reads as zero |
| `[24]` | `busy` | Job activity is present |
| `[25]` | `done` | Final result beat has been accepted |
| `[26]` | `idle` | Inverse of `busy` |
| `[27]` | `clear_accepted` | One-cycle pulse after a clear request is accepted while idle |
| `[28]` | `clear_busy_error` | One-cycle pulse after a clear request is attempted while busy |
| `[31:29]` | Reserved | Reads as zero |

Bits 27 and 28 are pulse-like diagnostic fields and can be missed by slow software polling.

### 4.3 Dimension registers

```c
row_count     = M;
k_block_count = (K + 31) / 32;
n_block_count = (N + 31) / 32;
```

The register widths are:

| Register | Width | Encoded range |
|---|---:|---:|
| `row_count` | 9 bits | 0 to 511 |
| `k_block_count` | 5 bits | 0 to 31 |
| `n_block_count` | 5 bits | 0 to 31 |

Zero dimensions are not valid jobs.

## 5. Job Lifecycle

### 5.1 Configuration sequence

1. Poll `SHIFT_STATUS` until `idle = 1`.
2. If `done = 1`, write `clear_done = 1` while preserving the desired shift.
3. Write the desired shift to `0x00`.
4. Write `row_count` to `0x04`.
5. Write `k_block_count` to `0x08`.
6. Write `n_block_count` to `0x0C`.
7. Prepare and synchronize the DMA buffers.
8. Start result S2MM first.
9. Start feature MM2S.
10. Start weight MM2S.

### 5.2 Active configuration freeze

`GemmAccelerator` copies the four configuration fields into internal registers while inactive. Once input, internal compute, or output activity begins, those frozen values control the active job.

Software writes made during a job can change the AXI4-Lite readback registers but do not change the active computation. Configure a job only while idle.

### 5.3 Completion

`busy` clears and `done` sets when the final result beat completes a `TVALID && TREADY && TLAST` handshake. A clear request made while busy does not abort the job.

## 6. AXI4-Stream Rules

All streams use 256-bit `TDATA`, which contains 32 signed INT8 lanes.

| Lane | Bit range |
|---:|---|
| 0 | `[7:0]` |
| 1 | `[15:8]` |
| ... | ... |
| 31 | `[255:248]` |

Feature and weight beats must be full:

```text
TSTRB = 32'hFFFF_FFFF
```

A partial input beat does not receive `TREADY`. `TLAST` must be asserted only on the final beat of the complete input stream.

## 7. Feature Input Layout

Each feature beat contains one 32-element K slice from one row of A.

```text
for row = 0 .. row_count-1
    for k_block = 0 .. k_block_count-1
        send one 256-bit beat
```

Within the beat:

```text
A[row, k_block x 32 + lane] -> lane
```

Pad lanes beyond the true K dimension with zero.

Feature beat count and bytes:

```text
feature_beats = row_count x k_block_count
feature_bytes = feature_beats x 32
```

## 8. Weight Input Layout

Each weight beat contains 32 output-column values for one K element and one N block.

```text
for k_block = 0 .. k_block_count-1
    for k_lane = 0 .. 31
        for n_block = 0 .. n_block_count-1
            send one 256-bit beat
```

Within the beat:

```text
B[k_block x 32 + k_lane, n_block x 32 + lane] -> lane
```

Pad entries beyond the true K or N dimension with zero.

Weight beat count and bytes:

```text
weight_beats = k_block_count x 32 x n_block_count
weight_bytes = weight_beats x 32
```

## 9. Result Output Layout

Each result beat contains 32 output columns from one row of C.

```text
for row = 0 .. row_count-1
    for n_block = 0 .. n_block_count-1
        receive one 256-bit beat
```

Within the beat:

```text
lane -> C[row, n_block x 32 + lane]
```

Ignore padded lanes beyond the true N dimension.

Result beat count and bytes:

```text
result_beats = row_count x n_block_count
result_bytes = result_beats x 32
```

The result stream asserts `TLAST` on the final beat.

## 10. Capacity Checks

The default feature, weight, and output memories each have a depth of 2,400 stream words. Software must reject or partition a job unless all constraints hold:

```text
row_count x k_block_count             <= 2400
k_block_count x 32 x n_block_count    <= 2400
row_count x n_block_count             <= 2400
```

For example, a Qwen K dimension of 896 has `k_block_count = 28`. With the current 2,400-word weight buffer, one hardware invocation can contain at most two N blocks (`N_tile <= 64`). Wider N dimensions must be partitioned by software.

## 11. AXI DMA Register Offsets

The design uses Xilinx AXI DMA simple mode.

### 11.1 MM2S channel - DMA0 and DMA1

| Register | Offset |
|---|---:|
| `MM2S_DMACR` | `0x00` |
| `MM2S_DMASR` | `0x04` |
| `MM2S_SA` | `0x18` |
| `MM2S_SA_MSB` | `0x1C` |
| `MM2S_LENGTH` | `0x28` |

### 11.2 S2MM channel - DMA2

| Register | Offset |
|---|---:|
| `S2MM_DMACR` | `0x30` |
| `S2MM_DMASR` | `0x34` |
| `S2MM_DA` | `0x48` |
| `S2MM_DA_MSB` | `0x4C` |
| `S2MM_LENGTH` | `0x58` |

Write the DMA buffer address first and write `LENGTH` last. Writing `LENGTH` starts a simple-mode transfer.

## 12. Required DMA Order

The verified order is:

1. Configure GEMM.
2. Reset or clear DMA channels if required.
3. Synchronize input and output buffers.
4. Start DMA2 result S2MM.
5. Start DMA0 feature MM2S.
6. Start DMA1 weight MM2S.
7. Wait for feature DMA completion.
8. Wait for weight DMA completion.
9. Wait for result DMA completion.
10. Check GEMM completion.
11. Synchronize/invalidate the result buffer.
12. Compare against a software reference.

The S2MM channel must be active first because the current output pipeline waits for result readiness before beginning result-memory streaming.

## 13. Cache and Alignment

One stream beat is 32 bytes. Use at least 32-byte alignment; the verified bare-metal software uses 64-byte alignment.

```cpp
alignas(64) static int8_t A_buf[A_BYTES];
alignas(64) static int8_t B_buf[B_BYTES];
alignas(64) static int8_t C_hw[C_BYTES];
```

With the bare-metal data cache enabled:

```c
Xil_DCacheFlushRange((INTPTR)A_buf, A_BYTES);
Xil_DCacheFlushRange((INTPTR)B_buf, B_BYTES);
Xil_DCacheFlushRange((INTPTR)C_hw, C_BYTES);

/* After S2MM completion */
Xil_DCacheInvalidateRange((INTPTR)C_hw, C_BYTES);
```

Linux uses coherent driver-allocated buffers in the current integration and must not pass ordinary `malloc()` virtual addresses to DMA.

## 14. 32 x 32 Example

For `M = K = N = 32`:

```text
shift         = 0
row_count     = 32
k_block_count = 1
n_block_count = 1
```

Each matrix uses 1,024 bytes and 32 stream beats.

```c
write32(GEMM_BASE_ADDR + 0x00, 0);
write32(GEMM_BASE_ADDR + 0x04, 32);
write32(GEMM_BASE_ADDR + 0x08, 1);
write32(GEMM_BASE_ADDR + 0x0C, 1);
```

Expected idle readback before the job:

```text
SHIFT_STATUS = 0x04000000
ROW_COUNT    = 0x00000020
K_BLOCKS     = 0x00000001
N_BLOCKS     = 0x00000001
```

Typical successful completion:

```text
DMA0 DMASR = 0x00001002
DMA1 DMASR = 0x00001002
DMA2 DMASR = 0x00001002
GEMM status = 0x06000000
```

## 15. Software Safety Checks

A production caller should enforce:

- nonzero M, K, and N;
- register-width limits;
- all three buffer-depth constraints;
- full 256-bit stream beats;
- zero padding for incomplete K/N blocks;
- result S2MM started before input MM2S;
- bounded polling timeouts;
- DMA error-bit checks;
- GEMM `done` verification; and
- CPU-reference comparison during bring-up and regression tests.
