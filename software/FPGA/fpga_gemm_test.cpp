// fpga_gemm_test.cpp
// Build: cl /EHsc /I ggml\src\ggml-cpu\FPGA_GEMM tests\fpga_gemm_test.cpp
//            ggml\src\ggml-cpu\FPGA_GEMM\FPGA_GEMM.cpp /Fe:fpga_test.exe
// Tren Windows tu dong dung mock (fpga_win_mock.h)

#include "FPGA_GEMM.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

// ============================================================
// Helpers
// ============================================================
static float randf(float lo, float hi) {
    return lo + (hi - lo) * ((float) rand() / (float) RAND_MAX);
}

// CPU reference GEMM: C[m,n] = sum_k A[m,k] * B[k,n]
// A = activation [M x K], B = weight [K x N], C = output [M x N]
static void cpu_gemm(const float * A, const float * B, float * C, int M, int K, int N) {
    for (int m = 0; m < M; m++) {
        for (int n = 0; n < N; n++) {
            float acc = 0.f;
            for (int k = 0; k < K; k++) {
                acc += A[m * K + k] * B[k * N + n];
            }
            C[m * N + n] = acc;
        }
    }
}

// So sanh hai ma tran
static void compare(const float * ref, const float * got, int size, float * max_abs, float * max_rel, float * rmse) {
    double sum_sq = 0;
    *max_abs      = 0;
    *max_rel      = 0;
    for (int i = 0; i < size; i++) {
        float diff = fabsf(ref[i] - got[i]);
        float rel  = (fabsf(ref[i]) > 1e-6f) ? diff / fabsf(ref[i]) : diff;
        if (diff > *max_abs) {
            *max_abs = diff;
        }
        if (rel > *max_rel) {
            *max_rel = rel;
        }
        sum_sq += (double) diff * diff;
    }
    *rmse = (float) sqrt(sum_sq / size);
}

// ============================================================
// FP32 -> FP16 (raw, chi de encode test — khong can chuan xac)
// ============================================================
static uint16_t fp32_to_fp16_raw(float f) {
    uint32_t fu;
    memcpy(&fu, &f, 4);
    uint16_t sign = (fu >> 16) & 0x8000;
    int      exp  = (int) ((fu >> 23) & 0xFF) - 127 + 15;
    uint32_t mant = (fu >> 13) & 0x3FF;
    if (exp <= 0) {
        return sign;
    }
    if (exp >= 31) {
        return sign | 0x7C00;
    }
    return (uint16_t) (sign | ((uint32_t) exp << 10) | mant);
}

// ============================================================
// Q5_0 encoder
// ============================================================
#define QK5_0 32

typedef struct {
    uint16_t d;
    uint8_t  qh[4];
    uint8_t  qs[16];
} block_q5_0;

static void encode_q5_0(const float * src, int n, block_q5_0 * dst) {
    int nb = (n + QK5_0 - 1) / QK5_0;
    for (int b = 0; b < nb; b++) {
        const float * blk  = src + b * QK5_0;
        float         amax = 0;
        for (int i = 0; i < QK5_0; i++) {
            if (fabsf(blk[i]) > amax) {
                amax = fabsf(blk[i]);
            }
        }
        float d  = amax / 15.f;
        dst[b].d = fp32_to_fp16_raw(d);
        memset(dst[b].qs, 0, 16);

        uint32_t qh = 0;
        for (int i = 0; i < QK5_0; i++) {
            int val    = (d > 0) ? (int) roundf(blk[i] / d) + 16 : 16;
            val        = val < 0 ? 0 : val > 31 ? 31 : val;
            uint8_t lo = val & 0x0F;
            uint8_t hi = (val >> 4) & 1;
            qh |= ((uint32_t) hi << i);
            if (i < 16) {
                dst[b].qs[i] = (dst[b].qs[i] & 0xF0) | lo;
            } else {
                dst[b].qs[i - 16] = (dst[b].qs[i - 16] & 0x0F) | (lo << 4);
            }
        }
        memcpy(dst[b].qh, &qh, 4);
    }
}

