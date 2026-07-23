# Linux and llama.cpp Integration

## 1. Purpose

This guide documents the current Linux execution path for the KV260 GEMM accelerator and its selective integration into `llama.cpp`. The implemented flow uses an FPGA overlay, a custom coherent DMA-buffer kernel module, AXI4-Lite/DMA control from the runtime, and a shape-aware hook in `ggml_compute_forward_mul_mat`.

This is not a generic list of possible Linux DMA methods. It describes the current project implementation.

## 2. Current Platform

| Item | Current environment |
|---|---|
| Board | Xilinx Kria KV260 |
| OS | Ubuntu 22.04.4 LTS |
| Kernel | `5.15.0-1027-xilinx-zynqmp` |
| CPU | 4 x Cortex-A53 at 1.333 GHz |
| PL clock | 100 MHz |
| Model used for evaluation | Qwen2.5-0.5B-Instruct-Q4_K_M |
| Runtime | Modified `llama.cpp` / GGML |

## 3. Linux Startup Sequence

1. Boot the KV260 Linux image.
2. Load the GEMM FPGA application/overlay.
3. Confirm the FPGA manager is operating.
4. Load the coherent DMA-buffer kernel module.
5. Confirm `/dev/gemm_dma_buf` exists.
6. Run an AXI4-Lite smoke test.
7. Run a small GEMM comparison test.
8. Start the modified `llama.cpp` runtime only after both tests pass.

Typical overlay command:

```bash
sudo xmutil loadapp gemm_dsp_app
```

The accelerator and DMA register bases remain:

| Block | Base address |
|---|---:|
| GEMM | `0xA0000000` |
| Feature DMA | `0xA0010000` |
| Weight DMA | `0xA0020000` |
| Result DMA | `0xA0030000` |

Detailed register and stream definitions are in the [Software Programming Model](programming-model.md).

## 4. Coherent DMA-Buffer Driver

The current kernel module is:

```text
gemm_dma_buf_large_weight400m.ko
```

It exposes:

```text
/dev/gemm_dma_buf
```

The driver allocates coherent buffers so user space receives CPU mappings while the DMA engines receive valid DMA/physical addresses.

### Buffer capacities

| Buffer | Role | Capacity |
|---|---|---:|
| A | Feature / activation input | 64 MiB |
| B | Packed weight input | 400 MiB |
| C | Result output | 64 MiB |

### IOCTL layouts

The driver retains a compatible request and provides an extended request:

```c
struct gemm_dma_info_compat {
    uint64_t a_phys;
    uint64_t b_phys;
    uint64_t c_phys;
    uint32_t size;
};

struct gemm_dma_info_ext {
    uint64_t a_phys;
    uint64_t b_phys;
    uint64_t c_phys;
    uint64_t a_size;
    uint64_t b_size;
    uint64_t c_size;
};
```

### `mmap` selection

| Page offset | Mapped buffer |
|---:|---|
| `0 x PAGE_SIZE` | A / feature |
| `1 x PAGE_SIZE` | B / weight |
| `2 x PAGE_SIZE` | C / result |

Normal heap pointers must never be programmed into the DMA engines.

## 5. GEMM Runtime Flow

For every admitted hardware tile, the runtime:

1. Checks tensor type, dimensions, layout, contiguity, alignment, and hardware scope.
2. Packs or reuses the INT8 weight tile.
3. Quantizes/packs the activation tile.
4. Writes `shift`, `row_count`, `k_block_count`, and `n_block_count`.
5. Starts result S2MM.
6. Starts feature MM2S.
7. Starts weight MM2S.
8. Waits for all three DMA channels.
9. Checks GEMM completion.
10. Restores the INT8 output to the GGML destination representation.
11. Falls back to the normal CPU implementation on any unsupported condition or recoverable hardware error.

The complete offload cost is treated as:

```text
T_offload = T_check + T_prepare + T_DMA + T_sync + T_PL + T_restore
```

Packed-weight reuse reduces `T_prepare`, but eligibility checks, synchronization, DMA setup, and output restoration remain.

## 6. llama.cpp Hook

The offload decision is made inside:

```cpp
ggml_compute_forward_mul_mat()
```

For the GGML matrix-multiplication convention used by the integration:

| GEMM dimension | GGML dimension |
|---|---|
| M | `ne11` - activation rows/tokens |
| K | `ne00` - weight row length / inner dimension |
| N | `ne01` - number of weight rows / output columns |

The hook also checks:

```text
ne10 == ne00
ne0  == ne01
ne1  == ne11
ne2  == 1
ne3  == 1
```

`src0` is the weight tensor and `src1` is the activation tensor.

## 7. Supported Quantization and Packing

The current path supports:

- `Q5_0`
- `Q8_0`
- `Q4_K`

GGML weights are dequantized to floating point as required, requantized into the accelerator's signed INT8 tile format, and stored in a persistent packed-weight cache. The cache avoids repeating the most expensive static weight preparation on later calls.

