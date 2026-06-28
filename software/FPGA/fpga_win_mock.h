#pragma once

#ifdef _WIN32

#    ifndef NOMINMAX
#        define NOMINMAX
#    endif

#    ifndef WIN32_LEAN_AND_MEAN
#        define WIN32_LEAN_AND_MEAN
#    endif

#    include <windows.h>

#    ifdef min
#        undef min
#    endif

#    ifdef max
#        undef max
#    endif

#    include <cstdint>
#    include <cstdio>
#    include <cstring>
#    include <vector>

static inline void fix_console_utf8() {
    SetConsoleOutputCP(CP_UTF8);
    SetConsoleCP(CP_UTF8);

    HANDLE h = GetStdHandle(STD_OUTPUT_HANDLE);
    if (h != INVALID_HANDLE_VALUE) {
        DWORD mode = 0;
        if (GetConsoleMode(h, &mode)) {
            SetConsoleMode(h, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
        }
    }
}

// POSIX-like constants for Windows build
#    define _SYS_MMAN_H
#    define _UNISTD_H
#    define _FCNTL_H

#    ifndef O_RDWR
#        define O_RDWR 2
#    endif

#    ifndef O_SYNC
#        define O_SYNC 0
#    endif

#    ifndef PROT_READ
#        define PROT_READ 0x1
#    endif

#    ifndef PROT_WRITE
#        define PROT_WRITE 0x2
#    endif

#    ifndef MAP_SHARED
#        define MAP_SHARED 0x01
#    endif

#    ifndef MAP_FAILED
#        define MAP_FAILED ((void *) -1)
#    endif

// AXI-Lite register offsets, same as FPGA_GEMM.cpp
#    define MOCK_REG_SHIFT    0x00
#    define MOCK_REG_F_LENGTH 0x04
#    define MOCK_REG_F_WIDTH  0x08
#    define MOCK_REG_W_WIDTH  0x0C
#    define MOCK_ARRAY_SIZE   32

// DDR base addresses, same as FPGA_GEMM.cpp
#    define MOCK_FEAT_BASE 0x10000000ULL
#    define MOCK_WGHT_BASE 0x20000000ULL
#    define MOCK_RSLT_BASE 0x70000000ULL

// AXI-Lite / DMA controller base addresses, same as FPGA_GEMM.cpp
#    define MOCK_AXILITE_BASE  0xA0000000ULL
#    define MOCK_DMA_FEAT_BASE 0xA0010000ULL
#    define MOCK_DMA_WGHT_BASE 0xA0020000ULL
#    define MOCK_DMA_RSLT_BASE 0xA0030000ULL

#    ifndef DMA_SR_IDLE
#        define DMA_SR_IDLE 0x0002
#    endif

#    ifndef DMA_SR_IOC_IRQ
#        define DMA_SR_IOC_IRQ 0x1000
#    endif

static std::vector<uint8_t> g_axilite;        // AXI-Lite config regs 64KB
static std::vector<uint8_t> g_dma_feat_regs;  // DMA feature regs 64KB
static std::vector<uint8_t> g_dma_wght_regs;  // DMA weight regs 64KB
static std::vector<uint8_t> g_dma_rslt_regs;  // DMA result regs 64KB
static std::vector<uint8_t> g_ddr_feat;       // Feature DDR 64MB
static std::vector<uint8_t> g_ddr_wght;       // Weight DDR 512MB
static std::vector<uint8_t> g_ddr_rslt;       // Result DDR 64MB

static bool g_mock_ready = false;

static uint64_t g_feat_phys  = 0;
static uint32_t g_feat_bytes = 0;
static uint64_t g_wght_phys  = 0;
static uint32_t g_wght_bytes = 0;
static uint64_t g_rslt_phys  = 0;
static uint32_t g_rslt_bytes = 0;

static inline void mock_init() {
    if (g_mock_ready) {
        return;
    }

    fix_console_utf8();

    printf("[MOCK] Allocating buffers...\n");

    g_axilite.assign(0x10000, 0);
    g_dma_feat_regs.assign(0x10000, 0);
    g_dma_wght_regs.assign(0x10000, 0);
    g_dma_rslt_regs.assign(0x10000, 0);

    g_ddr_feat.assign(0x04000000ULL, 0);  // 64MB
    g_ddr_wght.assign(0x20000000ULL, 0);  // 512MB
    g_ddr_rslt.assign(0x04000000ULL, 0);  // 64MB

    printf("[MOCK] Buffers ready\n");

    g_mock_ready = true;
}

static inline bool mock_range_ok(uint64_t phys, uint64_t base, size_t bytes, size_t region_size) {
    if (phys < base) {
        return false;
    }

    const uint64_t off = phys - base;
    return off + bytes <= region_size;
}

// Software GEMM mock of the FPGA datapath.
//
// Layout:
//   feature: [M x K_pad]
//   weight : [K_pad x N_pad]
//   result : [M x N_pad]
//
// Behavior:
//   int32 acc = sum(feature_int8 * weight_int8)
//   right shift by AXI-Lite shift value
//   round
//   clamp to signed int8
static inline void mock_compute_gemm() {
    if (!g_mock_ready) {
        fprintf(stderr, "[MOCK] not initialized\n");
        return;
    }

    const uint32_t axi_shift_reg     = *(uint32_t *) (g_axilite.data() + MOCK_REG_SHIFT);
    const uint32_t mock_shift_amount = axi_shift_reg & 0x3FF;

    const int M = (int) (*(uint32_t *) (g_axilite.data() + MOCK_REG_F_LENGTH));
    const int K = (int) (*(uint32_t *) (g_axilite.data() + MOCK_REG_F_WIDTH)) * MOCK_ARRAY_SIZE;
    const int N = (int) (*(uint32_t *) (g_axilite.data() + MOCK_REG_W_WIDTH)) * MOCK_ARRAY_SIZE;

    if (M <= 0 || K <= 0 || N <= 0) {
        fprintf(stderr, "[MOCK] invalid config M=%d K=%d N=%d mock_shift_amount=%u\n", M, K, N, mock_shift_amount);
        return;
    }

    if (!mock_range_ok(g_feat_phys, MOCK_FEAT_BASE, (size_t) M * (size_t) K, g_ddr_feat.size())) {
        fprintf(stderr, "[MOCK] feature phys invalid phys=0x%llx bytes=%u M=%d K=%d\n",
                (unsigned long long) g_feat_phys, g_feat_bytes, M, K);
        return;
    }

    if (!mock_range_ok(g_wght_phys, MOCK_WGHT_BASE, (size_t) K * (size_t) N, g_ddr_wght.size())) {
        fprintf(stderr, "[MOCK] weight phys invalid phys=0x%llx bytes=%u K=%d N=%d\n", (unsigned long long) g_wght_phys,
                g_wght_bytes, K, N);
        return;
    }

    if (!mock_range_ok(g_rslt_phys, MOCK_RSLT_BASE, (size_t) M * (size_t) N, g_ddr_rslt.size())) {
        fprintf(stderr, "[MOCK] result phys invalid phys=0x%llx bytes=%u M=%d N=%d\n", (unsigned long long) g_rslt_phys,
                g_rslt_bytes, M, N);
        return;
    }

    const int8_t * feat = (const int8_t *) (g_ddr_feat.data() + (g_feat_phys - MOCK_FEAT_BASE));
    const int8_t * wght = (const int8_t *) (g_ddr_wght.data() + (g_wght_phys - MOCK_WGHT_BASE));
    int8_t *       rslt = (int8_t *) (g_ddr_rslt.data() + (g_rslt_phys - MOCK_RSLT_BASE));

    int32_t max_abs_acc = 1;

    printf("[MOCK] GEMM start M=%d K=%d N=%d mock_shift_amount=%u\n", M, K, N, mock_shift_amount);

    for (int m = 0; m < M; ++m) {
        for (int n = 0; n < N; ++n) {
            int32_t acc = 0;

            for (int k = 0; k < K; ++k) {
                const int32_t a = (int32_t) feat[m * K + k];
                const int32_t b = (int32_t) wght[k * N + n];
                acc += a * b;
            }

            const int32_t abs_acc = acc < 0 ? -acc : acc;
            if (abs_acc > max_abs_acc) {
                max_abs_acc = abs_acc;
            }

            int32_t v = acc;

            if (mock_shift_amount > 0) {
                const int32_t round = 1 << (mock_shift_amount - 1);

                if (v >= 0) {
                    v = (v + round) >> mock_shift_amount;
                } else {
                    v = -(((-v) + round) >> mock_shift_amount);
                }
            }

            if (v > 127) {
                v = 127;
            } else if (v < -128) {
                v = -128;
            }

            rslt[m * N + n] = (int8_t) v;
        }
    }

    printf("[MOCK] GEMM done M=%d K=%d N=%d mock_shift_amount=%u max_acc=%d\n", M, K, N, mock_shift_amount,
           max_abs_acc);
}

// POSIX stubs
static inline int open(const char * path, int) {
    mock_init();
    printf("[MOCK] open(\"%s\")\n", path);
    return 3;
}

static inline int close(int) {
    return 0;
}

static inline void usleep(unsigned) {}

static inline int munmap(void *, size_t) {
    return 0;
}

// mmap receives uint64_t offset directly.
// This avoids sign extension through MSVC off_t.
static inline void * mmap(void *, size_t len, int, int, int, uint64_t offset) {
    mock_init();

    printf("[MOCK] mmap offset=0x%llx size=0x%zx\n", (unsigned long long) offset, len);

    if (offset == MOCK_AXILITE_BASE) {
        return g_axilite.data();
    }

    if (offset == MOCK_DMA_FEAT_BASE) {
        return g_dma_feat_regs.data();
    }

    if (offset == MOCK_DMA_WGHT_BASE) {
        return g_dma_wght_regs.data();
    }

    if (offset == MOCK_DMA_RSLT_BASE) {
        return g_dma_rslt_regs.data();
    }

    if (offset == MOCK_FEAT_BASE) {
        return g_ddr_feat.data();
    }

    if (offset == MOCK_WGHT_BASE) {
        return g_ddr_wght.data();
    }

    if (offset == MOCK_RSLT_BASE) {
        return g_ddr_rslt.data();
    }

    printf("[MOCK][WARN] unknown mmap offset=0x%llx\n", (unsigned long long) offset);

    return MAP_FAILED;
}

static inline uint32_t mock_rd32(void * base, uint32_t off) {
    if (base == (void *) g_axilite.data() && off + 4 <= g_axilite.size()) {
        return *(uint32_t *) (g_axilite.data() + off);
    }

    if (base == (void *) g_dma_feat_regs.data() && off + 4 <= g_dma_feat_regs.size()) {
        return DMA_SR_IDLE | DMA_SR_IOC_IRQ;
    }

    if (base == (void *) g_dma_wght_regs.data() && off + 4 <= g_dma_wght_regs.size()) {
        return DMA_SR_IDLE | DMA_SR_IOC_IRQ;
    }

    if (base == (void *) g_dma_rslt_regs.data() && off + 4 <= g_dma_rslt_regs.size()) {
        return DMA_SR_IDLE | DMA_SR_IOC_IRQ;
    }

    return DMA_SR_IDLE | DMA_SR_IOC_IRQ;
}

static inline void mock_wr32(void * base, uint32_t off, uint32_t val) {
    if (base == (void *) g_axilite.data() && off + 4 <= g_axilite.size()) {
        *(uint32_t *) (g_axilite.data() + off) = val;
        return;
    }

    if (base == (void *) g_dma_feat_regs.data() && off + 4 <= g_dma_feat_regs.size()) {
        *(uint32_t *) (g_dma_feat_regs.data() + off) = val;
        return;
    }

    if (base == (void *) g_dma_wght_regs.data() && off + 4 <= g_dma_wght_regs.size()) {
        *(uint32_t *) (g_dma_wght_regs.data() + off) = val;
        return;
    }

    if (base == (void *) g_dma_rslt_regs.data() && off + 4 <= g_dma_rslt_regs.size()) {
        *(uint32_t *) (g_dma_rslt_regs.data() + off) = val;
        return;
    }
}

static inline void mock_dma_reset(void *) {
    g_feat_phys  = 0;
    g_feat_bytes = 0;
    g_wght_phys  = 0;
    g_wght_bytes = 0;
    g_rslt_phys  = 0;
    g_rslt_bytes = 0;
}

static inline void mock_dma_send(void *, uint64_t phys, uint32_t bytes) {
    if (phys >= MOCK_FEAT_BASE && phys < MOCK_WGHT_BASE) {
        g_feat_phys  = phys;
        g_feat_bytes = bytes;

        printf("[MOCK] dma_send FEAT phys=0x%llx bytes=%u\n", (unsigned long long) phys, bytes);
        return;
    }

    if (phys >= MOCK_WGHT_BASE && phys < MOCK_RSLT_BASE) {
        g_wght_phys  = phys;
        g_wght_bytes = bytes;

        printf("[MOCK] dma_send WGHT phys=0x%llx bytes=%u\n", (unsigned long long) phys, bytes);
        return;
    }

    fprintf(stderr, "[MOCK] dma_send unknown phys=0x%llx bytes=%u\n", (unsigned long long) phys, bytes);
}

static inline void mock_dma_recv_start(void *, uint64_t phys, uint32_t bytes) {
    g_rslt_phys  = phys;
    g_rslt_bytes = bytes;

    printf("[MOCK] dma_recv_start RSLT phys=0x%llx bytes=%u\n", (unsigned long long) phys, bytes);
}

static inline void mock_dma_recv_wait(void *) {
    mock_compute_gemm();
}

// Override POSIX/DMA helpers inside FPGA_GEMM.cpp on Windows.
#    define rd32(base, off)                  mock_rd32(base, off)
#    define wr32(base, off, val)             mock_wr32(base, off, val)
#    define dma_reset(dma)                   mock_dma_reset(dma)
#    define dma_send(dma, addr, bytes)       mock_dma_send(dma, addr, bytes)
#    define dma_recv_start(dma, addr, bytes) mock_dma_recv_start(dma, addr, bytes)
#    define dma_recv_wait(dma)               mock_dma_recv_wait(dma)

#endif  // _WIN32