// ============================================================
// Q8_0 encoder
// ============================================================
#define QK8_0 32

typedef struct {
    uint16_t d;
    int8_t   qs[QK8_0];
} block_q8_0;

static void encode_q8_0(const float * src, int n, block_q8_0 * dst) {
    int nb = (n + QK8_0 - 1) / QK8_0;
    for (int b = 0; b < nb; b++) {
        const float * blk  = src + b * QK8_0;
        float         amax = 0;
        for (int i = 0; i < QK8_0; i++) {
            if (fabsf(blk[i]) > amax) {
                amax = fabsf(blk[i]);
            }
        }
        float d  = amax / 127.f;
        dst[b].d = fp32_to_fp16_raw(d);
        for (int i = 0; i < QK8_0; i++) {
            int v        = (d > 0) ? (int) roundf(blk[i] / d) : 0;
            dst[b].qs[i] = (int8_t) (v > 127 ? 127 : v < -128 ? -128 : v);
        }
    }
}

// ============================================================
// Q4_K encoder
// Super-block: 256 phan tu, chia thanh 8 sub-block x 32
//
// Layout block_q4_K (khop voi FPGA_GEMM.cpp):
//   scales[12] : 6-bit scale + 6-bit min cho 8 sub-block
//   qs[128]    : 4-bit nibble (lo=phan tu chan, hi=phan tu le)
//   d          : FP16 super-scale
//   dmin       : FP16 super-min
//
// Encoding scales/mins (theo ggml):
//   scales[i]     bit[5:0] = scale[i]      (i=0..3)
//   scales[i+4]   bit[5:0] = scale[i+4]    (i=0..3)
//   scales[i]     bit[7:6] = min[i] bit[1:0]
//   scales[i+4]   bit[7:6] = min[i+4] bit[1:0]
//   scales[i+8]   bit[3:0] = min[i] bit[5:2]    (i=0..3)
//   scales[i+8]   bit[7:4] = min[i+4] bit[5:2]  (i=0..3)
// ============================================================
#define QK_K         256
#define K_SCALE_SIZE 12

typedef struct {
    uint8_t  scales[K_SCALE_SIZE];
    uint8_t  qs[QK_K / 2];
    uint16_t d;
    uint16_t dmin;
} block_q4_K;

