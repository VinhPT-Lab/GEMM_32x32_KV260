#ifdef _WIN32
#    ifndef NOMINMAX
#        define NOMINMAX
#    endif
#endif

#include "FPGA_GEMM.h"

#ifdef _WIN32
#    include "fpga_win_mock.h"
#endif
#ifndef _WIN32
#    include <fcntl.h>
#    include <sys/mman.h>
#    include <unistd.h>
#endif
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <unordered_map>

// ── FPGA register map ──────────────────────────────────────────────────────
#define AXILITE_BASE  0xA0000000ULL  // GEMM_DSP_IP_0
#define DMA_FEAT_BASE 0xA0010000ULL  // axi_dma_0
#define DMA_WGHT_BASE 0xA0020000ULL  // axi_dma_1
#define DMA_RSLT_BASE 0xA0030000ULL  // axi_dma_2
#define MAP_SIZE      0x10000ULL

// ── DDR fixed addresses ────────────────────────────────────────────────────
#define DDR_FEAT_BASE 0x10000000ULL
#define DDR_WGHT_BASE 0x20000000ULL
#define DDR_RSLT_BASE 0x70000000ULL
#define DDR_FEAT_SIZE 0x04000000ULL
#define DDR_WGHT_SIZE 0x20000000ULL
#define DDR_RSLT_SIZE 0x04000000ULL

// ── AXI-Lite control registers ─────────────────────────────────────────────
#define REG_SHIFT    0x00
#define REG_F_LENGTH 0x04
#define REG_F_WIDTH  0x08
#define REG_W_WIDTH  0x0C

// ── DMA register offsets ───────────────────────────────────────────────────
#define DMA_MM2S_CR     0x00
#define DMA_MM2S_SR     0x04
#define DMA_MM2S_SA     0x18
#define DMA_MM2S_LEN    0x28
#define DMA_S2MM_CR     0x30
#define DMA_S2MM_SR     0x34
#define DMA_S2MM_DA     0x48
#define DMA_S2MM_LEN    0x58
#define DMA_CR_RUN      0x0001
#define DMA_CR_RESET    0x0004
#define DMA_CR_IOC_EN   0x1000
#define DMA_CR_ERR_EN   0x4000
#define DMA_SR_HALTED   0x0001
#define DMA_SR_IDLE     0x0002
#define DMA_SR_ERR_MASK 0x0070
#define DMA_SR_IOC_IRQ  0x1000

// GEMM status bits read from REG_SHIFT
#define GEMM_ST_BUSY 24
#define GEMM_ST_DONE 25
#define GEMM_ST_IDLE 26

#define ARRAY_SIZE      32
#define IP_BUFFER_DEPTH 2400

// Align x up to nearest multiple of 32
static inline int align32(int x) {
    return (x + ARRAY_SIZE - 1) & ~(ARRAY_SIZE - 1);
}

// ── Quantization block layouts (ggml spec) ─────────────────────────────────
#define QK5_0 32

typedef struct {
    uint16_t d;
    uint8_t  qh[4];
    uint8_t  qs[16];
} block_q5_0;

#define QK8_0 32

typedef struct {
    uint16_t d;
    int8_t   qs[32];
} block_q8_0;

#define QK_K         256
#define K_SCALE_SIZE 12

typedef struct {
    uint8_t  scales[K_SCALE_SIZE];
    uint8_t  qs[QK_K / 2];
    uint16_t d;
    uint16_t dmin;
} block_q4_K;

// ── FP16 → FP32 ───────────────────────────────────────────────────────────
static float fp16_to_fp32(uint16_t h) {
    uint32_t sign = (uint32_t) (h & 0x8000) << 16;
    uint32_t exp  = (h >> 10) & 0x1F;
    uint32_t mant = h & 0x03FF;
    uint32_t f;
    if (exp == 0) {
        if (!mant) {
            f = sign;
        } else {
            exp = 1;
            while (!(mant & 0x0400)) {
                mant <<= 1;
                exp--;
            }
            mant &= 0x03FF;
            f = sign | ((exp + 112) << 23) | (mant << 13);
        }
    } else if (exp == 0x1F) {
        f = sign | 0x7F800000 | (mant << 13);  // Inf/NaN
    } else {
        f = sign | ((exp + 112) << 23) | (mant << 13);
    }
    float r;
    memcpy(&r, &f, 4);
    return r;
}

