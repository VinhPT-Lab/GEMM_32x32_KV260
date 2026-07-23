# Shape-Aware INT8 GEMM Accelerator on Kria KV260

This repository implements a 32 x 32 weight-stationary INT8 GEMM accelerator for the Xilinx Kria KV260. The design combines a 1,024-processing-element systolic array with AXI4-Lite control, three AXI DMA engines, 256-bit AXI4-Stream data paths, and a Linux integration path for selective `llama.cpp` offload.

## Highlights

- 32 x 32 weight-stationary systolic array (1,024 processing elements)
- Signed INT8 feature and weight inputs
- 32-bit inter-tile accumulation followed by right shift and INT8 saturation
- Two 256-bit AXI4-Stream inputs and one 256-bit AXI4-Stream output
- AXI4-Lite configuration and status interface
- Three-DMA architecture: feature MM2S, weight MM2S, and result S2MM
- Bare-metal 32 x 32 hardware verification with `COMPARE PASS`
- Linux coherent-DMA driver and shape-aware `llama.cpp` integration
- CPU fallback for unsupported or low-efficiency GEMM shapes

## System Architecture

![KV260 GEMM system architecture](docs/images/system-architecture.png)

The Processing System configures the accelerator and the AXI DMA engines through AXI4-Lite. Feature and weight data are read from DDR by two MM2S channels, while the result stream is written back to DDR by an S2MM channel.

## Hardware Summary

| Item | Current implementation |
|---|---|
| Target | Xilinx Kria KV260 / K26 |
| Tool flow | Vivado and Vitis 2022.2 |
| PL clock | 100 MHz |
| Array | 32 x 32 weight-stationary |
| Processing elements | 1,024 |
| Feature / weight | Signed INT8 |
| PE product | Signed 16-bit |
| PE partial sum | 21-bit |
| Output accumulation | Signed 32-bit |
| Stream width | 256 bits (32 INT8 values per beat) |
| Peak compute | 102.4 GMAC/s (204.8 GOPS when multiply and add are counted separately) |

## Implementation Results

| Resource | Utilization |
|---|---:|
| LUT | 39,781 / 117,120 (33.97%) |
| FF | 85,656 / 234,240 (36.57%) |
| BRAM | 111 / 144 (77.08%) |
| URAM | 8 / 64 (12.50%) |
| DSP48E2 | 1,025 / 1,248 (82.13%) |
| WNS | +3.055 ns |

## Verified Bare-Metal Baseline

```text
DMA0 feature done, status=0x00001002
DMA1 weight done, status=0x00001002
DMA2 result done, status=0x00001002
GEMM done, status=0x06000000
COMPARE PASS
```

## End-to-End Throughput

![CPU-only and CPU+FPGA throughput](docs/images/system-throughput.png)

The selective CPU+FPGA path improves prompt-processing throughput while keeping token-generation GEMMs on the CPU. The decode path remains close to the CPU-only baseline because small-M operations are intentionally excluded from FPGA execution.

| Workload | CPU-only prefill | CPU+FPGA prefill | Speedup | CPU-only decode | CPU+FPGA decode |
|---|---:|---:|---:|---:|---:|
| P32-N64 | 8.64 tok/s | 18.84 tok/s | 2.18x | 5.90 tok/s | 5.64 tok/s |
| P128-N64 | 8.65 tok/s | 25.07 tok/s | 2.90x | 5.88 tok/s | 5.70 tok/s |
| P512-N64 | 8.53 tok/s | 24.12 tok/s | 2.83x | 5.87 tok/s | 5.67 tok/s |

## Documentation

- [Documentation index](docs/README.md)
- [Hardware architecture](docs/architecture.md)
- [Software programming model](docs/programming-model.md)
- [Bare-metal bring-up](docs/baremetal-bringup.md)
- [Linux and llama.cpp integration](docs/linux-llama-integration.md)
- [RTL module reference](docs/rtl-module-reference.md)

## Current Scope

The RTL is a reusable tiled INT8 GEMM engine. The current `llama.cpp` path is intentionally narrower: it targets high-MAC prefill GEMMs, partitions large dimensions into bounded hardware tiles, reuses packed weights, and falls back deterministically to the CPU when a tensor does not satisfy the supported shape, layout, or quantization constraints.
