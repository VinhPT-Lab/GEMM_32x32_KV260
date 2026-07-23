# Hardware Architecture

## 1. Overview

The accelerator is a 32 x 32 weight-stationary INT8 GEMM engine for the Xilinx Kria KV260. It receives packed feature and weight vectors over independent AXI4-Stream inputs, performs tiled matrix multiplication in a 1,024-PE systolic array, accumulates partial results across K blocks, applies output quantization, and returns packed INT8 result vectors over AXI4-Stream.

The design is separated into two architectural levels:

1. The KV260 system level: Processing System, DDR, AXI DMA engines, control bus, and streaming data paths.
2. The accelerator level: stream adapters, configuration/status logic, input buffering, tile scheduling, systolic computation, accumulation, and output quantization.

## 2. KV260 System Architecture

![KV260 GEMM system architecture](images/system-architecture.png)

The system contains one GEMM accelerator and three AXI DMA instances.

| Component | Role |
|---|---|
| Processing System | Configures GEMM and DMA registers through AXI4-Lite |
| DDR memory subsystem | Stores feature, weight, and result buffers |
| DMA0 | Reads feature data from DDR and produces the feature AXI4-Stream |
| DMA1 | Reads weight data from DDR and produces the weight AXI4-Stream |
| DMA2 | Accepts the result AXI4-Stream and writes results to DDR |
| GEMM accelerator | Executes tiled signed INT8 matrix multiplication |

The DMA engines are AXI4 memory-mapped masters toward DDR. The GEMM IP is an AXI4-Lite slave for control and uses AXI4-Stream for bulk data transfer.

## 3. GEMM Top-Level Interface

![GEMM top-level interface](images/gemm-top-interface.png)

The synthesizable top-level module is `GEMM_top`. It exposes four external interface groups.

| Interface | Direction at GEMM | Width | Function |
|---|---|---:|---|
| AXI4-Lite control | Slave | 32-bit data | Configuration writes and status reads |
| Feature AXI4-Stream | Slave | 256-bit data | Packed signed INT8 feature values |
| Weight AXI4-Stream | Slave | 256-bit data | Packed signed INT8 weight values |
| Result AXI4-Stream | Master | 256-bit data | Packed signed INT8 results |

Each 256-bit stream beat carries 32 signed 8-bit lanes. Feature and weight adapters require a full beat (`TSTRB = 32'hFFFF_FFFF`). The result adapter always drives all `TSTRB` bits high and propagates downstream backpressure through `result_axis_tready`.

`GEMM_top` also owns the software-visible `busy`, `done`, and `idle` state. A separate start register is not used. The first accepted feature or weight beat starts job activity; the final accepted result beat completes the job.

Register definitions and stream ordering are specified in the [Software Programming Model](programming-model.md).

## 4. GEMM Core Organization

![GEMM core datapath](images/gemm-core-datapath.png)

`GemmAccelerator` is the main datapath wrapper. It freezes the active configuration and instantiates three principal blocks.

| Block | Responsibility |
|---|---|
| `InputBuffer` | Stores complete feature and weight input streams and replays the selected K tile |
| `BufferFeeder` | Buffers one working tile, loads weights, and schedules feature rows into the compute core |
| `OutputBuffer` | Accumulates partial sums across K blocks, quantizes results, and generates the result stream |

The dashed `w_compute_partial_last` path is completion feedback from the compute scheduler. It advances `InputBuffer` to the next buffered K block and increments K-block completion state in `OutputBuffer`.

### Configuration inputs

| Configuration | Meaning |
|---|---|
| `shift` | Arithmetic right-shift amount used during final requantization |
| `row_count` | Number of M rows processed by the job |
| `k_block_count` | Number of 32-element blocks in K |
| `n_block_count` | Number of 32-column blocks in N |

`GemmAccelerator` copies these values into internal registers only while the core is inactive. Writes made during an active job do not alter that job.

## 5. Input Buffering

`InputBuffer` independently accepts feature and weight AXI4-Stream beats and stores them in block-RAM-style memories.

The expected input counts are:

```text
feature beats = row_count x k_block_count
weight beats  = k_block_count x 32 x n_block_count
```

Readout begins only after both expected counts have been received. For each K block, `InputBuffer` replays:

- one feature beat for each output row; and
- `n_block_count x 32` weight beats for the corresponding K tile.

Feature memory is addressed as `row * k_block_count + k_block`. Weight memory is read sequentially for the selected tile. Input `TLAST` must be asserted only on the final beat of the complete feature or weight job because it resets the associated write address.