Feature data are quantized per row/tile and packed as 32 INT8 lanes per 256-bit beat. Weight data follow the K-element / N-block order defined in the programming model.

## 8. Shape-Aware Offload Policy

The selective policy admits only shapes for which expected CPU work is large enough to amortize the full offload path.

### Current main conditions

| Check | Current policy |
|---|---|
| Hardware | FPGA runtime initialized and buffers mapped |
| Tensor layout | Supported, contiguous, and correctly aligned |
| Quantization | `Q5_0`, `Q8_0`, or `Q4_K` |
| K | `K = 896` for the current Qwen integration |
| M | `M >= 32`; decode `M = 1` remains on CPU |
| M partition | At most 64 rows per hardware chunk |
| N partition | At most 64 columns per hardware tile |
| Large N | Partitioned into multiple N tiles, up to the current model scope of 4,864 columns |

Unsupported shapes take a deterministic CPU fallback path and record the reason: shape, type, layout, scope, shift, or hardware readiness.

### Prefill versus decode

- **Prefill:** M is large, the matrix contains substantial MAC work, and selected calls are offloaded.
- **Decode:** M is typically 1, so setup and transfer overhead dominate; these calls remain on CPU.

An inclusive ablation that admits small-M calls is useful for measurement, but it reduces decode throughput.

## 9. Execution and Debug Modes

| Mode | Value | Behavior |
|---|---:|---|
| `CPU_ONLY` | 0 | Execute the normal CPU implementation |
| `FPGA_OUTPUT` | 1 | Use FPGA output for admitted calls |
| `COMPARE` | 2 | Run CPU and FPGA paths and report differences |
| `COMPARE_USE_FPGA` | 3 | Compare both paths and use FPGA output when the comparison passes |

Runtime statistics track:

- total `mul_mat` calls;
- calls by quantization type;
- admitted FPGA calls;
- fallback reasons;
- packed-weight cache hits;
- logical call coverage;
- observed MAC coverage;
- preparation, DMA, PL, and restore timing; and
- numerical mismatch/MAE results.

## 10. Numerical Restoration

The accelerator produces signed INT8 output after right shift and saturation. Software restores the tile to floating point using activation and weight scales. When multiple K tiles are required, software combines tile contributions using the corresponding scaling/shift information.

Comparison mode should remain enabled during development of a new tensor type, packing rule, shape, or shift policy.

## 11. Measured Throughput

![CPU-only and CPU+FPGA throughput](images/system-throughput.png)

| Workload | CPU-only prefill | CPU+FPGA prefill | Speedup | CPU-only decode | CPU+FPGA decode |
|---|---:|---:|---:|---:|---:|
| P32-N64 | 8.64 tok/s | 18.84 tok/s | 2.18x | 5.90 tok/s | 5.64 tok/s |
| P128-N64 | 8.65 tok/s | 25.07 tok/s | 2.90x | 5.88 tok/s | 5.70 tok/s |
| P512-N64 | 8.53 tok/s | 24.12 tok/s | 2.83x | 5.87 tok/s | 5.67 tok/s |

For the long-prompt workload, a small fraction of logical GEMM calls carries most of the observed GEMM MACs. This supports a selective policy based on computational weight rather than raw call count.

Measured operator-level MAE versus the floating-point reference is approximately `0.0108` to `0.0137` for the evaluated offloaded operators.

## 12. Build and Deployment Checklist

Before running the model:

```text
[ ] FPGA overlay loaded successfully
[ ] FPGA manager state is operating
[ ] gemm_dma_buf_large_weight400m.ko loaded
[ ] /dev/gemm_dma_buf exists
[ ] coherent A/B/C buffers mapped
[ ] AXI4-Lite smoke test passes
[ ] 32 x 32 GEMM comparison passes
[ ] llama.cpp binary is AArch64 and links the modified GGML code
[ ] offload mode and statistics are configured
[ ] CPU fallback remains enabled
```

## 13. Common Failure Modes

| Symptom | Likely cause |
|---|---|
| AXI read hangs or bus error | Overlay/PL path not ready or address map mismatch |
| DMA error | Invalid DMA address, length, direction, or channel state |
| DMA completes but output is stale | Incorrect buffer mapping or synchronization |
| Hardware completes but values mismatch | Feature/weight packing, scale, shift, padding, or layout error |
| Decode becomes slower | Small-M calls admitted or repeated eligibility overhead |
| Weight preparation dominates | Packed-weight cache miss or unsupported cache key/layout |

## 14. Current Limitations

- The hardware path is GEMM-only; normalization, RoPE, softmax, activation functions, KV-cache management, and sampling remain on CPU.
- The current model-specific path targets `K = 896` and partitions wider N dimensions.
- Decode GEMMs are deliberately not offloaded.
- Quantization/restoration is approximate relative to full floating-point execution.
- The current result path depends on S2MM readiness and requires the documented DMA start order.
- Buffer capacities and register widths bound each hardware invocation; software tiling is mandatory for larger matrices.