// ============================================================
// Q4_K encoder cai tien — dung least squares cho scale/min
// ============================================================
static void encode_q4_K(const float * src, int n, block_q4_K * dst) {
    int nb = (n + QK_K - 1) / QK_K;

    for (int b = 0; b < nb; b++) {
        const float * blk = src + b * QK_K;
        block_q4_K *  out = &dst[b];

        // --- Buoc 1: Least squares tim scale/min toi uu cho tung sub-block ---
        // Voi 4-bit [0..15]: q = round((x - min) / step), step = (max-min)/15
        // Dung iterative: bat dau tu max/min, sau do minimize MSE

        float sub_sc[8], sub_mn[8];  // scale va min thuc cua tung sub-block

        for (int sub = 0; sub < 8; sub++) {
            const float * s = blk + sub * 32;

            // Lan 1: khoi tao tu min/max
            float vmax = s[0], vmin = s[0];
            for (int j = 1; j < 32; j++) {
                if (s[j] > vmax) {
                    vmax = s[j];
                }
                if (s[j] < vmin) {
                    vmin = s[j];
                }
            }

            // Iterative least squares — 8 vong lap
            float scale = (vmax - vmin) / 15.f;
            float mn    = vmin;

            for (int iter = 0; iter < 8; iter++) {
                if (scale < 1e-9f) {
                    break;
                }

                // Quantize va tinh lai scale/min bang least squares
                // minimize sum((x_i - (q_i * scale + mn))^2)
                double sum_q = 0, sum_q2 = 0;
                double sum_x = 0, sum_xq = 0;
                int    cnt = 32;

                for (int j = 0; j < 32; j++) {
                    int q = (int) roundf((s[j] - mn) / scale);
                    q     = q < 0 ? 0 : q > 15 ? 15 : q;
                    sum_q += q;
                    sum_q2 += (double) q * q;
                    sum_x += s[j];
                    sum_xq += s[j] * q;
                }

                // Giai he phuong trinh tuyen tinh 2 an (scale, mn):
                // [sum_q2  sum_q ] [scale]   [sum_xq]
                // [sum_q   cnt   ] [mn   ] = [sum_x ]
                double det = sum_q2 * cnt - sum_q * sum_q;
                if (fabs(det) < 1e-12) {
                    break;
                }

                double new_scale = (sum_xq * cnt - sum_x * sum_q) / det;
                double new_mn    = (sum_x * sum_q2 - sum_xq * sum_q) / det;

                if (new_scale <= 0) {
                    break;
                }
                scale = (float) new_scale;
                mn    = (float) new_mn;
            }

            sub_sc[sub] = scale;
            sub_mn[sub] = mn;
        }

        // --- Buoc 2: Tim super-scale d va super-min dmin ---
        // d    bieu dien scale[sub] = d * sc6[sub],  sc6 in [0..15]
        // dmin bieu dien |mn[sub]|  = dmin * mn6[sub], mn6 in [0..15]
        // (luu y: mn co the am nen dung -mn cho min6)

        float max_sc = 1e-9f, max_mn = 1e-9f;
        for (int sub = 0; sub < 8; sub++) {
            if (sub_sc[sub] > max_sc) {
                max_sc = sub_sc[sub];
            }
            if (-sub_mn[sub] > max_mn) {
                max_mn = -sub_mn[sub];
            }
        }

        float d_val    = max_sc / 15.f;
        float dmin_val = max_mn / 15.f;

        out->d    = fp32_to_fp16_raw(d_val);
        out->dmin = fp32_to_fp16_raw(dmin_val);

        // --- Buoc 3: Quantize sc6 va mn6 ---
        uint8_t sc6[8], mn6[8];
        for (int sub = 0; sub < 8; sub++) {
            sc6[sub] = (d_val > 0) ? (uint8_t) roundf(sub_sc[sub] / d_val) : 0;
            mn6[sub] = (dmin_val > 0) ? (uint8_t) roundf(-sub_mn[sub] / dmin_val) : 0;
            if (sc6[sub] > 15) {
                sc6[sub] = 15;
            }
            if (mn6[sub] > 15) {
                mn6[sub] = 15;
            }
        }

        // --- Buoc 4: Pack scales/mins vao 12 bytes ---
        memset(out->scales, 0, K_SCALE_SIZE);
        for (int i = 0; i < 4; i++) {
            out->scales[i]     = (sc6[i] & 0x3F) | ((mn6[i] & 0x03) << 6);
            out->scales[i + 4] = (sc6[i + 4] & 0x3F) | ((mn6[i + 4] & 0x03) << 6);
            out->scales[i + 8] = ((mn6[i] >> 2) & 0x0F) | (((mn6[i + 4] >> 2) & 0x0F) << 4);
        }

        // --- Buoc 5: Quantize tung phan tu thanh 4-bit nibble ---
        // Dung scale/min da duoc round ve sc6/mn6 (khop voi decoder)
        memset(out->qs, 0, QK_K / 2);
        for (int sub = 0; sub < 8; sub++) {
            float sc_f  = d_val * (float) sc6[sub];
            float min_f = dmin_val * (float) mn6[sub];  // day la -mn thuc

            for (int j = 0; j < 32; j++) {
                float v = blk[sub * 32 + j];
                // x = sc_f * q + min_f_actual, voi min_f_actual = -min_f
                // q = round((x - (-min_f)) / sc_f) = round((x + min_f) / sc_f)
                int   q = (sc_f > 0) ? (int) roundf((v + min_f) / sc_f) : 0;
                if (q < 0) {
                    q = 0;
                }
                if (q > 15) {
                    q = 15;
                }

                int idx = sub * 16 + j / 2;
                if (j & 1) {
                    out->qs[idx] = (out->qs[idx] & 0x0F) | ((uint8_t) q << 4);
                } else {
                    out->qs[idx] = (out->qs[idx] & 0xF0) | (uint8_t) q;
                }
            }
        }
    }
}

