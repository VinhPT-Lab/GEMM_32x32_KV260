#ifndef FPGA_GEMM_H
#define FPGA_GEMM_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// RTL-compatible input to the FPGA packer.
// Supported source rows are converted in software to INT8 tiles before FPGA
// execution. Keep the first values stable so existing packed dumps remain
// readable.
typedef enum FpgaQuantType {
    FPGA_QUANT_Q5_0     = 0,
    FPGA_QUANT_Q8_0     = 1,
    FPGA_QUANT_Q6_K     = 2,
    FPGA_QUANT_Q1_0     = 3,
    FPGA_QUANT_Q4_0     = 4,
    FPGA_QUANT_Q4_1     = 5,
    FPGA_QUANT_Q5_1     = 6,
    FPGA_QUANT_Q2_K     = 7,
    FPGA_QUANT_Q3_K     = 8,
    FPGA_QUANT_Q4_K     = 9,
    FPGA_QUANT_Q5_K     = 10,
    FPGA_QUANT_F16      = 11,
    FPGA_QUANT_F32      = 12,
    FPGA_QUANT_BF16     = 13,
    FPGA_QUANT_MXFP4    = 14,
    FPGA_QUANT_NVFP4    = 15,
    FPGA_QUANT_IQ2_XXS  = 16,
    FPGA_QUANT_IQ2_XS   = 17,
    FPGA_QUANT_IQ3_XXS  = 18,
    FPGA_QUANT_IQ1_S    = 19,
    FPGA_QUANT_IQ4_NL   = 20,
    FPGA_QUANT_IQ3_S    = 21,
    FPGA_QUANT_IQ2_S    = 22,
    FPGA_QUANT_IQ4_XS   = 23,
    FPGA_QUANT_IQ1_M    = 24,
    FPGA_QUANT_TQ1_0    = 25,
    FPGA_QUANT_TQ2_0    = 26,
} FpgaQuantType;

bool fpga_gemm_init(void);
bool fpga_gemm_is_ready(void);
bool fpga_gemm_is_hardware_backend(void);
bool fpga_gemm_is_mock_backend(void);

void fpga_gemm_shutdown(void);
void fpga_gemm_cleanup(void);

void fpga_gemm_set_tensor_context(const char * tensor_name);
const char * fpga_gemm_current_shift_mode(void);

// Logical GEMM:
//   C[M x N] = B_f32[M x K_orig] * A_raw[N rows, each K_orig quantized values]
//
// Current hardware-compatible numeric behavior:
//   B_f32 activation -> INT8 feature per row
//   GGML Q5_0/Q6_K/Q8_0 weight -> prepacked INT8 FPGA layout
//   INT8 x INT8 -> INT32 accumulator
//   RTL Right_Shifter -> INT8 output
//   software dequant INT8 output -> F32
//
// fpga_gemm_try_run() returns true only when C was produced by the selected
// backend. On KV260, hardware runtime failure returns false by default so the
// caller can fall back to the original ggml CPU path instead of silently using
// the CPU mock. To explicitly enable old behavior for debug only:
//   export FPGA_ALLOW_HW_RUNTIME_FALLBACK=1
bool fpga_gemm_try_run(const void *  A_raw,
                       FpgaQuantType quant,
                       const float * B_f32,
                       float *       C,
                       int           M,
                       int           K_orig,
                       int           N_orig,
                       int           shift_in);

// Backward-compatible wrapper. New ggml hook code should call
// fpga_gemm_try_run() so it can continue to CPU when hardware fails.
void fpga_gemm_run(const void *  A_raw,
                   FpgaQuantType quant,
                   const float * B_f32,
                   float *       C,
                   int           M,
                   int           K_orig,
                   int           N_orig,
                   int           shift_in);

#ifdef __cplusplus
}
#endif

#endif  // FPGA_GEMM_H
