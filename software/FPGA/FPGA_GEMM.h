#ifndef FPGA_GEMM_H
#define FPGA_GEMM_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum FpgaQuantType {
    FPGA_QUANT_Q5_0 = 0,
    FPGA_QUANT_Q8_0 = 1,
    FPGA_QUANT_Q4_K = 2,
} FpgaQuantType;

bool fpga_gemm_init(void);
bool fpga_gemm_is_ready(void);
void fpga_gemm_shutdown(void);

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