// ============================================================
// Mot test case
// ============================================================
struct TestCase {
    const char *  name;
    int           M, K, N;
    FpgaQuantType quant;
};

static bool run_test(const TestCase & tc) {
    printf("\n---------------------------------------------\n");
    printf("TEST: %s  M=%d K=%d N=%d\n", tc.name, tc.M, tc.K, tc.N);
    printf("---------------------------------------------\n");

    // Reset giua cac test
    fpga_gemm_cleanup();
    if (!fpga_gemm_is_ready()) {
        printf("[FATAL] re-init failed\n");
        return false;
    }

    int M = tc.M, K = tc.K, N = tc.N;

    // Q4_K yeu cau K*N chia het 256
    if (tc.quant == FPGA_QUANT_Q4_K && (K * N) % QK_K != 0) {
        printf("[SKIP] Q4_K yeu cau K*N chia het 256, K*N=%d\n", K * N);
        return true;
    }

    srand(42);

    // 1. Tao weight float [K x N]
    float * W_f32 = new float[K * N];
    for (int i = 0; i < K * N; i++) {
        W_f32[i] = randf(-1.f, 1.f);
    }

    // 2. Tao activation float [M x K]
    float * A_f32 = new float[M * K];
    for (int i = 0; i < M * K; i++) {
        A_f32[i] = randf(-1.f, 1.f);
    }

    // 3. CPU reference (float goc)
    float * C_ref = new float[M * N]();
    cpu_gemm(A_f32, W_f32, C_ref, M, K, N);

    // 4. Encode weight sang dinh dang quantized
    void * W_quant     = nullptr;
    size_t quant_bytes = 0;

    if (tc.quant == FPGA_QUANT_Q5_0) {
        int nb      = (K * N + QK5_0 - 1) / QK5_0;
        quant_bytes = (size_t) nb * sizeof(block_q5_0);
        W_quant     = malloc(quant_bytes);
        memset(W_quant, 0, quant_bytes);
        encode_q5_0(W_f32, K * N, (block_q5_0 *) W_quant);

    } else if (tc.quant == FPGA_QUANT_Q8_0) {
        int nb      = (K * N + QK8_0 - 1) / QK8_0;
        quant_bytes = (size_t) nb * sizeof(block_q8_0);
        W_quant     = malloc(quant_bytes);
        memset(W_quant, 0, quant_bytes);
        encode_q8_0(W_f32, K * N, (block_q8_0 *) W_quant);

    } else if (tc.quant == FPGA_QUANT_Q4_K) {
        int nb      = (K * N + QK_K - 1) / QK_K;
        quant_bytes = (size_t) nb * sizeof(block_q4_K);
        W_quant     = malloc(quant_bytes);
        memset(W_quant, 0, quant_bytes);
        encode_q4_K(W_f32, K * N, (block_q4_K *) W_quant);

    } else {
        printf("[SKIP] Quant type %d chua implement\n", (int) tc.quant);
        delete[] W_f32;
        delete[] A_f32;
        delete[] C_ref;
        return true;
    }

    // 5. Chay FPGA (hoac mock)
    float * C_fpga = new float[M * N]();
    fpga_gemm_run(W_quant, tc.quant, A_f32, C_fpga, M, K, N, 0);

    // 6. So sanh
    float max_abs, max_rel, rmse;
    compare(C_ref, C_fpga, M * N, &max_abs, &max_rel, &rmse);

    // Normalized RMSE
    double ref_mean = 0;
    for (int i = 0; i < M * N; i++) {
        ref_mean += C_ref[i];
    }
    ref_mean /= (M * N);

    double ref_var = 0;
    for (int i = 0; i < M * N; i++) {
        double d = C_ref[i] - ref_mean;
        ref_var += d * d;
    }
    double ref_std = sqrt(ref_var / (M * N));
    float  nrmse   = (ref_std > 1e-9) ? (float) (rmse / ref_std) : rmse;

    // Sign match
    int same_sign = 0;
    for (int i = 0; i < M * N; i++) {
        if (C_ref[i] * C_fpga[i] >= 0) {
            same_sign++;
        }
    }
    float sign_ratio = (float) same_sign / (float) (M * N);

    // Q4_K co double-quantization nen cho phep sai so lon hon mot chut
    float thr_nrmse = (tc.quant == FPGA_QUANT_Q4_K) ? 0.40f : 0.30f;
    float thr_sign  = 0.80f;
    bool  pass      = (nrmse < thr_nrmse) && (sign_ratio >= thr_sign);

    printf("  nRMSE=%.4f (thr=%.2f)  sign_match=%.1f%%  max_abs=%.4f  -> %s\n", nrmse, thr_nrmse, sign_ratio * 100.f,
           max_abs, pass ? "PASS" : "FAIL");

    // In vai phan tu dau de debug
    printf("  C_ref  [0..4]: ");
    for (int i = 0; i < 5 && i < M * N; i++) {
        printf("%8.3f ", C_ref[i]);
    }
    printf("\n  C_fpga [0..4]: ");
    for (int i = 0; i < 5 && i < M * N; i++) {
        printf("%8.3f ", C_fpga[i]);
    }
    printf("\n");

    free(W_quant);
    delete[] W_f32;
    delete[] A_f32;
    delete[] C_ref;
    delete[] C_fpga;
    return pass;
}

