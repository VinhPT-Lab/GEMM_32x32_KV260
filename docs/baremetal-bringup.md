# Bare-Metal Bring-Up on Kria KV260

## 1. Purpose

This guide documents the verified Vivado/Vitis 2022.2 procedure for running the 32 x 32 signed INT8 GEMM comparison test on the Kria KV260. It focuses on stable board initialization, AXI4-Lite reachability, DMA ordering, cache maintenance, expected output, and troubleshooting.

For address, register, and stream-layout details, see the [Software Programming Model](programming-model.md).

## 2. Verified Baseline

| Item | Configuration |
|---|---|
| Board | Xilinx Kria KV260 / K26 |
| Processor | Cortex-A53 #0 |
| Software environment | Vitis standalone / bare-metal |
| Tools | Vivado and Vitis 2022.2 |
| Matrix test | 32 x 32 x 32 signed INT8 GEMM |
| AXI4-Stream width | 256 bits |
| Matrix bytes | 1,024 bytes for A, B, and C |
| UART | 115200 baud |

Verified completion:

```text
DMA0 feature done, status=0x00001002
DMA1 weight done, status=0x00001002
DMA2 result done, status=0x00001002
GEMM done, status=0x06000000
COMPARE PASS
```

## 3. Required Build Artifacts

The run flow requires:

- the implemented FPGA bitstream;
- the matching `psu_init.tcl` exported with the hardware platform; and
- the rebuilt Cortex-A53 ELF application.

All three artifacts must come from the same hardware revision. A stale XSA/platform/bitstream combination can produce AXI4-Lite hangs even when the C application is unchanged.

## 4. Rebuild Flow After Hardware Changes

After changing RTL, IP configuration, block design, address map, clock, or reset:

1. Regenerate IP output products if required.
2. Reset synthesis/implementation runs when appropriate.
3. Run synthesis.
4. Run implementation.
5. Generate the bitstream.
6. Export the hardware platform with the bitstream included.
7. Rebuild the Vitis platform.
8. Rebuild the application.
9. Power-cycle the KV260.
10. Run the known-good XSCT launch sequence.
11. Confirm `COMPARE PASS` before continuing to larger tests.

Do not export only a new XSA after an RTL change without regenerating the bitstream.

## 5. Stable XSCT Launch

The repository includes a parameterized launch script:

```bash
xsct scripts/baremetal/run_gemm_dsp.tcl \
  path/to/design.bit \
  path/to/psu_init.tcl \
  path/to/application.elf
```

The script performs the verified order:

1. Connect to the board.
2. Reset the system.
3. Program the FPGA.
4. Source and execute `psu_init`.
5. Remove PS-PL isolation and configure resets.
6. Run `psu_post_config`.
7. Reset Cortex-A53 #0.
8. Download the ELF.
9. Continue processor execution.

This explicit flow is preferred over an unverified Vitis GUI launch configuration.

## 6. Pre-Run Procedure

1. Connect the UART terminal at 115200 baud.
2. Power-cycle the KV260 if the board has been used by a different design or is in an unknown state.
3. Open an XSCT shell.
4. Run the script with the current bitstream, PSU initialization script, and ELF.
5. Observe the UART log from the beginning of the application.

## 7. AXI4-Lite Smoke Test

Before starting DMA, the application should read:

| Target | Address |
|---|---:|
| GEMM status | `0xA0000000` |
| DMA0 MM2S status | `0xA0010004` |
| DMA1 MM2S status | `0xA0020004` |
| DMA2 S2MM status | `0xA0030034` |

The smoke test must return values without hanging or raising a bus error. Typical reset/idle values are:

```text
DMA0 MM2S status = 0x00000001
DMA1 MM2S status = 0x00000001
DMA2 S2MM status = 0x00000001
GEMM status      = 0x04000000
```

If the application hangs while reading a PL address, stop. Do not continue to DMA or GEMM testing.

## 8. Verified 32 x 32 Test Sequence

### Configuration

```text
shift         = 0
row_count     = 32
k_block_count = 1
n_block_count = 1
A bytes       = 1024
B bytes       = 1024
C bytes       = 1024
```

### Execution