// ── Dequantize helpers ─────────────────────────────────────────────────────
static void dequant_q5_0(const block_q5_0 * b, int nb, float * out) {
    for (int i = 0; i < nb; i++) {
        float    d = fp16_to_fp32(b[i].d);
        uint32_t qh;
        memcpy(&qh, b[i].qh, 4);
        for (int j = 0; j < 32; j++) {
            uint8_t lo      = (j < 16) ? (b[i].qs[j] & 0x0F) : (b[i].qs[j - 16] >> 4);
            uint8_t hi      = (qh >> j) & 1;
            out[i * 32 + j] = d * (float) ((int) ((hi << 4) | lo) - 16);
        }
    }
}

static void dequant_q8_0(const block_q8_0 * b, int nb, float * out) {
    for (int i = 0; i < nb; i++) {
        float d = fp16_to_fp32(b[i].d);
        for (int j = 0; j < 32; j++) {
            out[i * 32 + j] = d * (float) b[i].qs[j];
        }
    }
}

static void dequant_q4_K(const block_q4_K * b, int nb, float * out) {
    for (int i = 0; i < nb; i++) {
        float           d    = fp16_to_fp32(b[i].d);
        float           dmin = fp16_to_fp32(b[i].dmin);
        const uint8_t * sc   = b[i].scales;
        const uint8_t * q    = b[i].qs;
        float *         dst  = out + i * QK_K;
        uint8_t         sv[8], mv[8];
        for (int j = 0; j < 4; j++) {
            sv[j]     = sc[j] & 0x3F;
            sv[j + 4] = sc[j + 4] & 0x3F;
            mv[j]     = (sc[j] >> 6) | ((sc[j + 8] & 0x0F) << 2);
            mv[j + 4] = (sc[j + 4] >> 6) | ((sc[j + 8] >> 4) << 2);
        }
        for (int sub = 0; sub < 8; sub++) {
            float sf = d * (float) sv[sub];
            float mf = dmin * (float) mv[sub];
            for (int j = 0; j < 32; j++) {
                int     idx       = sub * 16 + j / 2;
                uint8_t nib       = (j & 1) ? (q[idx] >> 4) : (q[idx] & 0x0F);
                dst[sub * 32 + j] = sf * (float) nib - mf;
            }
        }
    }
}

// ── Weight cache ───────────────────────────────────────────────────────────
struct WeightEntry {
    uint64_t phys_addr;  // 0 = invalid
    float    scale_W;
    uint32_t size;       // bytes in weight pool
    int      K_pad;
    int      N_pad;
};

static std::unordered_map<const void *, WeightEntry> g_weight_cache;
static uint64_t                                      g_wpool_offset = 0;
static std::mutex                                    g_init_mutex;

// ── Static state ───────────────────────────────────────────────────────────
static bool     g_ready      = false;
static int      mem_fd       = -1;
static void *   axilite_map  = nullptr;
static void *   dma_feat_map = nullptr;
static void *   dma_wght_map = nullptr;
static void *   dma_rslt_map = nullptr;
static int8_t * ddr_feat     = nullptr;
static void *   ddr_wght     = nullptr;
static int8_t * ddr_rslt     = nullptr;

// ── Register access (Linux only) ───────────────────────────────────────────
#ifndef _WIN32
static void wr32(void * base, uint32_t off, uint32_t val) {
    *(volatile uint32_t *) ((char *) base + off) = val;
}

static uint32_t rd32(void * base, uint32_t off) {
    return *(volatile uint32_t *) ((char *) base + off);
}
#endif

