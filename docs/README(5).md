# Documentation

This directory contains the design, programming, deployment, and RTL reference documentation for the KV260 INT8 GEMM accelerator.

## Recommended Reading Order

| Reader goal | Start here |
|---|---|
| Understand the hardware organization | [Hardware Architecture](architecture.md) |
| Write software for the IP | [Software Programming Model](programming-model.md) |
| Run the verified Vitis bare-metal test | [Bare-Metal Bring-Up](baremetal-bringup.md) |
| Use the accelerator from Linux and `llama.cpp` | [Linux and llama.cpp Integration](linux-llama-integration.md) |
| Look up an RTL module | [RTL Module Reference](rtl-module-reference.md) |

## Documents

### [Hardware Architecture](architecture.md)

Explains the PS-PL system, external GEMM interfaces, core datapath, input buffering, data scheduling, 32 x 32 systolic array, partial-sum accumulation, quantization, pipeline alignment, and design limits.

### [Software Programming Model](programming-model.md)

The source of truth for the current address map, GEMM registers, status bits, AXI4-Stream layouts, tiling formulas, transfer sizes, DMA offsets, DMA start order, cache maintenance, and software-visible job lifecycle.

### [Bare-Metal Bring-Up](baremetal-bringup.md)

Documents the verified Vivado/Vitis 2022.2 flow, XSCT launch sequence, smoke test, 32 x 32 comparison test, expected UART output, rebuild checklist, and common failure modes.

### [Linux and llama.cpp Integration](linux-llama-integration.md)

Describes FPGA overlay loading, the coherent DMA-buffer driver, buffer mappings, the `ggml_compute_forward_mul_mat` hook, supported quantization formats, shape-aware offload policy, packed-weight reuse, comparison modes, performance, and limitations.

### [RTL Module Reference](rtl-module-reference.md)

Provides a concise reference for the 18 synthesizable modules and the generated multiplier IP. It focuses on module responsibility, key parameters, external ports, submodules, and behavior that software or verification engineers must know.

## Source-of-Truth Rules

To avoid duplicated and inconsistent documentation:

- Address and register definitions belong in `programming-model.md`.
- Hardware organization and pipeline behavior belong in `architecture.md`.
- Vitis/XSCT operational procedures belong in `baremetal-bringup.md`.
- Linux driver and `llama.cpp` behavior belong in `linux-llama-integration.md`.
- Module ports and parameters belong in `rtl-module-reference.md`.

Other documents should link to the relevant source instead of copying complete tables.

## Figures

The figures in `images/` are exported from the project-provided Draw.io/PDF sources. They are not regenerated diagrams.