The default feature and weight memory depths are 2,400 words each. At 256 bits per word, each buffer stores 76,800 bytes, approximately 75 KiB.

## 6. Tile Scheduling

`BufferFeeder` receives replayed data from `InputBuffer` and alternates between two phases:

1. **Weight-load phase:** 32 weight words are loaded into the compute core for the active N block.
2. **Feature-compute phase:** buffered feature rows are streamed through the array using the stationary weight tile.

The process repeats across N blocks and K blocks. `BufferFeeder` generates packed partial-sum data together with `partial_valid` and `partial_last` markers.

## 7. Compute Core and Systolic Array

![32 x 32 weight-stationary systolic array](images/systolic-array-architecture.png)

`GemmComputeCore` contains the working weight storage and the `ProcessingElementArray`. A complete 32-row weight tile is loaded before feature execution begins.

### Weight-stationary behavior

- Each PE stores one signed INT8 weight during the weight-load phase.
- Feature values move horizontally across each processing-element row.
- Partial sums move vertically through the array.
- The array produces 32 partial-sum lanes for each feature row.

### Processing element

Each `ProcessingElement` performs a signed multiply-add:

```text
partial_sum_out = delayed_partial_sum_in + feature x stored_weight
```

For the current parameters:

| Quantity | Width |
|---|---:|
| Feature | 8-bit signed |
| Weight | 8-bit signed |
| Product | 16-bit signed |
| PE partial sum | 21-bit signed (`2 x 8 + 5`) |

The Xilinx `mult_IP` is configured as a signed 8 x 8 multiplier with one pipeline stage.

## 8. Pipeline Alignment

The compute pipeline constants are:

```text
multiplier latency = 1 cycle
PE total latency   = multiplier latency + 1 = 2 cycles
result latency     = 2 x array_rows + array_cols
```

For a 32 x 32 array, the result-valid alignment delay is 96 cycles. `GemmComputeCore` delays `partial_valid` and `partial_last` so that they align with the output vector of the systolic array.

This latency assumes the generated multiplier remains configured for one pipeline stage. Changing `mult_IP` latency requires the RTL alignment constants to be updated and reverified.

## 9. Partial-Sum Accumulation and Output Quantization

`OutputBuffer` stores one 32-lane accumulation word per output row and N block. The expected result count is:

```text
result beats = row_count x n_block_count
```

For every valid partial vector, the module:

1. sign-extends each 21-bit PE result to 32 bits;
2. reads the previous 32-bit accumulation value;
3. performs lane-wise signed saturating addition through `SignedAdder`; and
4. writes the updated value back to the output memory.

After all configured K blocks complete, each 32-bit lane is passed through `RightShifter`. The module applies an arithmetic right shift, uses the discarded high bit as a rounding bit, and saturates the final value to the signed INT8 range `[-128, 127]`.

Result order is row-major with the N block inside each row:

```text
for row in 0 .. row_count-1
    for n_block in 0 .. n_block_count-1
        emit one 256-bit result beat
```

## 10. Control and Handshake Behavior

- Feature and weight inputs use independent `TVALID/TREADY` handshakes.
- Partial feature/weight beats are rejected by the stream adapters.
- Result data uses `TVALID/TREADY` and asserts `TLAST` on the final result beat.
- `done` is set only after the final result beat is accepted.
- A clear request is accepted only while the core is idle.

The current `OutputBuffer` begins its output-memory pipeline when `i_result_ready` is asserted. Therefore, software must start and enable the result S2MM channel before the two input MM2S channels.

## 11. Clock and Reset

All PL AXI interfaces and accelerator logic should use the same PL clock. The verified design uses a 100 MHz PL clock.

All active-low PL resets should be driven from the processor-system-reset peripheral reset output. If the reset block uses `dcm_locked`, that input must be asserted by a valid lock source; otherwise the PL can remain in reset and AXI4-Lite accesses can hang.

## 12. Capacity Constraints

Software must satisfy both register-width limits and memory-depth limits.

| Constraint | Current limit |
|---|---:|
| `row_count` register | 9 bits, maximum 511 |
| `k_block_count` register | 5 bits, maximum 31 |
| `n_block_count` register | 5 bits, maximum 31 |
| Feature buffer | `row_count x k_block_count <= 2400` beats |
| Weight buffer | `k_block_count x 32 x n_block_count <= 2400` beats |
| Output buffer | `row_count x n_block_count <= 2400` beats |

Larger matrices are supported by software partitioning into multiple hardware jobs. The current Linux integration uses bounded M chunks and N tiles; those policy limits are documented in [Linux and llama.cpp Integration](linux-llama-integration.md).