// Map physical address via /dev/mem
// _WIN32: mock mmap nhận uint64_t trực tiếp, không cast qua off_t (off_t = 32-bit trên MSVC → sign-extend)
// Linux : off_t = 64-bit khi _FILE_OFFSET_BITS=64, cast an toàn
static void * map_phys(uint64_t base, size_t size) {
#ifdef _WIN32
    void * p = mmap(0, size, PROT_READ | PROT_WRITE, MAP_SHARED, mem_fd, base);
#else
    void * p = mmap(0, size, PROT_READ | PROT_WRITE, MAP_SHARED, mem_fd, (off_t) base);
#endif
    return (p == MAP_FAILED) ? nullptr : p;
}

#ifndef _WIN32
static bool wait_reg_clear(void * base, uint32_t off, uint32_t mask, uint32_t timeout, const char * name) {
    while (timeout-- > 0) {
        if ((rd32(base, off) & mask) == 0) {
            return true;
        }
    }
    fprintf(stderr, "[FPGA] timeout waiting %s clear, reg=0x%08x\n", name, rd32(base, off));
    return false;
}

static bool dma_reset_channel(void * dma, uint32_t cr_off, const char * name) {
    wr32(dma, cr_off, DMA_CR_RESET);
    // AXI DMA reset is done when the reset bit self-clears. Do NOT wait for HALTED=0;
    // a stopped simple-DMA channel normally has HALTED=1.
    return wait_reg_clear(dma, cr_off, DMA_CR_RESET, 1000000U, name);
}

static bool dma_reset_mm2s(void * dma) {
    return dma_reset_channel(dma, DMA_MM2S_CR, "MM2S reset");
}

static bool dma_reset_s2mm(void * dma) {
    return dma_reset_channel(dma, DMA_S2MM_CR, "S2MM reset");
}

static bool dma_wait_done(void * dma, uint32_t sr_off, const char * name) {
    uint32_t timeout  = 200000000U;
    bool     saw_busy = false;
    while (timeout-- > 0) {
        uint32_t st = rd32(dma, sr_off);
        if (st & DMA_SR_ERR_MASK) {
            fprintf(stderr, "[FPGA] %s DMA error, DMASR=0x%08x\n", name, st);
            return false;
        }
        if (st & DMA_SR_IOC_IRQ) {
            return true;
        }
        if ((st & DMA_SR_IDLE) == 0) {
            saw_busy = true;
        } else if (saw_busy) {
            return true;
        }
    }
    fprintf(stderr, "[FPGA] %s DMA timeout, DMASR=0x%08x\n", name, rd32(dma, sr_off));
    return false;
}

static void dma_mm2s_start(void * dma, uint64_t addr, uint32_t bytes) {
    wr32(dma, DMA_MM2S_SR, DMA_SR_IOC_IRQ);  // clear stale completion bit
    wr32(dma, DMA_MM2S_CR, DMA_CR_RUN | DMA_CR_IOC_EN | DMA_CR_ERR_EN);
    wr32(dma, DMA_MM2S_SA, (uint32_t) (addr & 0xFFFFFFFFULL));
    wr32(dma, DMA_MM2S_LEN, bytes);
}

static void dma_s2mm_start(void * dma, uint64_t addr, uint32_t bytes) {
    wr32(dma, DMA_S2MM_SR, DMA_SR_IOC_IRQ);  // clear stale completion bit
    wr32(dma, DMA_S2MM_CR, DMA_CR_RUN | DMA_CR_IOC_EN | DMA_CR_ERR_EN);
    wr32(dma, DMA_S2MM_DA, (uint32_t) (addr & 0xFFFFFFFFULL));
    wr32(dma, DMA_S2MM_LEN, bytes);
}

static bool gemm_wait_idle(uint32_t timeout) {
    while (timeout-- > 0) {
        uint32_t st = rd32(axilite_map, REG_SHIFT);
        if ((st >> GEMM_ST_IDLE) & 1U) {
            return true;
        }
    }
    fprintf(stderr, "[FPGA] GEMM not idle, status=0x%08x\n", rd32(axilite_map, REG_SHIFT));
    return false;
}