// ============================================================
// main
// ============================================================
int main() {
    printf("============================================\n");
    printf("  FPGA GEMM Correctness Test\n");
    printf("============================================\n");

    if (!fpga_gemm_is_ready()) {
        printf("[FATAL] fpga_gemm_init() failed\n");
        return 1;
    }

    TestCase cases[] = {
        // ── Q5_0 ──────────────────────────────────────────────
        { "Q5_0 chia het 32",          4, 64,  64,  FPGA_QUANT_Q5_0 },
        { "Q5_0 K,N khong chia het",   3, 96,  96,  FPGA_QUANT_Q5_0 },
        { "Q5_0 attn_q [M=1]",         1, 896, 896, FPGA_QUANT_Q5_0 },
        { "Q5_0 attn_k [128x896]",     1, 896, 128, FPGA_QUANT_Q5_0 },
        { "Q5_0 N pad (100->128)",     2, 64,  100, FPGA_QUANT_Q5_0 },
        { "Q5_0 K+N pad (48x100)",     2, 48,  100, FPGA_QUANT_Q5_0 },

        // ── Q8_0 ──────────────────────────────────────────────
        { "Q8_0 chia het 32",          4, 64,  64,  FPGA_QUANT_Q8_0 },
        { "Q8_0 token_embd [896x128]", 1, 896, 128, FPGA_QUANT_Q8_0 },
        { "Q8_0 K pad (48->64)",       2, 48,  64,  FPGA_QUANT_Q8_0 },

        // ── Q4_K ──────────────────────────────────────────────
        // K*N phai la boi so cua 256
        { "Q4_K co ban [256x256]",     1, 256, 256, FPGA_QUANT_Q4_K },
        { "Q4_K M=4 [256x256]",        4, 256, 256, FPGA_QUANT_Q4_K },
        { "Q4_K K lon [512x256]",      1, 512, 256, FPGA_QUANT_Q4_K },
        { "Q4_K attn [896x896]",       1, 896, 896, FPGA_QUANT_Q4_K },
        { "Q4_K attn_k [896x128]",     1, 896, 128, FPGA_QUANT_Q4_K },
    };

    int total = (int) (sizeof(cases) / sizeof(cases[0]));
    int pass  = 0;

    for (int i = 0; i < total; i++) {
        if (run_test(cases[i])) {
            pass++;
        }
    }

    printf("\n============================================\n");
    printf("  Ket qua: %d/%d PASS\n", pass, total);
    printf("============================================\n");

    fpga_gemm_cleanup();
    return (pass == total) ? 0 : 1;
}