1. Compute the software reference result.
2. Poll GEMM until idle.
3. Clear a previous `done` state if required.
4. Write the four GEMM configuration registers.
5. Flush A, B, and C hardware buffers from the CPU cache.
6. Start DMA2 S2MM for the result buffer.
7. Start DMA0 MM2S for feature data.
8. Start DMA1 MM2S for weight data.
9. Poll all DMA channels with timeouts and error checks.
10. Check GEMM `done`.
11. Invalidate the C hardware result buffer.
12. Compare hardware output against the software reference.

## 9. Expected UART Output

A successful run should include the following sequence:

```text
===== GEMM 32x32 DMA TEST START =====
MM_ADDR          = 0xA0000000
FEATURE_DMA_ADDR = 0xA0010000
WEIGHT_DMA_ADDR  = 0xA0020000
RESULT_DMA_ADDR  = 0xA0030000
A_SIZE=32, MATRIX_A_BYTES=1024, MATRIX_B_BYTES=1024, MATRIX_C_BYTES=1024
Software GEMM start
Software GEMM done
stage 0: bus smoke test
DMA0 MM2S status = 0x00000001
DMA1 MM2S status = 0x00000001
DMA2 S2MM status = 0x00000001
GEMM status = 0x04000000
...
DMA0 feature done, status=0x00001002
DMA1 weight done, status=0x00001002
DMA2 result done, status=0x00001002
GEMM done, status=0x06000000
Hardware GEMM done
COMPARE PASS
===== GEMM 32x32 DMA TEST END =====
```

## 10. Clock and Reset Requirements

Use one consistent PL clock for all accelerator and AXI interfaces. The verified design uses the ZynqMP PL clock at 100 MHz.

Active-low PL resets should be driven by the processor-system-reset `peripheral_aresetn` output. If the reset block has a `dcm_locked` input, connect it to a valid asserted lock signal. A low or floating lock input can hold the entire PL in reset and make AXI4-Lite reads hang.

## 11. Troubleshooting

### 11.1 Application hangs at `READ DMA0 status...`

**Meaning:** Cortex-A53 attempted to read `0xA0010004`, but the PL AXI4-Lite slave did not respond.

**Check:**

- the current FPGA bitstream was programmed;
- the Vitis platform matches that bitstream;
- `psu_init` completed;
- PS-PL isolation was removed;
- `psu_post_config` completed;
- the A53 was reset and downloaded after PL initialization; and
- PL clock/reset signals are valid.

This symptom is an initialization/access problem, not evidence of a GEMM arithmetic error.

### 11.2 XSCT `mrd` reports a blocked PL address

XSCT can reject a valid PL address because its debugger memory map does not include that range. Add it for debugger convenience:

```tcl
targets -set -filter {name =~ "Cortex-A53 #0"}
memmap -addr 0xA0000000 -size 0x00040000 -flags rw
mrd 0xA0000000
mrd 0xA0010004
mrd 0xA0020004
mrd 0xA0030034
```

The running A53 application's successful reads remain the primary reachability test.

### 11.3 DMA completes but the result is zero or incorrect

Check, in order:

1. A/B cache flush and C cache invalidation.
2. Full `TSTRB` on both input streams.
3. `TLAST` only on the final complete feature/weight beat.
4. Feature and weight packing order.
5. Shift value and output saturation.
6. Correct row/K-block/N-block configuration.
7. Matching bitstream, XSA, platform, and ELF.

Use simulation or ILA on the feature, weight, and result `TVALID/TREADY/TDATA/TLAST` signals if the mismatch remains.

### 11.4 DMA timeout or DMA error bits

Check:

- programmed source/destination physical addresses;
- transfer length written after the address;
- channel direction (MM2S versus S2MM);
- DMA reset completion;
- data-path clock/reset; and
- S2MM started before MM2S.

### 11.5 GEMM `done` does not assert

`done` is generated only when the final result beat is accepted. Confirm that DMA2 is active, `result_axis_tready` is high, `result_axis_tlast` is generated, and the configured result-beat count is correct.

## 12. Bring-Up Discipline

Keep the passing 32 x 32 application as a regression baseline. Change one subsystem at a time, rebuild all dependent artifacts after hardware changes, and require the smoke test plus `COMPARE PASS` before moving to larger matrices or Linux/LLM integration.