static bool gemm_configure(uint32_t shift, uint32_t row_count, uint32_t k_blocks, uint32_t n_blocks) {
    if (!gemm_wait_idle(200000000U)) {
        return false;
    }

    uint32_t st = rd32(axilite_map, REG_SHIFT);
    if ((st >> GEMM_ST_DONE) & 1U) {
        // Preserve shift while clearing done/status.
        wr32(axilite_map, REG_SHIFT, (shift & 0x3ffU) | (1U << 16));
        (void) rd32(axilite_map, REG_SHIFT);
    }

    wr32(axilite_map, REG_SHIFT, shift & 0x3ffU);
    wr32(axilite_map, REG_F_LENGTH, row_count);
    wr32(axilite_map, REG_F_WIDTH, k_blocks);
    wr32(axilite_map, REG_W_WIDTH, n_blocks);

    // Readback catches wrong base address / stale address map quickly.
    uint32_t rb_shift = rd32(axilite_map, REG_SHIFT) & 0x3ffU;
    uint32_t rb_m     = rd32(axilite_map, REG_F_LENGTH) & 0x1ffU;
    uint32_t rb_kb    = rd32(axilite_map, REG_F_WIDTH) & 0x1fU;
    uint32_t rb_nb    = rd32(axilite_map, REG_W_WIDTH) & 0x1fU;
    if (rb_shift != (shift & 0x3ffU) || rb_m != row_count || rb_kb != k_blocks || rb_nb != n_blocks) {
        fprintf(stderr, "[FPGA] GEMM config readback mismatch: shift %u/%u M %u/%u Kb %u/%u Nb %u/%u\n", rb_shift,
                shift, rb_m, row_count, rb_kb, k_blocks, rb_nb, n_blocks);
        return false;
    }
    return true;
}
#endif

// ── Weight pool allocator (64-byte aligned) ────────────────────────────────
static uint64_t alloc_weight(uint32_t size) {
    uint64_t off = (g_wpool_offset + 63) & ~63ULL;
    if (off + size > DDR_WGHT_SIZE) {
        fprintf(stderr, "[FPGA] weight pool overflow (need %u, used %llu / %lu)\n", size, (unsigned long long) off,
                (unsigned long) DDR_WGHT_SIZE);
        return 0;
    }
    g_wpool_offset = off + size;
    return DDR_WGHT_BASE + off;
}

static int8_t * wphys_to_virt(uint64_t phys) {
    return (int8_t *) ddr_wght + (phys - DDR_WGHT_BASE);
}

// Quantize ggml src0 weight rows into hardware weight stream layout.
// ggml src0 logical shape is [K, N] with K on ne0 and N on ne1.
// After dequantization, flat W_rows is laid out as W_rows[n*K + k].
// Hardware wants packed weight beats in K-major order: hw[k*N_pad + n].
// scale_W = max_abs(W) / 127.
static WeightEntry store_weight_f32(const float * W_rows, int K, int N, int K_pad, int N_pad, const char * tag) {
    float max_abs = 1e-9f;
    for (int n = 0; n < N; n++) {
        for (int k = 0; k < K; k++) {
            float v = fabsf(W_rows[n * K + k]);
            if (v > max_abs) {
                max_abs = v;
            }
        }
    }

    float    scale_W     = max_abs / 127.0f;
    float    inv_scale_W = 127.0f / max_abs;
    uint32_t sz          = (uint32_t) (K_pad * N_pad);
    uint64_t phys        = alloc_weight(sz);
    if (!phys) {
        return { 0, 0.0f, 0, 0, 0 };
    }

    int8_t * virt = wphys_to_virt(phys);
    memset(virt, 0, sz);

    for (int k = 0; k < K; k++) {
        for (int n = 0; n < N; n++) {
            // Transpose from ggml row layout [N,K] to FPGA weight layout [K,N].
            float w             = W_rows[n * K + k];
            int   iv            = (int) roundf(w * inv_scale_W);
            iv                  = iv > 127 ? 127 : iv < -128 ? -128 : iv;
            virt[k * N_pad + n] = (int8_t) iv;
        }
    }

#ifndef _WIN32
    __sync_synchronize();
    (void) msync(virt, sz, MS_SYNC);
#endif

    printf("[FPGA] %s cached @ 0x%llx K=%d->%d N=%d->%d scale_W=%.4e\n", tag, (unsigned long long) phys, K, K_pad, N,
           N_pad, scale_W);
    return WeightEntry{ phys, scale_W, sz, K_pad, N_pad };
}

// ── Per-quant cache helpers ────────────────────────────────────────────────
static WeightEntry cache_q5_0(const void * raw, int K, int N) {
    int     nb = (K * N + QK5_0 - 1) / QK5_0;
    float * f  = new float[K * N];
    dequant_q5_0((const block_q5_0 *) raw, nb, f);
    auto we = store_weight_f32(f, K, N, align32(K), align32(N), "Q5_0");
    delete[] f;
    return we;
}

static WeightEntry cache_q8_0(const void * raw, int K, int N) {
    int     nb = (K * N + QK8_0 - 1) / QK8_0;
    float * f  = new float[K * N];
    dequant_q8_0((const block_q8_0 *) raw, nb, f);
    auto we = store_weight_f32(f, K, N, align32(K), align32(N), "Q8_0");
    delete[] f;
    return we;
}

static WeightEntry cache_q4_K(const void * raw, int K, int N) {
    int     nb = (K * N + QK_K - 1) / QK_K;
    float * f  = new float[K * N];
    dequant_q4_K((const block_q4_K *) raw, nb, f);
    auto we = store_weight_f32(f, K, N, align32(K), align32(N), "Q4_K");
    delete[] f;
    return we;
}

// ── Public API ─────────────────────────────────────────────────────────────
bool fpga_gemm_init() {
#ifdef _WIN32
    mock_init();
    mem_fd = 3;  // fake fd for Windows mock
#else
    mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    printf("[DEBUG] mem_fd = %d\n", mem_fd);
    if (mem_fd < 0) {
        perror("[FPGA] open /dev/mem");
        return false;
    }
#endif
    axilite_map  = map_phys(AXILITE_BASE, MAP_SIZE);
    dma_feat_map = map_phys(DMA_FEAT_BASE, MAP_SIZE);
    dma_wght_map = map_phys(DMA_WGHT_BASE, MAP_SIZE);
    dma_rslt_map = map_phys(DMA_RSLT_BASE, MAP_SIZE);
    if (!axilite_map || !dma_feat_map || !dma_wght_map || !dma_rslt_map) {
        fprintf(stderr, "[FPGA] mmap AXI-Lite failed\n");
        return false;
    }
    ddr_feat = (int8_t *) map_phys(DDR_FEAT_BASE, DDR_FEAT_SIZE);
    ddr_wght = map_phys(DDR_WGHT_BASE, DDR_WGHT_SIZE);
    ddr_rslt = (int8_t *) map_phys(DDR_RSLT_BASE, DDR_RSLT_SIZE);
    if (!ddr_feat || !ddr_wght || !ddr_rslt) {
        fprintf(stderr, "[FPGA] mmap DDR failed\n");
        return false;
    }
#ifndef _WIN32
    if (!dma_reset_mm2s(dma_feat_map) || !dma_reset_mm2s(dma_wght_map) || !dma_reset_s2mm(dma_rslt_map)) {
        fprintf(stderr, "[FPGA] DMA reset failed\n");
        return false;
    }
#endif
    g_wpool_offset = 0;
    g_weight_cache.clear();
    g_ready = true;
    printf("[FPGA] init OK\n");
    return true;
}

void fpga_gemm_cleanup() {
    g_weight_cache.clear();
#ifndef _WIN32
    if (ddr_feat) {
        munmap(ddr_feat, DDR_FEAT_SIZE);
    }
    if (ddr_wght) {
        munmap(ddr_wght, DDR_WGHT_SIZE);
    }
    if (ddr_rslt) {
        munmap(ddr_rslt, DDR_RSLT_SIZE);
    }
    if (axilite_map) {
        munmap(axilite_map, MAP_SIZE);
    }
    if (dma_feat_map) {
        munmap(dma_feat_map, MAP_SIZE);
    }
    if (dma_wght_map) {
        munmap(dma_wght_map, MAP_SIZE);
    }
    if (dma_rslt_map) {
        munmap(dma_rslt_map, MAP_SIZE);
    }
    if (mem_fd >= 0) {
        close(mem_fd);
    }
#endif
    ddr_feat     = nullptr;
    ddr_wght     = nullptr;
    ddr_rslt     = nullptr;
    axilite_map  = nullptr;
    dma_feat_map = nullptr;
    dma_wght_map = nullptr;
    dma_rslt_map = nullptr;
    mem_fd       = -1;
    g_ready      = false;
}

bool fpga_gemm_is_ready() {
    if (g_ready) {
        return true;
    }
    std::lock_guard<std::mutex> lock(g_init_mutex);
    if (!g_ready) {
        g_ready = fpga_gemm_init();
    }
    return g_ready;
}

// ── fpga_gemm_run ──────────────────────────────────────────────────────────
// Math pipeline:
//   A) scale_B = max|B|/127 ; feat_q = clamp(round(B/scale_B), -128,127)
//   B) scale_W = max|W|/127 ; wght_q = clamp(round(W/scale_W), -128,127)  [cached]
//   C) FPGA: acc[m,n] = sum_k feat_q[m,k]*wght_q[k,n]  → rslt = clamp(acc>>shift, -128,127)
//   D) C[m,n] = rslt[m,n] * scale_B * scale_W * 2^shift
//
// Important layout contract:
//   - A_raw/src0 is ggml weight, logical src0 shape [K,N], stored row-by-row as W[n*K+k].
//   - B_f32/src1 is activation, logical src1 shape [K,M], passed here as B[m*K+k].
//   - C/dst is written as C[m*N+n], which matches ggml dst memory because dst ne0=N.
void fpga_gemm_run(const void *  A_raw,
                   FpgaQuantType quant,
                   const float * B_f32,
                   float *       C,
                   int           M,
                   int           K_orig,
                   int           N_orig,
                   int           shift_in) {
    if (!g_ready) {
        fprintf(stderr, "[FPGA] not initialised\n");
        return;
    }
    if (M <= 0 || K_orig <= 0 || N_orig <= 0) {
        fprintf(stderr, "[FPGA] invalid shape M=%d K=%d N=%d\n", M, K_orig, N_orig);
        return;
    }

    const int TILE     = ARRAY_SIZE;
    int       K_pad    = align32(K_orig);
    int       N_pad    = align32(N_orig);
    int       k_blocks = K_pad / TILE;
    int       n_blocks = N_pad / TILE;

    // Current RTL register widths: row_count=9 bits, k/n block count=5 bits.
    // Do not launch when values would truncate in the AXI-Lite registers.
    if (M > 511 || k_blocks < 1 || k_blocks > 31 || n_blocks < 1 || n_blocks > 31) {
        fprintf(stderr, "[FPGA] shape unsupported by current RTL regs: M=%d K=%d(Kb=%d) N=%d(Nb=%d)\n", M, K_orig,
                k_blocks, N_orig, n_blocks);
        return;
    }

    uint64_t feature_beats = (uint64_t) M * (uint64_t) k_blocks;
    uint64_t weight_beats  = (uint64_t) k_blocks * (uint64_t) ARRAY_SIZE * (uint64_t) n_blocks;
    uint64_t result_beats  = (uint64_t) M * (uint64_t) n_blocks;
    if (feature_beats > IP_BUFFER_DEPTH || weight_beats > IP_BUFFER_DEPTH || result_beats > IP_BUFFER_DEPTH) {
        fprintf(
            stderr,
            "[FPGA] shape exceeds RTL buffer depth: feature_beats=%llu weight_beats=%llu result_beats=%llu depth=%d\n",
            (unsigned long long) feature_beats, (unsigned long long) weight_beats, (unsigned long long) result_beats,
            IP_BUFFER_DEPTH);
        return;
    }

    uint64_t feat_bytes64 = (uint64_t) M * (uint64_t) K_pad;
    uint64_t rslt_bytes64 = (uint64_t) M * (uint64_t) N_pad;
    uint64_t wght_bytes64 = (uint64_t) K_pad * (uint64_t) N_pad;
    if (feat_bytes64 > DDR_FEAT_SIZE || rslt_bytes64 > DDR_RSLT_SIZE || wght_bytes64 > DDR_WGHT_SIZE ||
        feat_bytes64 > 0xFFFFFFFFULL || rslt_bytes64 > 0xFFFFFFFFULL) {
        fprintf(stderr, "[FPGA] DDR window too small for M=%d K=%d N=%d\n", M, K_orig, N_orig);
        return;
    }

    uint32_t feat_bytes = (uint32_t) feat_bytes64;
    uint32_t rslt_bytes = (uint32_t) rslt_bytes64;

    // A: quantize activation B[m,k] → int8 feature stream, zero-pad K → K_pad.
    float max_abs_B = 1e-9f;
    for (int i = 0; i < M * K_orig; i++) {
        float v = fabsf(B_f32[i]);
        if (v > max_abs_B) {
            max_abs_B = v;
        }
    }
    float scale_B     = max_abs_B / 127.0f;
    float inv_scale_B = 127.0f / max_abs_B;
    memset(ddr_feat, 0, feat_bytes);
    for (int m = 0; m < M; m++) {
        for (int k = 0; k < K_orig; k++) {
            int iv                  = (int) roundf(B_f32[m * K_orig + k] * inv_scale_B);
            iv                      = iv > 127 ? 127 : iv < -128 ? -128 : iv;
            ddr_feat[m * K_pad + k] = (int8_t) iv;
        }
    }
    memset(ddr_rslt, 0, rslt_bytes);

#ifndef _WIN32
    __sync_synchronize();
    (void) msync(ddr_feat, feat_bytes, MS_SYNC);
    (void) msync(ddr_rslt, rslt_bytes, MS_SYNC);
#endif

    // B: cache/dequantize/transpose weight once per ggml weight pointer.
    WeightEntry we;
    auto        it = g_weight_cache.find(A_raw);
    if (it != g_weight_cache.end()) {
        we = it->second;
    } else {
        switch (quant) {
            case FPGA_QUANT_Q5_0:
                we = cache_q5_0(A_raw, K_orig, N_orig);
                break;
            case FPGA_QUANT_Q8_0:
                we = cache_q8_0(A_raw, K_orig, N_orig);
                break;
            case FPGA_QUANT_Q4_K:
                we = cache_q4_K(A_raw, K_orig, N_orig);
                break;
            default:
                fprintf(stderr, "[FPGA] unknown quant type %d\n", (int) quant);
                return;
        }
        if (!we.phys_addr) {
            fprintf(stderr, "[FPGA] weight alloc failed\n");
            return;
        }
        g_weight_cache[A_raw] = we;
    }

    if (we.K_pad != K_pad || we.N_pad != N_pad || we.size != (uint32_t) wght_bytes64) {
        fprintf(stderr, "[FPGA] padding mismatch: cached(%d,%d,%u) vs current(%d,%d,%llu)\n", we.K_pad, we.N_pad,
                we.size, K_pad, N_pad, (unsigned long long) wght_bytes64);
        return;
    }

    // C: choose shift. Use ceil(log2(K_pad*127)) so worst-case int8 accumulation fits int8 output better.
    int shift = shift_in;
    if (shift <= 0) {
        shift = (int) ceil(log2((double) K_pad * 127.0));
        shift = shift < 0 ? 0 : shift > 24 ? 24 : shift;
    }

#ifndef _WIN32
    if (!gemm_configure((uint32_t) shift, (uint32_t) M, (uint32_t) k_blocks, (uint32_t) n_blocks)) {
        return;
    }

    // D: Safe DMA order for this RTL: result S2MM first, then feature/weight MM2S.
    dma_s2mm_start(dma_rslt_map, DDR_RSLT_BASE, rslt_bytes);
    dma_mm2s_start(dma_feat_map, DDR_FEAT_BASE, feat_bytes);
    dma_mm2s_start(dma_wght_map, we.phys_addr, we.size);

    bool ok0 = dma_wait_done(dma_feat_map, DMA_MM2S_SR, "feature MM2S");
    bool ok1 = dma_wait_done(dma_wght_map, DMA_MM2S_SR, "weight MM2S");
    bool ok2 = dma_wait_done(dma_rslt_map, DMA_S2MM_SR, "result S2MM");
    if (!ok0 || !ok1 || !ok2) {
        return;
    }

    __sync_synchronize();
    (void) msync(ddr_rslt, rslt_bytes, MS_INVALIDATE);
#else
    // Windows mock path can keep its own internal behavior.
    *(uint32_t *) ((char *) axilite_map + REG_SHIFT)    = (uint32_t) shift;
    *(uint32_t *) ((char *) axilite_map + REG_F_LENGTH) = (uint32_t) M;
    *(uint32_t *) ((char *) axilite_map + REG_F_WIDTH)  = (uint32_t) k_blocks;
    *(uint32_t *) ((char *) axilite_map + REG_W_WIDTH)  = (uint32_t) n_blocks;
#endif

    // E: dequant result int8 → float.
    float out_scale = ldexpf(scale_B * we.scale_W, shift);
    for (int m = 0; m < M; m++) {
        for (int n = 0; n < N_orig; n++) {
            C[m * N_orig + n] = (float) ddr_rslt[m * N_pad + n] * out_scale;
        }
    }

#ifdef _WIN32
    {
        static int dbg_count = 0;
        if (dbg_count++ != 0) {
            return;
        }

        int     n_elem = K_orig * N_orig;
        float * W_f    = new float[n_elem];
        int     nb;
        switch (quant) {
            case FPGA_QUANT_Q5_0:
                nb = (n_elem + QK5_0 - 1) / QK5_0;
                dequant_q5_0((const block_q5_0 *) A_raw, nb, W_f);
                break;
            case FPGA_QUANT_Q8_0:
                nb = (n_elem + QK8_0 - 1) / QK8_0;
                dequant_q8_0((const block_q8_0 *) A_raw, nb, W_f);
                break;
            case FPGA_QUANT_Q4_K:
                nb = (n_elem + QK_K - 1) / QK_K;
                dequant_q4_K((const block_q4_K *) A_raw, nb, W_f);
                break;
            default:
                break;
        }

        float * C_ref = new float[M * N_orig]();
        for (int m = 0; m < M; m++) {
            for (int k = 0; k < K_orig; k++) {
                for (int n = 0; n < N_orig; n++) {
                    // W_f is ggml row layout: W_f[n*K + k].
                    C_ref[m * N_orig + n] += B_f32[m * K_orig + k] * W_f[n * K_orig + k];
                }
            }
        }

        float max_diff = 0, max_rel = 0, sum_diff = 0;
        for (int i = 0; i < M * N_orig; i++) {
            float diff = fabsf(C[i] - C_ref[i]);
            float rel  = diff / (fabsf(C_ref[i]) + 1e-6f);
            if (diff > max_diff) {
                max_diff = diff;
            }
            if (rel > max_rel) {
                max_rel = rel;
            }
            sum_diff += diff;
        }
        printf("[REF] M=%d K=%d N=%d shift=%d\n", M, K_orig, N_orig, shift);
        printf("[REF] scale_B=%.4e scale_W=%.4e out_scale=%.4e\n", scale_B, we.scale_W, out_scale);
        printf("[REF] max_abs=%.4e mean_abs=%.4e max_rel=%.2f%%\n", max_diff, sum_diff / (float) (M * N_orig),
               max_rel * 100.0f);
        printf("[REF] Sample n=0..7:");
        for (int n = 0; n < 8 && n < N_orig; n++) {
            printf(" [%d] fpga=%.4f ref=%.4f", n, C[n], C_ref[n]);
        }
        printf("\n");

        delete[] W_f;
        delete[] C_ref;
    }
#endif
}
