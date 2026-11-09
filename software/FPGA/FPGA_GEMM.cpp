#include "FPGA_GEMM.h"

#include "fpga_stats.h"
#include "fpga_win_mock.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

#ifndef GGML_COMMON_DECL_CPP
#    define GGML_COMMON_DECL_CPP
#endif

#include "ggml-common.h"
#include "ggml.h"
#include "ggml-quants.h"

#if !defined(_WIN32)
#    include <errno.h>
#    include <fcntl.h>
#    include <sys/ioctl.h>
#    include <sys/mman.h>
#    include <sys/stat.h>
#    include <unistd.h>
#endif

// -----------------------------------------------------------------------------
// KV260 address map matching current RTL/Vivado design.
// -----------------------------------------------------------------------------
static constexpr uint64_t FPGA_CTRL_BASE = 0xA0000000ull;  // AXI-Lite control / GEMM_top
static constexpr uint64_t FPGA_DMA0_BASE = 0xA0010000ull;  // feature MM2S
static constexpr uint64_t FPGA_DMA1_BASE = 0xA0020000ull;  // weight MM2S
static constexpr uint64_t FPGA_DMA2_BASE = 0xA0030000ull;  // result S2MM
static constexpr size_t   FPGA_MAP_SIZE  = 0x10000;

static constexpr uint32_t DMA_MM2S_DMACR  = 0x00;
static constexpr uint32_t DMA_MM2S_DMASR  = 0x04;
static constexpr uint32_t DMA_MM2S_SA     = 0x18;
static constexpr uint32_t DMA_MM2S_SA_MSB = 0x1C;
static constexpr uint32_t DMA_MM2S_LEN    = 0x28;

static constexpr uint32_t DMA_S2MM_DMACR  = 0x30;
static constexpr uint32_t DMA_S2MM_DMASR  = 0x34;
static constexpr uint32_t DMA_S2MM_DA     = 0x48;
static constexpr uint32_t DMA_S2MM_DA_MSB = 0x4C;
static constexpr uint32_t DMA_S2MM_LEN    = 0x58;

static constexpr uint32_t DMA_CR_RS      = 0x00000001u;
static constexpr uint32_t DMA_CR_RESET   = 0x00000004u;
static constexpr uint32_t DMA_SR_IDLE    = 0x00000002u;
static constexpr uint32_t DMA_SR_IOC_IRQ = 0x00001000u;
// AXI DMA status error bits only.
// 0x1000 is IOC_IRQ / transfer done, so it MUST NOT be included here.
// Previous mask 0x00007070 incorrectly treated DMASR=0x00001002 as an error.
static constexpr uint32_t DMA_SR_ERR_ALL = 0x00004770u;

static constexpr uint32_t CTRL_SHIFT = 0x00;
static constexpr uint32_t CTRL_FL    = 0x04;
static constexpr uint32_t CTRL_FWBN  = 0x08;
static constexpr uint32_t CTRL_WWBN  = 0x0C;

// Current RTL-safe policy.
static constexpr int HW_K_SUPPORTED  = 896;   // Stable non-tiled K.
static constexpr int HW_K_TILE_MAX   = 896;   // Max FWBN-safe software K tile.
static constexpr int HW_K_TILE_ALT   = 384;   // Useful Qwen K=4864 remainder.
static constexpr int HW_N_TILE       = 64;    // Preferred N columns per RTL run.
static constexpr int HW_N_TILE_MIN   = 32;    // Fallback N columns per RTL run.
static constexpr int HW_N_MAX        = 4864;  // Skip token_embd/logits-like huge tensors.
static constexpr int HW_M_MIN        = 32;    // Small-M pad32 floor.
static constexpr int HW_M_TILE       = 64;    // ggml hook calls hardware in <=64 row chunks.
static constexpr int HW_BUFFER_LIMIT = 2400;  // RTL internal feature block limit: M_hw * (K/32) <= 2400.

// Packed weight dump format.
// File is an append-only record log. If a tensor is not present, userspace packs it
// once and appends a new record. Next run loads from file instead of packing again.
static constexpr uint32_t DUMP_REC_MAGIC = 0x34574746u;  // "FGW4" little endian: Q6/K-tiling metadata.
static constexpr uint32_t DUMP_REC_VER   = 4;

// -----------------------------------------------------------------------------
// /dev/gemm_dma_buf UAPI.
// If your driver uses different ioctl or mmap layout, edit only this section.
// -----------------------------------------------------------------------------
#if !defined(_WIN32)
// Backward-compatible old UAPI used by your 1 MB driver.
struct gemm_dma_buf_info_old {
    uint64_t a_phys;
    uint64_t b_phys;
    uint64_t c_phys;
    uint32_t size;
};

static_assert(sizeof(gemm_dma_buf_info_old) == 32, "old gemm_dma_buf_info size mismatch");

// New large-buffer UAPI. Sizes are per-buffer, so A/B/C can be different.
struct gemm_dma_buf_info_ex {
    uint64_t a_phys;
    uint64_t b_phys;
    uint64_t c_phys;
    uint64_t a_size;
    uint64_t b_size;
    uint64_t c_size;
};

static_assert(sizeof(gemm_dma_buf_info_ex) == 48, "new gemm_dma_buf_info_ex size mismatch");

#    define GEMM_BUF_IOCTL_MAGIC           'G'
#    define GEMM_DMA_BUF_IOCTL_GET_INFO    _IOR(GEMM_BUF_IOCTL_MAGIC, 1, struct gemm_dma_buf_info_old)
#    define GEMM_DMA_BUF_IOCTL_GET_INFO_EX _IOR(GEMM_BUF_IOCTL_MAGIC, 2, struct gemm_dma_buf_info_ex)
#endif

#pragma pack(push, 1)

struct DumpRecordHeader {
    uint32_t magic;
    uint32_t version;
    uint64_t fingerprint;
    uint32_t quant;
    uint32_t K;
    uint32_t N;
    uint32_t tile_count;
    uint64_t record_bytes;
};

struct DumpTileHeader {
    uint32_t n0;
    uint32_t cur_N;
    uint32_t N_pad;
    uint32_t k0;
    uint32_t K_tile;
    uint32_t reserved;
    uint64_t weight_bytes;
    uint64_t scale_count;
    uint64_t sum_abs_count;
    float    max_sum_abs_w;
};

#pragma pack(pop)

enum class FpgaBackend {
    UNINIT = 0,
    MOCK   = 1,
    HW     = 2,
    NONE   = 3,
};

enum class BCacheMode {
    PERSISTENT = 0,
    SCRATCH    = 1,
};

enum class ShiftMode {
    EXACT   = 0,
    CACHED  = 1,
    SAMPLED = 2,
    FAST    = 3,
    FIXED   = 4,
    TABLE   = 5,
};

enum class ShiftTableMissPolicy {
    CPU_FALLBACK = 0,
    FIXED        = 1,
    CACHED       = 2,
    EXACT        = 3,
};

enum class DmaResetMode {
    EACH_TILE = 0,
    ONCE_CALL = 1,
    ON_ERROR  = 2,
};

enum class DmaWaitStatus {
    DONE    = 0,
    ERROR   = 1,
    TIMEOUT = 2,
};

struct HwContext {
#if !defined(_WIN32)
    int fd_mem = -1;
    int fd_buf = -1;

    volatile uint32_t * dma0 = nullptr;
    volatile uint32_t * dma1 = nullptr;
    volatile uint32_t * dma2 = nullptr;
    volatile uint32_t * ctrl = nullptr;

    uint8_t * buf_base     = nullptr;
    size_t    buf_map_size = 0;

    uint8_t * feature_v = nullptr;
    uint8_t * weight_v  = nullptr;
    uint8_t * result_v  = nullptr;

    size_t feature_map_size = 0;
    size_t weight_map_size  = 0;
    size_t result_map_size  = 0;

    uint64_t a_phys = 0;
    uint64_t b_phys = 0;
    uint64_t c_phys = 0;
    size_t   a_size = 0;
    size_t   b_size = 0;
    size_t   c_size = 0;
#endif
    bool ready = false;
};

struct PackedTile {
    int n0     = 0;
    int cur_N  = 0;
    int N_pad  = 0;
    int k0     = 0;
    int K_tile = 0;

    // K-major hardware layout:
    //   qw[k * N_pad + n] = quantized weight for output column n and input k
    std::vector<int8_t> qw;
    std::vector<float>  scale_w;

    // Precomputed shift metadata:
    //   bound_acc <= max_abs_x * sum_abs_w[n]
    // Runtime chooses shift from this bound, without scanning all K products.
    std::vector<float> sum_abs_w;
    float              max_sum_abs_w = 0.0f;
    int                cached_shift  = -1;

#if !defined(_WIN32)
    uint64_t hw_phys     = 0;
    size_t   hw_bytes    = 0;
    bool     hw_resident = false;
#endif
};

struct PackedRecord {
    uint64_t                fingerprint = 0;
    FpgaQuantType           quant       = FPGA_QUANT_Q5_0;
    int                     K           = 0;
    int                     N           = 0;
    std::vector<PackedTile> tiles;
};

struct PreparedWeight {
    const void *   A_raw       = nullptr;
    uint64_t       fingerprint = 0;
    FpgaQuantType  quant       = FPGA_QUANT_Q5_0;
    int            K           = 0;
    int            N           = 0;
    PackedRecord * record      = nullptr;
};

struct ShiftTableKey {
    std::string tensor_name;
    int         layer_id = -1;
    std::string op_group;
    std::string qtype;
    std::string m_bucket;
    int         K = 0;
    int         N = 0;
    int         k0 = 0;
    int         K_tile = 0;
    int         n0 = 0;
    int         N_tile = 0;
};

struct ShiftTableRow {
    ShiftTableKey key;
    int           shift = 0;
    std::string   calib_mae = "NA";
    std::string   calib_max_abs_error = "NA";
    std::string   calib_match_rate = "NA";
    uint64_t      num_samples = 0;
};

enum class ShiftTableLookupKind {
    MISS     = 0,
    EXACT    = 1,
    FALLBACK = 2,
};

enum class ReconstructionCheckMode {
    FULL = 0,
    OFF  = 1,
};

static FpgaBackend g_backend = FpgaBackend::UNINIT;
static HwContext   g_hw;
static BCacheMode  g_b_cache_mode       = BCacheMode::PERSISTENT;
static bool        g_b_cache_mode_inited = false;
static ShiftMode   g_shift_mode         = ShiftMode::EXACT;
static bool        g_shift_mode_inited  = false;
static int         g_fixed_shift        = 5;
static std::string g_shift_table_path   = "fpga_shift_table.tsv";
static bool        g_shift_table_append = false;
static ShiftTableMissPolicy g_shift_table_miss_policy = ShiftTableMissPolicy::CPU_FALLBACK;
static bool        g_shift_table_loaded = false;
static std::string g_tensor_context;
static DmaResetMode g_dma_reset_mode        = DmaResetMode::EACH_TILE;
static bool         g_dma_reset_mode_inited = false;
static bool         g_dma_reset_ready       = false;
static bool         g_runtime_env_inited    = false;
static bool         g_force_full_offload    = false;
static bool         g_experimental_k_tiling = false;
static bool         g_small_m_pad32         = false;
static bool         g_fpga_verbose          = false;
static ReconstructionCheckMode g_reconstruction_check_mode = ReconstructionCheckMode::FULL;

static std::mutex                                 g_init_mutex;
static std::mutex                                 g_weight_mutex;
static std::vector<std::unique_ptr<PackedRecord>> g_records;
static std::vector<PreparedWeight>                g_prepared_cache;
static std::vector<ShiftTableRow>                 g_shift_table_rows;
static std::unordered_map<std::string, size_t>    g_shift_table_exact_index;
static std::unordered_map<std::string, size_t>    g_shift_table_fallback_index;
static std::unordered_map<std::string, size_t>    g_shift_table_fallback_empty_tensor_index;
static bool                                       g_dump_loaded = false;

#if !defined(_WIN32)
static size_t g_weight_bank_offset = 0;

static inline size_t align_up_size(size_t x, size_t a) {
    return (x + a - 1) & ~(a - 1);
}
#endif

// -----------------------------------------------------------------------------
// Numeric helpers.
// -----------------------------------------------------------------------------
static inline int8_t clamp_i8_symmetric(int v) {
    if (v > 127) {
        return 127;
    }
    if (v < -127) {
        return -127;
    }
    return (int8_t) v;
}

static inline int8_t saturate_after_shift_to_i8(int64_t v) {
    if (v > 127) {
        return 127;
    }
    if (v < -128) {
        return -128;
    }
    return (int8_t) v;
}

// Emulate current RTL Right_Shifter:
//   temp1_out = data_in >>> shift;
//   temp2_out = data_in[shift-1] ? temp1_out + 1 : temp1_out;
//   saturate to int8.
static inline int8_t rtl_right_shift_round_sat(int64_t acc, int shift) {
    int64_t shifted = acc;

    if (shift > 0) {
        shifted                 = acc >> shift;
        const int64_t round_bit = (acc >> (shift - 1)) & 1ll;
        if (round_bit) {
            shifted += 1;
        }
    }

    return saturate_after_shift_to_i8(shifted);
}

static inline int round_to_int(float x) {
    return (int) lrintf(x);
}

static enum ggml_type fpga_quant_to_ggml_type(FpgaQuantType quant) {
    switch (quant) {
        case FPGA_QUANT_F32: return GGML_TYPE_F32;
        case FPGA_QUANT_F16: return GGML_TYPE_F16;
        case FPGA_QUANT_BF16: return GGML_TYPE_BF16;
        case FPGA_QUANT_Q1_0: return GGML_TYPE_Q1_0;
        case FPGA_QUANT_Q4_0: return GGML_TYPE_Q4_0;
        case FPGA_QUANT_Q4_1: return GGML_TYPE_Q4_1;
        case FPGA_QUANT_Q5_0: return GGML_TYPE_Q5_0;
        case FPGA_QUANT_Q5_1: return GGML_TYPE_Q5_1;
        case FPGA_QUANT_Q8_0: return GGML_TYPE_Q8_0;
        case FPGA_QUANT_MXFP4: return GGML_TYPE_MXFP4;
        case FPGA_QUANT_NVFP4: return GGML_TYPE_NVFP4;
        case FPGA_QUANT_Q2_K: return GGML_TYPE_Q2_K;
        case FPGA_QUANT_Q3_K: return GGML_TYPE_Q3_K;
        case FPGA_QUANT_Q4_K: return GGML_TYPE_Q4_K;
        case FPGA_QUANT_Q5_K: return GGML_TYPE_Q5_K;
        case FPGA_QUANT_Q6_K: return GGML_TYPE_Q6_K;
        case FPGA_QUANT_IQ2_XXS: return GGML_TYPE_IQ2_XXS;
        case FPGA_QUANT_IQ2_XS: return GGML_TYPE_IQ2_XS;
        case FPGA_QUANT_IQ3_XXS: return GGML_TYPE_IQ3_XXS;
        case FPGA_QUANT_IQ1_S: return GGML_TYPE_IQ1_S;
        case FPGA_QUANT_IQ4_NL: return GGML_TYPE_IQ4_NL;
        case FPGA_QUANT_IQ3_S: return GGML_TYPE_IQ3_S;
        case FPGA_QUANT_IQ2_S: return GGML_TYPE_IQ2_S;
        case FPGA_QUANT_IQ4_XS: return GGML_TYPE_IQ4_XS;
        case FPGA_QUANT_IQ1_M: return GGML_TYPE_IQ1_M;
        case FPGA_QUANT_TQ1_0: return GGML_TYPE_TQ1_0;
        case FPGA_QUANT_TQ2_0: return GGML_TYPE_TQ2_0;
    }

    return GGML_TYPE_COUNT;
}

static inline size_t fpga_row_size_bytes(FpgaQuantType quant, int K) {
    if (K <= 0) {
        return 0;
    }

    const enum ggml_type type = fpga_quant_to_ggml_type(quant);
    if (type == GGML_TYPE_COUNT) {
        return 0;
    }

    const int64_t blck = ggml_blck_size(type);
    if (blck <= 0 || (K % blck) != 0) {
        return 0;
    }

    return ggml_row_size(type, K);
}

static inline bool fpga_dequant_row_to_f32(const void * row_base, FpgaQuantType quant, float * dst, int K) {
    if (row_base == nullptr || dst == nullptr || K <= 0) {
        return false;
    }

    if (quant == FPGA_QUANT_F32) {
        std::memcpy(dst, row_base, (size_t) K * sizeof(float));
        return true;
    }

    const enum ggml_type type = fpga_quant_to_ggml_type(quant);
    if (type == GGML_TYPE_COUNT) {
        return false;
    }

    const struct ggml_type_traits * traits = ggml_get_type_traits(type);
    if (traits == nullptr || traits->to_float == nullptr) {
        return false;
    }

    traits->to_float(row_base, dst, K);
    return true;
}

static uint64_t fnv1a64(const void * data, size_t bytes) {
    const uint8_t * p = (const uint8_t *) data;
    uint64_t        h = 1469598103934665603ull;

    for (size_t i = 0; i < bytes; ++i) {
        h ^= (uint64_t) p[i];
        h *= 1099511628211ull;
    }

    return h;
}

static uint64_t weight_fingerprint(const void * A_raw, FpgaQuantType quant, int K, int N) {
    const size_t row_bytes = fpga_row_size_bytes(quant, K);
    if (row_bytes == 0) {
        return 0;
    }

    uint64_t h = 1469598103934665603ull;

    const uint64_t meta[3] = {
        (uint64_t) quant,
        (uint64_t) K,
        (uint64_t) N,
    };

    h ^= fnv1a64(meta, sizeof(meta));
    h *= 1099511628211ull;

    h ^= fnv1a64(A_raw, row_bytes * (size_t) N);
    h *= 1099511628211ull;

    return h;
}

static std::string dump_file_path() {
    const char * p = std::getenv("FPGA_WEIGHT_FILE");
    if (p != nullptr && p[0] != '\0') {
        return std::string(p);
    }

    // Default file name in current working directory / llama-cli bin directory.
    return std::string("qwen_fpga_weights.bin");
}

static bool env_flag_enabled(const char * name, bool default_value) {
    const char * v = std::getenv(name);
    if (v == nullptr || v[0] == '\0') {
        return default_value;
    }

    if (std::strcmp(v, "1") == 0 || std::strcmp(v, "true") == 0 || std::strcmp(v, "TRUE") == 0 ||
        std::strcmp(v, "yes") == 0 || std::strcmp(v, "YES") == 0 || std::strcmp(v, "on") == 0 ||
        std::strcmp(v, "ON") == 0) {
        return true;
    }

    if (std::strcmp(v, "0") == 0 || std::strcmp(v, "false") == 0 || std::strcmp(v, "FALSE") == 0 ||
        std::strcmp(v, "no") == 0 || std::strcmp(v, "NO") == 0 || std::strcmp(v, "off") == 0 ||
        std::strcmp(v, "OFF") == 0) {
        return false;
    }

    return default_value;
}

static bool ascii_equal_ignore_case(const char * a, const char * b) {
    if (a == nullptr || b == nullptr) {
        return false;
    }

    while (*a != '\0' && *b != '\0') {
        char ca = *a;
        char cb = *b;
        if (ca >= 'A' && ca <= 'Z') {
            ca = (char) (ca - 'A' + 'a');
        }
        if (cb >= 'A' && cb <= 'Z') {
            cb = (char) (cb - 'A' + 'a');
        }
        if (ca != cb) {
            return false;
        }
        ++a;
        ++b;
    }

    return *a == '\0' && *b == '\0';
}

static const char * b_cache_mode_name() {
    return g_b_cache_mode == BCacheMode::SCRATCH ? "scratch" : "persistent";
}

static void init_b_cache_mode_once() {
    if (g_b_cache_mode_inited) {
        return;
    }

    const char * mode = std::getenv("FPGA_B_CACHE_MODE");
    if (mode != nullptr && mode[0] != '\0') {
        if (ascii_equal_ignore_case(mode, "scratch")) {
            g_b_cache_mode = BCacheMode::SCRATCH;
        } else if (ascii_equal_ignore_case(mode, "persistent")) {
            g_b_cache_mode = BCacheMode::PERSISTENT;
        } else {
            fprintf(stderr, "[FPGA][B_CACHE] unknown mode '%s', using persistent\n", mode);
            g_b_cache_mode = BCacheMode::PERSISTENT;
        }
    } else {
        g_b_cache_mode = BCacheMode::PERSISTENT;
    }

    g_b_cache_mode_inited = true;
    fpga_stats_set_b_cache_mode(b_cache_mode_name());
    fprintf(stderr, "[FPGA][B_CACHE] mode=%s\n", b_cache_mode_name());
}

static bool b_cache_is_scratch() {
    init_b_cache_mode_once();
    return g_b_cache_mode == BCacheMode::SCRATCH;
}

static const char * shift_table_miss_policy_name();

static int env_int_clamped(const char * name, int default_value, int min_value, int max_value) {
    const char * v = std::getenv(name);
    if (v == nullptr || v[0] == '\0') {
        return default_value;
    }

    char * end = nullptr;
    long   x   = std::strtol(v, &end, 10);
    if (end == v) {
        x = default_value;
    }

    if (x < min_value) {
        x = min_value;
    }
    if (x > max_value) {
        x = max_value;
    }

    return (int) x;
}

static const char * reconstruction_check_mode_name() {
    return g_reconstruction_check_mode == ReconstructionCheckMode::OFF ? "off" : "full";
}

static bool reconstruction_check_full() {
    return g_reconstruction_check_mode == ReconstructionCheckMode::FULL;
}

static void init_runtime_env_once() {
    if (g_runtime_env_inited) {
        return;
    }

    const FpgaRuntimeMode runtime_mode = fpga_stats_get_runtime_mode();
    g_force_full_offload    = env_flag_enabled("FPGA_FORCE_FULL_OFFLOAD", false);
    g_experimental_k_tiling = env_flag_enabled("FPGA_EXPERIMENTAL_K_TILING", false);
    g_small_m_pad32         = env_flag_enabled("FPGA_SMALL_M_PAD32",
                                               runtime_mode == FPGA_RUNTIME_MODE_INCLUSIVE);
    if (runtime_mode == FPGA_RUNTIME_MODE_INCLUSIVE) {
        g_small_m_pad32 = true;
    }
    g_fpga_verbose          = env_flag_enabled("FPGA_VERBOSE", false);

    const char * k_accum = std::getenv("FPGA_K_TILING_ACCUM");
    if (k_accum != nullptr && k_accum[0] != '\0' && !ascii_equal_ignore_case(k_accum, "dequant_float")) {
        fprintf(stderr, "[FPGA][K_TILE] unsupported FPGA_K_TILING_ACCUM=%s, using dequant_float\n", k_accum);
    }

    const char * reconstruction_check = std::getenv("FPGA_RECONSTRUCTION_CHECK");
    if (reconstruction_check != nullptr && reconstruction_check[0] != '\0') {
        if (ascii_equal_ignore_case(reconstruction_check, "off")) {
            g_reconstruction_check_mode = ReconstructionCheckMode::OFF;
        } else if (ascii_equal_ignore_case(reconstruction_check, "full")) {
            g_reconstruction_check_mode = ReconstructionCheckMode::FULL;
        } else {
            fprintf(stderr, "[FPGA][reconstruction] unsupported FPGA_RECONSTRUCTION_CHECK=%s, using full\n",
                    reconstruction_check);
            g_reconstruction_check_mode = ReconstructionCheckMode::FULL;
        }
    }
    if ((runtime_mode == FPGA_RUNTIME_MODE_COMPARE || env_flag_enabled("FPGA_COMPARE", false) ||
         env_flag_enabled("FPGA_PROFILE_COMPARE", false)) &&
        g_reconstruction_check_mode == ReconstructionCheckMode::OFF) {
        fprintf(stderr, "[FPGA][reconstruction] numerical compare requires full check; using full\n");
        g_reconstruction_check_mode = ReconstructionCheckMode::FULL;
    }

    fpga_stats_set_force_full_offload(g_force_full_offload);
    fpga_stats_set_reconstruction_check_mode(reconstruction_check_mode_name());
    g_runtime_env_inited = true;
    if (fpga_stats_audit_verbose()) {
        fprintf(stderr,
                "[FPGA][mode] mode=%s force_full_offload=%d experimental_k_tiling=%d small_m_pad32=%d verbose=%d reconstruction_check=%s\n",
                fpga_stats_runtime_mode_name(runtime_mode), g_force_full_offload ? 1 : 0,
                g_experimental_k_tiling ? 1 : 0, g_small_m_pad32 ? 1 : 0, g_fpga_verbose ? 1 : 0,
                reconstruction_check_mode_name());
    }
    if (g_experimental_k_tiling && fpga_stats_audit_verbose()) {
        fprintf(stderr,
                "[FPGA][K_TILE] accumulation=dequant_float approximate=1 reason=rtl_returns_int8_partials\n");
    }
}

static const char * shift_mode_name() {
    if (g_shift_mode == ShiftMode::TABLE) {
        return "table";
    }
    if (g_shift_mode == ShiftMode::CACHED || g_shift_mode == ShiftMode::FAST || g_shift_mode == ShiftMode::SAMPLED) {
        return "cached";
    }
    if (g_shift_mode == ShiftMode::FIXED) {
        return "fixed";
    }
    return "exact";
}

static void init_shift_mode_once() {
    if (g_shift_mode_inited) {
        return;
    }

    const char * mode = std::getenv("FPGA_SHIFT_MODE");
    if (mode != nullptr && mode[0] != '\0') {
        if (ascii_equal_ignore_case(mode, "cached") || ascii_equal_ignore_case(mode, "sampled") ||
            ascii_equal_ignore_case(mode, "fast")) {
            g_shift_mode = ShiftMode::CACHED;
        } else if (ascii_equal_ignore_case(mode, "fixed")) {
            g_shift_mode = ShiftMode::FIXED;
        } else if (ascii_equal_ignore_case(mode, "exact")) {
            g_shift_mode = ShiftMode::EXACT;
        } else if (ascii_equal_ignore_case(mode, "table")) {
            g_shift_mode = ShiftMode::TABLE;
        } else {
            fprintf(stderr, "[FPGA][shift] unknown mode '%s', using cached\n", mode);
            g_shift_mode = ShiftMode::CACHED;
        }
    } else {
        g_shift_mode = ShiftMode::CACHED;
    }

    const char * table_path = std::getenv("FPGA_SHIFT_TABLE");
    if (table_path != nullptr && table_path[0] != '\0') {
        g_shift_table_path = table_path;
    } else {
        g_shift_table_path = "fpga_shift_table.tsv";
    }

    g_shift_table_append = env_flag_enabled("FPGA_SHIFT_TABLE_APPEND", false);

    const char * miss = std::getenv("FPGA_SHIFT_TABLE_MISS");
    if (miss != nullptr && miss[0] != '\0') {
        if (ascii_equal_ignore_case(miss, "fixed")) {
            g_shift_table_miss_policy = ShiftTableMissPolicy::FIXED;
        } else if (ascii_equal_ignore_case(miss, "cached") || ascii_equal_ignore_case(miss, "sampled") ||
                   ascii_equal_ignore_case(miss, "fast")) {
            g_shift_table_miss_policy = ShiftTableMissPolicy::CACHED;
        } else if (ascii_equal_ignore_case(miss, "exact")) {
            g_shift_table_miss_policy = ShiftTableMissPolicy::EXACT;
        } else {
            g_shift_table_miss_policy = ShiftTableMissPolicy::CPU_FALLBACK;
        }
    } else {
        g_shift_table_miss_policy = ShiftTableMissPolicy::CPU_FALLBACK;
    }

    g_fixed_shift       = env_int_clamped("FPGA_FIXED_SHIFT", 5, 0, 30);
    g_shift_mode_inited = true;
    fprintf(stderr, "[FPGA][shift] mode=%s fixed_shift=%d table=%s append=%d miss=%s\n", shift_mode_name(),
            g_fixed_shift, g_shift_table_path.c_str(), g_shift_table_append ? 1 : 0, shift_table_miss_policy_name());
    if (g_shift_mode == ShiftMode::EXACT) {
        fprintf(stderr, "[FPGA][shift] exact mode is calibration/debug only; use FPGA_SHIFT_MODE=table for deployment.\n");
    }
}

static const char * dma_reset_mode_name() {
    if (g_dma_reset_mode == DmaResetMode::ONCE_CALL) {
        return "once_call";
    }
    if (g_dma_reset_mode == DmaResetMode::ON_ERROR) {
        return "on_error";
    }
    return "each_tile";
}

static void init_dma_reset_mode_once() {
    if (g_dma_reset_mode_inited) {
        return;
    }

    const char * mode = std::getenv("FPGA_DMA_RESET_MODE");
    if (mode != nullptr && mode[0] != '\0') {
        if (ascii_equal_ignore_case(mode, "once_call")) {
            g_dma_reset_mode = DmaResetMode::ONCE_CALL;
        } else if (ascii_equal_ignore_case(mode, "on_error")) {
            g_dma_reset_mode = DmaResetMode::ON_ERROR;
        } else {
            g_dma_reset_mode = DmaResetMode::EACH_TILE;
        }
    } else {
        g_dma_reset_mode = DmaResetMode::EACH_TILE;
    }

    g_dma_reset_mode_inited = true;
    fpga_stats_set_dma_reset_mode(dma_reset_mode_name());
    fprintf(stderr, "[FPGA][dma] reset_mode=%s\n", dma_reset_mode_name());
}

// Default = OFF. Hardware failure must return false to ggml so the real CPU
// path can recompute safely. This avoids silently generating tokens from the
// CPU mock while the log says KV260 hardware.
static bool allow_hw_runtime_mock_fallback() {
    return env_flag_enabled("FPGA_ALLOW_HW_RUNTIME_FALLBACK", false) ||
           env_flag_enabled("FPGA_ALLOW_HW_MOCK_FALLBACK", false);
}

// -----------------------------------------------------------------------------
// Activation quantization.
// Also computes max_abs_x per row for fast shift selection.
// -----------------------------------------------------------------------------
static bool quantize_feature_rows(const float *         B_f32,
                                  int                   M,
                                  int                   K,
                                  std::vector<int8_t> & qx,
                                  std::vector<float> &  scale_x,
                                  std::vector<float> &  max_abs_qx) {
    qx.resize((size_t) M * (size_t) K);
    scale_x.resize((size_t) M);
    max_abs_qx.resize((size_t) M);

    for (int m = 0; m < M; ++m) {
        const float * row = B_f32 + (size_t) m * (size_t) K;

        float max_abs = 0.0f;
        for (int k = 0; k < K; ++k) {
            max_abs = std::max(max_abs, fabsf(row[k]));
        }

        float scale = max_abs / 127.0f;
        if (!(scale > 1e-12f) || !std::isfinite(scale)) {
            scale = 1.0f;
        }

        scale_x[(size_t) m] = scale;

        float max_abs_q = 0.0f;

        for (int k = 0; k < K; ++k) {
            const int    q                           = round_to_int(row[k] / scale);
            const int8_t q8                          = clamp_i8_symmetric(q);
            qx[(size_t) m * (size_t) K + (size_t) k] = q8;
            max_abs_q                                = std::max(max_abs_q, (float) std::abs((int) q8));
        }

        max_abs_qx[(size_t) m] = max_abs_q;
    }

    return true;
}

// -----------------------------------------------------------------------------
// Weight prepack.
// -----------------------------------------------------------------------------
struct SafeTileShape {
    int M_hw   = HW_M_MIN;
    int K_tile = 0;
    int N_tile = 0;
    int FWBN   = 0;
    int WWBN   = 0;
};

static int fpga_m_hw_for_runtime(int M) {
    if (M <= HW_M_MIN) {
        return HW_M_MIN;
    }
    return M;
}

static bool tile_shape_fits_rtl(int M_hw, int K_tile, int N_pad) {
    if (K_tile <= 0 || N_pad <= 0 || (K_tile % 32) != 0 || (N_pad % 32) != 0) {
        return false;
    }

    const int fwbn = K_tile / 32;
    const int wwbn = N_pad / 32;
    if (fwbn < 1 || fwbn > 31 || wwbn < 1 || wwbn > 31) {
        return false;
    }

    if (M_hw < 1 || M_hw > 511) {
        return false;
    }

    if (M_hw * fwbn > HW_BUFFER_LIMIT) {
        return false;
    }

    if (wwbn * fwbn * 32 > HW_BUFFER_LIMIT) {
        return false;
    }

    return true;
}

static bool choose_safe_tile_shape(int M, int K_remaining, int N_remaining, SafeTileShape & out) {
    const int M_hw = fpga_m_hw_for_runtime(M);
    const int n_targets[2] = { HW_N_TILE, HW_N_TILE_MIN };

    for (int n_target : n_targets) {
        int cur_N = std::min(n_target, N_remaining);
        if (cur_N <= 0) {
            continue;
        }

        const int N_pad = ((cur_N + 31) / 32) * 32;
        int       K_try = std::min(HW_K_TILE_MAX, K_remaining);
        if (K_remaining == HW_K_TILE_ALT) {
            K_try = HW_K_TILE_ALT;
        }
        K_try           = (K_try / 32) * 32;

        while (K_try > 0) {
            if (tile_shape_fits_rtl(M_hw, K_try, N_pad)) {
                out.M_hw   = M_hw;
                out.K_tile = K_try;
                out.N_tile = cur_N;
                out.FWBN   = K_try / 32;
                out.WWBN   = N_pad / 32;
                return true;
            }
            K_try -= 32;
        }
    }

    return false;
}

static bool pack_one_weight_tile(const void *  A_raw,
                                 FpgaQuantType quant,
                                 int           K_total,
                                 int           N_total,
                                 int           n0,
                                 int           cur_N,
                                 int           N_pad,
                                 int           k0,
                                 int           K_tile,
                                 PackedTile &  tile) {
    const size_t row_bytes = fpga_row_size_bytes(quant, K_total);
    if (row_bytes == 0 || K_tile <= 0 || (K_tile % 32) != 0 || k0 < 0 || k0 + K_tile > K_total) {
        return false;
    }

    tile.n0     = n0;
    tile.cur_N  = cur_N;
    tile.N_pad  = N_pad;
    tile.k0     = k0;
    tile.K_tile = K_tile;
    tile.qw.assign((size_t) K_tile * (size_t) N_pad, 0);
    tile.scale_w.assign((size_t) cur_N, 1.0f);
    tile.sum_abs_w.assign((size_t) cur_N, 0.0f);
    tile.max_sum_abs_w = 0.0f;
    tile.cached_shift  = -1;

    // Dequant source rows in software, then requantize to the INT8 tile layout.
    std::vector<float> w_row((size_t) K_total);

    for (int n = 0; n < cur_N; ++n) {
        const int global_n = n0 + n;
        if (global_n >= N_total) {
            break;
        }

        const uint8_t * row_base = (const uint8_t *) A_raw + (size_t) global_n * row_bytes;
        if (!fpga_dequant_row_to_f32(row_base, quant, w_row.data(), K_total)) {
            return false;
        }

        float max_abs = 0.0f;
        for (int kk = 0; kk < K_tile; ++kk) {
            max_abs = std::max(max_abs, fabsf(w_row[(size_t) k0 + (size_t) kk]));
        }

        float scale = max_abs / 127.0f;
        if (!(scale > 1e-12f) || !std::isfinite(scale)) {
            scale = 1.0f;
        }

        tile.scale_w[(size_t) n] = scale;

        float sum_abs = 0.0f;

        for (int kk = 0; kk < K_tile; ++kk) {
            const int    q                                     = round_to_int(w_row[(size_t) k0 + (size_t) kk] / scale);
            const int8_t q8                                    = clamp_i8_symmetric(q);
            tile.qw[(size_t) kk * (size_t) N_pad + (size_t) n] = q8;
            sum_abs += (float) std::abs((int) q8);
        }

        tile.sum_abs_w[(size_t) n] = sum_abs;
        tile.max_sum_abs_w         = std::max(tile.max_sum_abs_w, sum_abs);
    }

    return true;
}

static std::unique_ptr<PackedRecord> pack_record_from_ggml(const void *  A_raw,
                                                           FpgaQuantType quant,
                                                           int           K,
                                                           int           N,
                                                           uint64_t      fp) {
    init_runtime_env_once();

    if (K <= 0 || (K % 32) != 0 || N <= 0 || N > HW_N_MAX) {
        return nullptr;
    }

    if (K != HW_K_SUPPORTED && !g_experimental_k_tiling) {
        return nullptr;
    }

    std::unique_ptr<PackedRecord> rec(new PackedRecord());
    rec->fingerprint = fp;
    rec->quant       = quant;
    rec->K           = K;
    rec->N           = N;

    int k0 = 0;
    while (k0 < K) {
        int n0 = 0;
        while (n0 < N) {
            SafeTileShape shape;
            if (!choose_safe_tile_shape(HW_M_TILE, K - k0, N - n0, shape)) {
                return nullptr;
            }

            const int cur_N = shape.N_tile;
            const int N_pad = ((cur_N + 31) / 32) * 32;

            PackedTile tile;
            if (!pack_one_weight_tile(A_raw, quant, K, N, n0, cur_N, N_pad, k0, shape.K_tile, tile)) {
                return nullptr;
            }

            rec->tiles.push_back(std::move(tile));
            n0 += cur_N;
        }

        SafeTileShape k_shape;
        if (!choose_safe_tile_shape(HW_M_TILE, K - k0, N, k_shape)) {
            return nullptr;
        }
        k0 += k_shape.K_tile;
    }

    return rec;
}

static uint64_t record_payload_bytes(const PackedRecord & rec) {
    uint64_t bytes = 0;

    for (const PackedTile & t : rec.tiles) {
        bytes += sizeof(DumpTileHeader);
        bytes += (uint64_t) t.qw.size() * sizeof(int8_t);
        bytes += (uint64_t) t.scale_w.size() * sizeof(float);
        bytes += (uint64_t) t.sum_abs_w.size() * sizeof(float);
    }

    return bytes;
}

static bool append_record_to_dump_file(const PackedRecord & rec) {
    const std::string path = dump_file_path();

    std::ofstream os(path.c_str(), std::ios::binary | std::ios::app);
    if (!os.good()) {
        return false;
    }

    DumpRecordHeader hdr = {};
    hdr.magic            = DUMP_REC_MAGIC;
    hdr.version          = DUMP_REC_VER;
    hdr.fingerprint      = rec.fingerprint;
    hdr.quant            = (uint32_t) rec.quant;
    hdr.K                = (uint32_t) rec.K;
    hdr.N                = (uint32_t) rec.N;
    hdr.tile_count       = (uint32_t) rec.tiles.size();
    hdr.record_bytes     = sizeof(DumpRecordHeader) + record_payload_bytes(rec);

    os.write((const char *) &hdr, sizeof(hdr));

    for (const PackedTile & t : rec.tiles) {
        DumpTileHeader th = {};
        th.n0             = (uint32_t) t.n0;
        th.cur_N          = (uint32_t) t.cur_N;
        th.N_pad          = (uint32_t) t.N_pad;
        th.k0             = (uint32_t) t.k0;
        th.K_tile         = (uint32_t) t.K_tile;
        th.weight_bytes   = (uint64_t) t.qw.size() * sizeof(int8_t);
        th.scale_count    = (uint64_t) t.scale_w.size();
        th.sum_abs_count  = (uint64_t) t.sum_abs_w.size();
        th.max_sum_abs_w  = t.max_sum_abs_w;

        os.write((const char *) &th, sizeof(th));

        if (!t.qw.empty()) {
            os.write((const char *) t.qw.data(), (std::streamsize) th.weight_bytes);
        }
        if (!t.scale_w.empty()) {
            os.write((const char *) t.scale_w.data(), (std::streamsize) (th.scale_count * sizeof(float)));
        }
        if (!t.sum_abs_w.empty()) {
            os.write((const char *) t.sum_abs_w.data(), (std::streamsize) (th.sum_abs_count * sizeof(float)));
        }
    }

    return os.good();
}

static bool fpga_quant_supported(FpgaQuantType quant);

#if !defined(_WIN32)
static void clear_tile_ddr_residency(PackedTile & t) {
    t.hw_phys     = 0;
    t.hw_bytes    = 0;
    t.hw_resident = false;
}

static void clear_record_ddr_residency(PackedRecord & rec) {
    for (PackedTile & t : rec.tiles) {
        clear_tile_ddr_residency(t);
    }
}

static void clear_b_cache_metadata(PackedRecord * current_rec) {
    g_weight_bank_offset = 0;

    for (std::unique_ptr<PackedRecord> & rec : g_records) {
        if (rec) {
            clear_record_ddr_residency(*rec);
        }
    }

    if (current_rec != nullptr) {
        clear_record_ddr_residency(*current_rec);
    }

    fpga_stats_count_b_cache_clear();
    fpga_stats_update_b_cache_used_bytes(0);
}

static bool b_tile_too_large(const PackedTile & t, size_t bytes) {
    fpga_stats_count_b_tile_too_large_fallback();
    fpga_stats_set_last_runtime_fallback_reason(FPGA_FB_B_TILE_TOO_LARGE);

    static uint64_t s_too_large_log_count = 0;
    if (s_too_large_log_count < 16) {
        fprintf(stderr,
                "[FPGA][B_CACHE] tile too large n0=%d cur_N=%d k0=%d K_tile=%d tile_bytes=%zu limit=%zu\n",
                t.n0, t.cur_N, t.k0, t.K_tile, bytes, g_hw.b_size);
        s_too_large_log_count++;
    }

    return false;
}

static bool place_tile_in_ddr(PackedRecord * owner, PackedTile & t, uint64_t & phys, size_t & bytes) {
    phys  = 0;
    bytes = t.qw.size() * sizeof(int8_t);

    if (!g_hw.ready) {
        fprintf(stderr, "[FPGA][B_CACHE] FAIL: g_hw.ready=false\n");
        fpga_stats_set_last_runtime_fallback_reason(FPGA_FB_NOT_READY);
        return false;
    }

    if (g_hw.weight_v == nullptr) {
        fprintf(stderr, "[FPGA][B_CACHE] FAIL: weight_v == nullptr\n");
        fpga_stats_set_last_runtime_fallback_reason(FPGA_FB_CACHE_PLACEMENT_FAILED);
        return false;
    }

    if (bytes == 0) {
        fprintf(stderr, "[FPGA][B_CACHE] FAIL: tile bytes = 0 n0=%d cur_N=%d k0=%d K_tile=%d\n", t.n0, t.cur_N, t.k0,
                t.K_tile);
        fpga_stats_set_last_runtime_fallback_reason(FPGA_FB_CACHE_PLACEMENT_FAILED);
        return false;
    }

    fpga_stats_set_b_buffer_limit_bytes((uint64_t) g_hw.b_size);

    if (bytes > g_hw.b_size) {
        return b_tile_too_large(t, bytes);
    }

    if (b_cache_is_scratch()) {
        std::memcpy(g_hw.weight_v, t.qw.data(), bytes);
        phys = g_hw.b_phys;

        fpga_stats_count_b_scratch_copy();
        fpga_stats_add_weight_ddr_bytes(bytes);
        fpga_stats_update_b_cache_used_bytes((uint64_t) bytes);
        fpga_stats_set_last_runtime_fallback_reason(FPGA_FB_B_CACHE_DISABLED_SCRATCH);

        static uint64_t s_scratch_log_count = 0;
        if (s_scratch_log_count < 64) {
            fprintf(stderr,
                    "[FPGA][B_CACHE] scratch copy n0=%d cur_N=%d N_pad=%d k0=%d K_tile=%d phys=0x%llx bytes=%zu "
                    "limit=%zu\n",
                    t.n0, t.cur_N, t.N_pad, t.k0, t.K_tile, (unsigned long long) phys, bytes, g_hw.b_size);
            s_scratch_log_count++;
        }

        return true;
    }

    if (t.hw_resident && t.hw_phys != 0 && t.hw_bytes == bytes) {
        phys = t.hw_phys;
        return true;
    }

    size_t aligned = align_up_size(g_weight_bank_offset, 4096);
    if (aligned + bytes > g_hw.b_size) {
        fpga_stats_count_b_cache_full();

        static uint64_t s_full_log_count = 0;
        if (s_full_log_count < 64) {
            fprintf(stderr,
                    "[FPGA][B_CACHE] full, clear and retry used=%zu aligned=%zu tile_bytes=%zu total=%zu limit=%zu "
                    "n0=%d cur_N=%d k0=%d K_tile=%d\n",
                    g_weight_bank_offset, aligned, bytes, aligned + bytes, g_hw.b_size, t.n0, t.cur_N, t.k0, t.K_tile);
            s_full_log_count++;
        }

        clear_b_cache_metadata(owner);
        fpga_stats_set_last_runtime_fallback_reason(FPGA_FB_B_CACHE_FULL_RECOVERED);
        aligned = 0;

        if (aligned + bytes > g_hw.b_size) {
            return b_tile_too_large(t, bytes);
        }
    }

    std::memcpy(g_hw.weight_v + aligned, t.qw.data(), bytes);

    t.hw_phys     = g_hw.b_phys + aligned;
    t.hw_bytes    = bytes;
    t.hw_resident = true;

    g_weight_bank_offset = aligned + bytes;
    phys                 = t.hw_phys;

    fpga_stats_add_weight_ddr_bytes(bytes);
    fpga_stats_update_b_cache_used_bytes((uint64_t) g_weight_bank_offset);

    static uint64_t s_place_log_count = 0;
    if (s_place_log_count < 64) {
        fprintf(stderr,
                "[FPGA][B_CACHE] place persistent n0=%d cur_N=%d N_pad=%d k0=%d K_tile=%d phys=0x%llx "
                "tile_bytes=%zu used=%zu limit=%zu\n",
                t.n0, t.cur_N, t.N_pad, t.k0, t.K_tile, (unsigned long long) t.hw_phys, t.hw_bytes,
                g_weight_bank_offset, g_hw.b_size);
        s_place_log_count++;
    }

    return true;
}

#endif

static bool load_dump_file_once_locked() {
    if (g_dump_loaded) {
        return true;
    }

    g_dump_loaded = true;

    const std::string path = dump_file_path();
    std::ifstream     is(path.c_str(), std::ios::binary);
    if (!is.good()) {
        return true;
    }

    while (true) {
        DumpRecordHeader hdr = {};
        is.read((char *) &hdr, sizeof(hdr));
        if (!is.good()) {
            break;
        }

        if (hdr.magic != DUMP_REC_MAGIC || hdr.version != DUMP_REC_VER || hdr.tile_count == 0 ||
            hdr.K == 0 || (hdr.K % 32) != 0 || hdr.N == 0 || hdr.N > HW_N_MAX ||
            !fpga_quant_supported((FpgaQuantType) hdr.quant)) {
            break;
        }

        std::unique_ptr<PackedRecord> rec(new PackedRecord());
        rec->fingerprint = hdr.fingerprint;
        rec->quant       = (FpgaQuantType) hdr.quant;
        rec->K           = (int) hdr.K;
        rec->N           = (int) hdr.N;

        bool     ok           = true;
        uint64_t packed_bytes = 0;

        for (uint32_t ti = 0; ti < hdr.tile_count; ++ti) {
            DumpTileHeader th = {};
            is.read((char *) &th, sizeof(th));
            if (!is.good()) {
                ok = false;
                break;
            }

            PackedTile t;
            t.n0            = (int) th.n0;
            t.cur_N         = (int) th.cur_N;
            t.N_pad         = (int) th.N_pad;
            t.k0            = (int) th.k0;
            t.K_tile        = (int) th.K_tile;
            t.max_sum_abs_w = th.max_sum_abs_w;

            if (t.cur_N <= 0 || t.N_pad <= 0 || (t.N_pad % 32) != 0 || t.n0 < 0 || t.n0 + t.cur_N > rec->N ||
                t.k0 < 0 || t.K_tile <= 0 || (t.K_tile % 32) != 0 || t.k0 + t.K_tile > rec->K ||
                th.weight_bytes != (uint64_t) t.K_tile * (uint64_t) t.N_pad ||
                th.scale_count != (uint64_t) t.cur_N || th.sum_abs_count != (uint64_t) t.cur_N) {
                ok = false;
                break;
            }

            t.qw.resize((size_t) th.weight_bytes);
            t.scale_w.resize((size_t) th.scale_count);
            t.sum_abs_w.resize((size_t) th.sum_abs_count);

            if (th.weight_bytes > 0) {
                is.read((char *) t.qw.data(), (std::streamsize) th.weight_bytes);
            }
            if (th.scale_count > 0) {
                is.read((char *) t.scale_w.data(), (std::streamsize) (th.scale_count * sizeof(float)));
            }
            if (th.sum_abs_count > 0) {
                is.read((char *) t.sum_abs_w.data(), (std::streamsize) (th.sum_abs_count * sizeof(float)));
            }

            if (!is.good()) {
                ok = false;
                break;
            }

            packed_bytes += th.weight_bytes;
            rec->tiles.push_back(std::move(t));
        }

        if (!ok) {
            break;
        }

        fpga_stats_add_weight_file_bytes(packed_bytes);
        g_records.push_back(std::move(rec));
    }

    return true;
}

static PackedRecord * find_record_locked(uint64_t fp, FpgaQuantType quant, int K, int N) {
    for (std::unique_ptr<PackedRecord> & r : g_records) {
        if (r->fingerprint == fp && r->quant == quant && r->K == K && r->N == N) {
            return r.get();
        }
    }
    return nullptr;
}

static PackedRecord * get_or_prepare_weight(const void * A_raw, FpgaQuantType quant, int K, int N) {
    std::lock_guard<std::mutex> lock(g_weight_mutex);

    const bool use_runtime_cache = !b_cache_is_scratch();

    if (use_runtime_cache) {
        for (const PreparedWeight & w : g_prepared_cache) {
            if (w.A_raw == A_raw && w.quant == quant && w.K == K && w.N == N && w.record != nullptr) {
                fpga_stats_count_weight_cache_hit();
                return w.record;
            }
        }
    }

    fpga_stats_count_weight_cache_miss();

    load_dump_file_once_locked();

    const uint64_t fp = weight_fingerprint(A_raw, quant, K, N);
    if (fp == 0) {
        return nullptr;
    }

    PackedRecord * rec = find_record_locked(fp, quant, K, N);

    if (rec != nullptr) {
        fpga_stats_count_weight_file_hit();
    } else {
        fpga_stats_count_weight_file_miss();

        std::unique_ptr<PackedRecord> new_rec = pack_record_from_ggml(A_raw, quant, K, N, fp);
        if (!new_rec) {
            return nullptr;
        }

        append_record_to_dump_file(*new_rec);

        g_records.push_back(std::move(new_rec));
        rec = g_records.back().get();
    }

    if (use_runtime_cache) {
        PreparedWeight pw = {};
        pw.A_raw          = A_raw;
        pw.fingerprint    = fp;
        pw.quant          = quant;
        pw.K              = K;
        pw.N              = N;
        pw.record         = rec;
        g_prepared_cache.push_back(pw);
    }

    return rec;
}

// Fast shift selection using precomputed weight metadata.
// Bound:
//   |acc| <= max_abs_qx[row] * sum_k |qw[k,n]|
// We choose one shift per tile, same as the value written to CTRL_SHIFT.
// This is much faster than scanning all M*K*N products every GEMM.
static int choose_shift_fast(const std::vector<float> & max_abs_qx, const PackedTile & tile) {
    float max_bound = 0.0f;

    for (float ax : max_abs_qx) {
        max_bound = std::max(max_bound, ax * tile.max_sum_abs_w);
    }

    int shift = 0;
    while (max_bound > 120.0f && shift < 30) {
        max_bound *= 0.5f;
        shift++;
    }

    return shift;
}

// Exact shift selection.
// This is slower than choose_shift_fast(), but it protects token quality.
// The metadata-only bound can overestimate accumulator magnitude and choose a
// shift that is too large, causing heavy precision loss and garbage tokens.
static int choose_shift_exact(const std::vector<int8_t> & qx, const PackedTile & tile, int M, int K_total) {
    if (tile.qw.empty()) {
        std::vector<float> max_abs_qx_fallback((size_t) M, 127.0f);
        return choose_shift_fast(max_abs_qx_fallback, tile);
    }

    int64_t max_abs = 0;

    for (int m = 0; m < M; ++m) {
        for (int n = 0; n < tile.cur_N; ++n) {
            int64_t acc = 0;

            for (int kk = 0; kk < tile.K_tile; ++kk) {
                const int a = (int) qx[(size_t) m * (size_t) K_total + (size_t) tile.k0 + (size_t) kk];
                const int b = (int) tile.qw[(size_t) kk * (size_t) tile.N_pad + (size_t) n];
                acc += (int64_t) a * (int64_t) b;
            }

            const int64_t aa = acc >= 0 ? acc : -acc;
            if (aa > max_abs) {
                max_abs = aa;
            }
        }
    }

    int shift = 0;
    while (max_abs > 120 && shift < 30) {
        max_abs >>= 1;
        shift++;
    }

    return shift;
}

static int choose_shift_sampled(const std::vector<int8_t> & qx, const PackedTile & tile, int M, int K_total) {
    if (tile.qw.empty()) {
        std::vector<float> max_abs_qx_fallback((size_t) M, 127.0f);
        return choose_shift_fast(max_abs_qx_fallback, tile);
    }

    const int m_samples = std::min(M, 4);
    const int n_samples = std::min(tile.cur_N, 8);

    int64_t max_abs = 0;

    for (int mi = 0; mi < m_samples; ++mi) {
        const int m = m_samples == 1 ? 0 : (mi * (M - 1)) / (m_samples - 1);
        for (int ni = 0; ni < n_samples; ++ni) {
            const int n = n_samples == 1 ? 0 : (ni * (tile.cur_N - 1)) / (n_samples - 1);

            int64_t acc = 0;
            for (int kk = 0; kk < tile.K_tile; ++kk) {
                const int a = (int) qx[(size_t) m * (size_t) K_total + (size_t) tile.k0 + (size_t) kk];
                const int b = (int) tile.qw[(size_t) kk * (size_t) tile.N_pad + (size_t) n];
                acc += (int64_t) a * (int64_t) b;
            }

            const int64_t aa = acc >= 0 ? acc : -acc;
            if (aa > max_abs) {
                max_abs = aa;
            }
        }
    }

    int shift = 0;
    while (max_abs > 120 && shift < 30) {
        max_abs >>= 1;
        shift++;
    }

    return shift;
}

static const char * fpga_quant_name(FpgaQuantType quant) {
    const enum ggml_type type = fpga_quant_to_ggml_type(quant);
    if (type == GGML_TYPE_COUNT) {
        return "unknown";
    }
    return ggml_type_name(type);
}

static int parse_layer_id_from_tensor(const std::string & name) {
    const std::string marker = "blk.";
    const size_t      pos    = name.find(marker);
    if (pos == std::string::npos) {
        return -1;
    }

    size_t start = pos + marker.size();
    size_t end   = start;
    while (end < name.size() && name[end] >= '0' && name[end] <= '9') {
        ++end;
    }
    if (end == start) {
        return -1;
    }
    return (int) std::strtol(name.substr(start, end - start).c_str(), nullptr, 10);
}

static std::string op_group_from_tensor(const std::string & name, int M) {
    if (name.find("Q/O projection") != std::string::npos) {
        return "Q/O projection";
    }
    if (name.find("Gate/Up projection") != std::string::npos) {
        return "Gate/Up projection";
    }
    if (name.find("Down projection") != std::string::npos) {
        return "Down projection";
    }
    if (name.find("Decode-like") != std::string::npos) {
        return "Decode-like GEMV";
    }
    if (name.find("attn_q") != std::string::npos) {
        return "Q projection";
    }
    if (name.find("attn_k") != std::string::npos) {
        return "K projection";
    }
    if (name.find("attn_v") != std::string::npos) {
        return "V projection";
    }
    if (name.find("attn_output") != std::string::npos || name.find("attn_o") != std::string::npos) {
        return "O projection";
    }
    if (name.find("ffn_gate") != std::string::npos || name.find("ffn_up") != std::string::npos) {
        return "Gate/Up projection";
    }
    if (name.find("ffn_down") != std::string::npos) {
        return "Down projection";
    }
    if (name.find("output.weight") != std::string::npos || name == "output") {
        return "Output projection";
    }
    return M < 32 ? "Decode-like GEMV" : "Prefill-like GEMM";
}

static std::string m_bucket_for_shift_table(int M) {
    if (M <= 1) {
        return "M1";
    }
    if (M <= 4) {
        return "M2_4";
    }
    if (M <= 15) {
        return "M5_15";
    }
    if (M <= 31) {
        return "M16_31";
    }
    return "M32_PLUS";
}

static ShiftTableKey make_shift_table_key(FpgaQuantType quant, int M, int K, int N, const PackedTile & tile) {
    ShiftTableKey key;
    key.tensor_name = g_tensor_context;
    key.layer_id    = parse_layer_id_from_tensor(key.tensor_name);
    key.op_group    = op_group_from_tensor(key.tensor_name, M);
    key.qtype       = fpga_quant_name(quant);
    key.m_bucket    = m_bucket_for_shift_table(M);
    key.K           = K;
    key.N           = N;
    key.k0          = tile.k0;
    key.K_tile      = tile.K_tile;
    key.n0          = tile.n0;
    key.N_tile      = tile.cur_N;
    return key;
}

static bool same_shift_key_exact(const ShiftTableKey & a, const ShiftTableKey & b) {
    return a.tensor_name == b.tensor_name && a.layer_id == b.layer_id && a.op_group == b.op_group &&
           a.qtype == b.qtype && a.m_bucket == b.m_bucket && a.K == b.K && a.N == b.N && a.k0 == b.k0 &&
           a.K_tile == b.K_tile && a.n0 == b.n0 && a.N_tile == b.N_tile;
}

static bool same_shift_key_without_tensor(const ShiftTableKey & a, const ShiftTableKey & b) {
    return a.op_group == b.op_group && a.qtype == b.qtype && a.m_bucket == b.m_bucket && a.K == b.K &&
           a.N == b.N && a.k0 == b.k0 && a.K_tile == b.K_tile && a.n0 == b.n0 && a.N_tile == b.N_tile;
}

static void append_shift_table_lookup_field(std::string & out, const std::string & value) {
    out.append(value);
    out.push_back('\x1f');
}

static void append_shift_table_lookup_field(std::string & out, int value) {
    out.append(std::to_string(value));
    out.push_back('\x1f');
}

static std::string make_shift_table_exact_lookup_key(const ShiftTableKey & key) {
    std::string out;
    out.reserve(key.tensor_name.size() + key.op_group.size() + key.qtype.size() + key.m_bucket.size() + 96);
    append_shift_table_lookup_field(out, key.tensor_name);
    append_shift_table_lookup_field(out, key.layer_id);
    append_shift_table_lookup_field(out, key.op_group);
    append_shift_table_lookup_field(out, key.qtype);
    append_shift_table_lookup_field(out, key.m_bucket);
    append_shift_table_lookup_field(out, key.K);
    append_shift_table_lookup_field(out, key.N);
    append_shift_table_lookup_field(out, key.k0);
    append_shift_table_lookup_field(out, key.K_tile);
    append_shift_table_lookup_field(out, key.n0);
    append_shift_table_lookup_field(out, key.N_tile);
    return out;
}

static std::string make_shift_table_fallback_lookup_key(const ShiftTableKey & key) {
    std::string out;
    out.reserve(key.op_group.size() + key.qtype.size() + key.m_bucket.size() + 80);
    append_shift_table_lookup_field(out, key.op_group);
    append_shift_table_lookup_field(out, key.qtype);
    append_shift_table_lookup_field(out, key.m_bucket);
    append_shift_table_lookup_field(out, key.K);
    append_shift_table_lookup_field(out, key.N);
    append_shift_table_lookup_field(out, key.k0);
    append_shift_table_lookup_field(out, key.K_tile);
    append_shift_table_lookup_field(out, key.n0);
    append_shift_table_lookup_field(out, key.N_tile);
    return out;
}

static void index_shift_table_row(size_t row_index) {
    if (row_index >= g_shift_table_rows.size()) {
        return;
    }

    const ShiftTableRow & row = g_shift_table_rows[row_index];
    const std::string     exact_key = make_shift_table_exact_lookup_key(row.key);
    const std::string     fallback_key = make_shift_table_fallback_lookup_key(row.key);

    // The old vector lookup returned the first matching row, so do not overwrite duplicate indexes.
    g_shift_table_exact_index.emplace(exact_key, row_index);
    g_shift_table_fallback_index.emplace(fallback_key, row_index);
    if (row.key.tensor_name.empty()) {
        g_shift_table_fallback_empty_tensor_index.emplace(fallback_key, row_index);
    }
}

static void rebuild_shift_table_index() {
    g_shift_table_exact_index.clear();
    g_shift_table_fallback_index.clear();
    g_shift_table_fallback_empty_tensor_index.clear();

    g_shift_table_exact_index.reserve(g_shift_table_rows.size());
    g_shift_table_fallback_index.reserve(g_shift_table_rows.size());
    g_shift_table_fallback_empty_tensor_index.reserve(g_shift_table_rows.size());

    for (size_t i = 0; i < g_shift_table_rows.size(); ++i) {
        index_shift_table_row(i);
    }
}

static std::vector<std::string> split_tsv_line(const std::string & line) {
    std::vector<std::string> out;
    std::stringstream ss(line);
    std::string item;
    while (std::getline(ss, item, '\t')) {
        out.push_back(item);
    }
    return out;
}

static void load_shift_table_once() {
    init_shift_mode_once();
    if (g_shift_table_loaded) {
        return;
    }
    g_shift_table_loaded = true;
    g_shift_table_rows.clear();
    rebuild_shift_table_index();

    std::ifstream is(g_shift_table_path.c_str());
    if (!is.good()) {
        return;
    }

    std::string line;
    while (std::getline(is, line)) {
        if (line.empty() || line.find("tensor_name\t") == 0) {
            continue;
        }

        std::vector<std::string> cols = split_tsv_line(line);
        if (cols.size() < 16) {
            continue;
        }

        ShiftTableRow row;
        row.key.tensor_name = cols[0];
        row.key.layer_id    = std::atoi(cols[1].c_str());
        row.key.op_group    = cols[2];
        row.key.qtype       = cols[3];
        row.key.m_bucket    = cols[4];
        row.key.K           = std::atoi(cols[5].c_str());
        row.key.N           = std::atoi(cols[6].c_str());
        row.key.k0          = std::atoi(cols[7].c_str());
        row.key.K_tile      = std::atoi(cols[8].c_str());
        row.key.n0          = std::atoi(cols[9].c_str());
        row.key.N_tile      = std::atoi(cols[10].c_str());
        row.shift           = std::atoi(cols[11].c_str());
        if (row.shift < 0) {
            row.shift = 0;
        }
        if (row.shift > 30) {
            row.shift = 30;
        }
        row.calib_mae       = cols[12];
        row.calib_max_abs_error = cols[13];
        row.calib_match_rate = cols[14];
        row.num_samples     = (uint64_t) std::strtoull(cols[15].c_str(), nullptr, 10);
        g_shift_table_rows.push_back(row);
    }

    rebuild_shift_table_index();

    fprintf(stderr, "[FPGA][shift_table] loaded path=%s rows=%zu exact_index=%zu fallback_index=%zu\n",
            g_shift_table_path.c_str(), g_shift_table_rows.size(), g_shift_table_exact_index.size(),
            g_shift_table_fallback_index.size());
}

static void write_shift_table() {
    std::ofstream os(g_shift_table_path.c_str(), std::ios::trunc);
    if (!os.good()) {
        fprintf(stderr, "[FPGA][shift_table] failed to write path=%s\n", g_shift_table_path.c_str());
        return;
    }

    os << "tensor_name\tlayer_id\top_group\tqtype\tM_bucket\tK\tN\tk0\tK_tile\tn0\tN_tile\tshift\t"
          "calib_mae\tcalib_max_abs_error\tcalib_match_rate\tnum_samples\n";
    for (const ShiftTableRow & row : g_shift_table_rows) {
        os << row.key.tensor_name << '\t'
           << row.key.layer_id << '\t'
           << row.key.op_group << '\t'
           << row.key.qtype << '\t'
           << row.key.m_bucket << '\t'
           << row.key.K << '\t'
           << row.key.N << '\t'
           << row.key.k0 << '\t'
           << row.key.K_tile << '\t'
           << row.key.n0 << '\t'
           << row.key.N_tile << '\t'
           << row.shift << '\t'
           << row.calib_mae << '\t'
           << row.calib_max_abs_error << '\t'
           << row.calib_match_rate << '\t'
           << row.num_samples << '\n';
    }
}

static void append_or_update_shift_table(FpgaQuantType quant,
                                         int           M,
                                         int           K,
                                         int           N,
                                         const PackedTile & tile,
                                         int           shift) {
    if (!g_shift_table_append) {
        return;
    }

    load_shift_table_once();

    ShiftTableRow row;
    row.key = make_shift_table_key(quant, M, K, N, tile);
    row.shift = shift;
    row.calib_mae = "NA";
    row.calib_max_abs_error = "NA";
    row.calib_match_rate = "NA";
    row.num_samples = (uint64_t) std::max(0, M) * (uint64_t) std::max(0, tile.cur_N);

    for (size_t i = 0; i < g_shift_table_rows.size(); ++i) {
        ShiftTableRow & existing = g_shift_table_rows[i];
        if (same_shift_key_exact(existing.key, row.key)) {
            existing = row;
            index_shift_table_row(i);
            write_shift_table();
            return;
        }
    }

    g_shift_table_rows.push_back(row);
    index_shift_table_row(g_shift_table_rows.size() - 1);
    write_shift_table();
}

static bool lookup_shift_table(const ShiftTableKey & key, int & shift, ShiftTableLookupKind & kind) {
    load_shift_table_once();

    const std::string exact_key = make_shift_table_exact_lookup_key(key);
    const std::unordered_map<std::string, size_t>::const_iterator exact_it = g_shift_table_exact_index.find(exact_key);
    if (exact_it != g_shift_table_exact_index.end() && exact_it->second < g_shift_table_rows.size()) {
        shift = g_shift_table_rows[exact_it->second].shift;
        kind = ShiftTableLookupKind::EXACT;
        return true;
    }

    const std::string fallback_key = make_shift_table_fallback_lookup_key(key);
    const std::unordered_map<std::string, size_t> & fallback_index =
        key.tensor_name.empty() ? g_shift_table_fallback_index : g_shift_table_fallback_empty_tensor_index;
    const std::unordered_map<std::string, size_t>::const_iterator fallback_it = fallback_index.find(fallback_key);
    if (fallback_it != fallback_index.end() && fallback_it->second < g_shift_table_rows.size()) {
        shift = g_shift_table_rows[fallback_it->second].shift;
        kind = ShiftTableLookupKind::FALLBACK;
        return true;
    }

    kind = ShiftTableLookupKind::MISS;
    return false;
}

static const char * shift_table_miss_policy_name() {
    if (g_shift_table_miss_policy == ShiftTableMissPolicy::FIXED) {
        return "fixed";
    }
    if (g_shift_table_miss_policy == ShiftTableMissPolicy::CACHED) {
        return "cached";
    }
    if (g_shift_table_miss_policy == ShiftTableMissPolicy::EXACT) {
        return "exact";
    }
    return "cpu_fallback";
}

static bool choose_shift_for_tile(const std::vector<int8_t> & qx,
                                  const std::vector<float> &  max_abs_qx,
                                  PackedTile &                tile,
                                  int                         M,
                                  int                         K_total,
                                  int                         N_total,
                                  FpgaQuantType               quant,
                                  int &                       shift_out) {
    init_shift_mode_once();

    if (g_shift_mode == ShiftMode::FIXED) {
        fpga_stats_count_shift_fixed();
        shift_out = g_fixed_shift;
        return true;
    }
    if (g_shift_mode == ShiftMode::CACHED || g_shift_mode == ShiftMode::FAST || g_shift_mode == ShiftMode::SAMPLED) {
        fpga_stats_count_shift_cached();
        if (tile.cached_shift < 0) {
            tile.cached_shift = choose_shift_fast(max_abs_qx, tile);
        }
        shift_out = tile.cached_shift;
        return true;
    }
    if (g_shift_mode == ShiftMode::TABLE) {
        fpga_stats_count_shift_table_call();
        const ShiftTableKey key = make_shift_table_key(quant, M, K_total, N_total, tile);

        int shift = 0;
        ShiftTableLookupKind lookup_kind = ShiftTableLookupKind::MISS;
        if (lookup_shift_table(key, shift, lookup_kind)) {
            fpga_stats_count_shift_table_hit();
            static uint64_t s_hit_log_count = 0;
            if (s_hit_log_count < 32) {
                fprintf(stderr, "[FPGA][shift_table] lookup=%s tensor=%s qtype=%s M_bucket=%s K=%d N=%d k0=%d "
                                "K_tile=%d n0=%d N_tile=%d shift=%d\n",
                        lookup_kind == ShiftTableLookupKind::EXACT ? "exact" : "fallback",
                        key.tensor_name.c_str(), key.qtype.c_str(), key.m_bucket.c_str(), key.K, key.N, key.k0,
                        key.K_tile, key.n0, key.N_tile, shift);
                s_hit_log_count++;
            }
            shift_out = shift;
            return true;
        }

        fpga_stats_count_shift_table_miss();
        static uint64_t s_miss_log_count = 0;
        if (s_miss_log_count < 64) {
            fprintf(stderr, "[FPGA][shift_table] lookup=miss policy=%s tensor=%s qtype=%s M_bucket=%s K=%d N=%d "
                            "k0=%d K_tile=%d n0=%d N_tile=%d\n",
                    shift_table_miss_policy_name(), key.tensor_name.c_str(), key.qtype.c_str(), key.m_bucket.c_str(),
                    key.K, key.N, key.k0, key.K_tile, key.n0, key.N_tile);
            s_miss_log_count++;
        }

        if (g_shift_table_miss_policy == ShiftTableMissPolicy::CPU_FALLBACK) {
            fpga_stats_count_shift_table_miss_cpu_fallback();
            fpga_stats_set_last_runtime_fallback_reason(FPGA_FB_SHIFT_TABLE_MISS);
            return false;
        }
        if (g_shift_table_miss_policy == ShiftTableMissPolicy::FIXED) {
            fpga_stats_count_shift_table_miss_fixed();
            fpga_stats_count_shift_fixed();
            shift_out = g_fixed_shift;
            return true;
        }
        if (g_shift_table_miss_policy == ShiftTableMissPolicy::CACHED) {
            fpga_stats_count_shift_table_miss_cached();
            fpga_stats_count_shift_cached();
            if (tile.cached_shift < 0) {
                tile.cached_shift = choose_shift_fast(max_abs_qx, tile);
            }
            shift_out = tile.cached_shift;
            return true;
        }

        fpga_stats_count_shift_table_miss_exact();
        fpga_stats_count_shift_exact();
        shift_out = choose_shift_exact(qx, tile, M, K_total);
        append_or_update_shift_table(quant, M, K_total, N_total, tile, shift_out);
        return true;
    }

    fpga_stats_count_shift_exact();
    shift_out = choose_shift_exact(qx, tile, M, K_total);
    append_or_update_shift_table(quant, M, K_total, N_total, tile, shift_out);
    return true;
}

// True hardware mock. It uses packed INT8 weights, precomputed shift metadata,
// RTL right_shift, and INT8 output behavior.
static bool true_hw_mock_gemm(PackedRecord *              rec,
                              const std::vector<int8_t> & qx,
                              const std::vector<float> &  scale_x,
                              const std::vector<float> &  max_abs_qx,
                              float *                     C,
                              int                         M,
                               int                         K,
                               int                         N) {
    if (rec == nullptr || K <= 0 || (K % 32) != 0) {
        return false;
    }

    std::fill(C, C + (size_t) M * (size_t) N, 0.0f);

    uint64_t sat_count = 0;
    uint64_t sat_total = 0;
    uint64_t k_sat_count = 0;
    uint64_t k_sat_total = 0;
    const bool k_tiling_used = K != HW_K_SUPPORTED;

    for (PackedTile & tile : rec->tiles) {
        if (tile.qw.empty()) {
            return false;
        }

        int shift = 0;
        const auto t_shift0 = std::chrono::high_resolution_clock::now();
        if (!choose_shift_for_tile(qx, max_abs_qx, tile, M, K, N, rec->quant, shift)) {
            return false;
        }
        const auto t_shift1 = std::chrono::high_resolution_clock::now();
        fpga_stats_add_shift_select_time(std::chrono::duration<double, std::milli>(t_shift1 - t_shift0).count());
        const float shift_scale = (float) (1u << shift);

        for (int m = 0; m < M; ++m) {
            for (int n = 0; n < tile.cur_N; ++n) {
                int64_t acc = 0;

                for (int kk = 0; kk < tile.K_tile; ++kk) {
                    const int a = (int) qx[(size_t) m * (size_t) K + (size_t) tile.k0 + (size_t) kk];
                    const int b = (int) tile.qw[(size_t) kk * (size_t) tile.N_pad + (size_t) n];
                    acc += (int64_t) a * (int64_t) b;
                }

                const int8_t qout = rtl_right_shift_round_sat(acc, shift);

                if (qout == 127 || qout == -128 || qout == -127) {
                    sat_count++;
                    if (k_tiling_used) {
                        k_sat_count++;
                    }
                }
                sat_total++;
                if (k_tiling_used) {
                    k_sat_total++;
                }

                C[(size_t) m * (size_t) N + (size_t) (tile.n0 + n)] +=
                    (float) qout * scale_x[(size_t) m] * tile.scale_w[(size_t) n] * shift_scale;
            }
        }
    }

    fpga_stats_count_saturation(sat_count, sat_total);
    if (k_tiling_used) {
        fpga_stats_count_k_tiling_saturation(k_sat_count, k_sat_total);
    }
    return true;
}

// -----------------------------------------------------------------------------
// Linux/KV260 MMIO + DMA path.
// -----------------------------------------------------------------------------
#if !defined(_WIN32)
static void * map_mmio(int fd, uint64_t base, size_t size) {
    void * p = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t) base);
    if (p == MAP_FAILED) {
        return nullptr;
    }
    return p;
}

static inline void wr(volatile uint32_t * base, uint32_t off, uint32_t v) {
    base[off / 4] = v;
}

static inline uint32_t rd(volatile uint32_t * base, uint32_t off) {
    return base[off / 4];
}

static void unmap_mmio_ptr(volatile uint32_t * ptr) {
    munmap(const_cast<uint32_t *>(ptr), FPGA_MAP_SIZE);
}

static bool wait_reset_clear(volatile uint32_t * dma, uint32_t cr_off) {
    // Linux userspace MMIO can be slower than bare-metal. Give AXI DMA
    // enough time to self-clear the reset bit.
    for (int i = 0; i < 1000; ++i) {
        if ((rd(dma, cr_off) & DMA_CR_RESET) == 0) {
            return true;
        }
        usleep(100);
    }
    return false;
}

static bool dma_full_reset_mm2s(volatile uint32_t * dma) {
    // Stop channel, clear sticky IRQ bits, then reset and restart.
    wr(dma, DMA_MM2S_DMACR, 0x00000000u);
    usleep(1000);
    wr(dma, DMA_MM2S_DMASR, DMA_SR_IOC_IRQ | DMA_SR_ERR_ALL);
    usleep(1000);

    wr(dma, DMA_MM2S_DMACR, DMA_CR_RESET);
    if (!wait_reset_clear(dma, DMA_MM2S_DMACR)) {
        return false;
    }

    wr(dma, DMA_MM2S_DMACR, DMA_CR_RS);
    usleep(1000);
    return true;
}

static bool dma_full_reset_s2mm(volatile uint32_t * dma) {
    wr(dma, DMA_S2MM_DMACR, 0x00000000u);
    usleep(1000);
    wr(dma, DMA_S2MM_DMASR, DMA_SR_IOC_IRQ | DMA_SR_ERR_ALL);
    usleep(1000);

    wr(dma, DMA_S2MM_DMACR, DMA_CR_RESET);
    if (!wait_reset_clear(dma, DMA_S2MM_DMACR)) {
        return false;
    }

    wr(dma, DMA_S2MM_DMACR, DMA_CR_RS);
    usleep(1000);
    return true;
}

static void dma_clear_status_mm2s(volatile uint32_t * dma) {
    wr(dma, DMA_MM2S_DMASR, DMA_SR_IOC_IRQ | DMA_SR_ERR_ALL);
}

static void dma_clear_status_s2mm(volatile uint32_t * dma) {
    wr(dma, DMA_S2MM_DMASR, DMA_SR_IOC_IRQ | DMA_SR_ERR_ALL);
}

static void dma_prepare_tile_status_clear_all() {
    fpga_stats_count_dma_status_clear_call();
    dma_clear_status_mm2s(g_hw.dma0);
    dma_clear_status_mm2s(g_hw.dma1);
    dma_clear_status_s2mm(g_hw.dma2);
}

static bool dma_full_reset_all(double * elapsed_ms, const char ** failed_channel) {
    if (failed_channel != nullptr) {
        *failed_channel = nullptr;
    }

    const auto t0 = std::chrono::high_resolution_clock::now();
    fpga_stats_count_dma_full_reset_call();

    if (!dma_full_reset_mm2s(g_hw.dma0)) {
        if (failed_channel != nullptr) {
            *failed_channel = "DMA0";
        }
        fpga_stats_count_dma_reset_failure();
        const auto t1 = std::chrono::high_resolution_clock::now();
        if (elapsed_ms != nullptr) {
            *elapsed_ms += std::chrono::duration<double, std::milli>(t1 - t0).count();
        }
        return false;
    }

    if (!dma_full_reset_mm2s(g_hw.dma1)) {
        if (failed_channel != nullptr) {
            *failed_channel = "DMA1";
        }
        fpga_stats_count_dma_reset_failure();
        const auto t1 = std::chrono::high_resolution_clock::now();
        if (elapsed_ms != nullptr) {
            *elapsed_ms += std::chrono::duration<double, std::milli>(t1 - t0).count();
        }
        return false;
    }

    if (!dma_full_reset_s2mm(g_hw.dma2)) {
        if (failed_channel != nullptr) {
            *failed_channel = "DMA2";
        }
        fpga_stats_count_dma_reset_failure();
        const auto t1 = std::chrono::high_resolution_clock::now();
        if (elapsed_ms != nullptr) {
            *elapsed_ms += std::chrono::duration<double, std::milli>(t1 - t0).count();
        }
        return false;
    }

    const auto t1 = std::chrono::high_resolution_clock::now();
    if (elapsed_ms != nullptr) {
        *elapsed_ms += std::chrono::duration<double, std::milli>(t1 - t0).count();
    }
    return true;
}

static bool dma_start_mm2s(volatile uint32_t * dma, uint64_t phys, uint32_t bytes) {
    wr(dma, DMA_MM2S_DMACR, DMA_CR_RS);
    wr(dma, DMA_MM2S_SA, (uint32_t) (phys & 0xFFFFFFFFu));
    wr(dma, DMA_MM2S_SA_MSB, (uint32_t) ((phys >> 32) & 0xFFFFFFFFu));
    wr(dma, DMA_MM2S_LEN, bytes);
    return true;
}

static bool dma_start_s2mm(volatile uint32_t * dma, uint64_t phys, uint32_t bytes) {
    wr(dma, DMA_S2MM_DMACR, DMA_CR_RS);
    wr(dma, DMA_S2MM_DA, (uint32_t) (phys & 0xFFFFFFFFu));
    wr(dma, DMA_S2MM_DA_MSB, (uint32_t) ((phys >> 32) & 0xFFFFFFFFu));
    wr(dma, DMA_S2MM_LEN, bytes);
    return true;
}

static DmaWaitStatus dma_wait_mm2s_current(volatile uint32_t * dma) {
    for (uint32_t timeout = 200000000u; timeout > 0; --timeout) {
        const uint32_t st = rd(dma, DMA_MM2S_DMASR);
        if (st & DMA_SR_ERR_ALL) {
            return DmaWaitStatus::ERROR;
        }
        if (st & DMA_SR_IOC_IRQ) {
            return DmaWaitStatus::DONE;
        }
    }
    return DmaWaitStatus::TIMEOUT;
}

static DmaWaitStatus dma_wait_s2mm_current(volatile uint32_t * dma) {
    for (uint32_t timeout = 200000000u; timeout > 0; --timeout) {
        const uint32_t st = rd(dma, DMA_S2MM_DMASR);
        if (st & DMA_SR_ERR_ALL) {
            return DmaWaitStatus::ERROR;
        }
        if (st & DMA_SR_IOC_IRQ) {
            return DmaWaitStatus::DONE;
        }
    }
    return DmaWaitStatus::TIMEOUT;
}

static const char * dma_wait_status_name(DmaWaitStatus status) {
    if (status == DmaWaitStatus::ERROR) {
        return "error";
    }
    if (status == DmaWaitStatus::TIMEOUT) {
        return "timeout";
    }
    return "done";
}

static void fpga_stats_count_dma_wait_status(DmaWaitStatus status) {
    if (status == DmaWaitStatus::ERROR) {
        fpga_stats_count_dma_runtime_error();
    } else if (status == DmaWaitStatus::TIMEOUT) {
        fpga_stats_count_dma_runtime_timeout();
    }
}

static void hw_write_ctrl_config(int shift, int M, int k_blocks, int w_blocks) {
    // Defensive double-write. It is harmless for the fixed RTL and protects the
    // older config-change-detect build where the first write after reset could
    // be ignored and produce all-zero output.
    const int alt_shift = (shift == 0) ? 1 : (shift - 1);
    const int alt_M     = (M == 1) ? 2 : (M - 1);
    const int alt_kb    = (k_blocks == 1) ? 2 : (k_blocks - 1);
    const int alt_wb    = (w_blocks == 1) ? 2 : (w_blocks - 1);

    wr(g_hw.ctrl, CTRL_SHIFT, (uint32_t) alt_shift);
    wr(g_hw.ctrl, CTRL_FL, (uint32_t) alt_M);
    wr(g_hw.ctrl, CTRL_FWBN, (uint32_t) alt_kb);
    wr(g_hw.ctrl, CTRL_WWBN, (uint32_t) alt_wb);

    // Read back once to force MMIO ordering on the ARM side.
    (void) rd(g_hw.ctrl, CTRL_WWBN);

    wr(g_hw.ctrl, CTRL_SHIFT, (uint32_t) shift);
    wr(g_hw.ctrl, CTRL_FL, (uint32_t) M);
    wr(g_hw.ctrl, CTRL_FWBN, (uint32_t) k_blocks);
    wr(g_hw.ctrl, CTRL_WWBN, (uint32_t) w_blocks);

    (void) rd(g_hw.ctrl, CTRL_WWBN);
}

static bool fpga_manager_operating() {
    FILE * f = fopen("/sys/class/fpga_manager/fpga0/state", "r");
    if (!f) {
        return false;
    }

    char       buf[128] = { 0 };
    const bool ok       = fgets(buf, sizeof(buf), f) != nullptr;
    fclose(f);

    return ok && strstr(buf, "operating") != nullptr;
}

static size_t round_up_page(size_t x) {
    const size_t p = 4096;
    return (x + p - 1) & ~(p - 1);
}

static bool hw_init() {
    if (g_hw.ready) {
        return true;
    }

    if (!fpga_manager_operating()) {
        fprintf(stderr, "[FPGA][hw_init] fpga_manager is not operating\n");
        return false;
    }

    struct stat st = {};
    if (stat("/dev/gemm_dma_buf", &st) != 0) {
        fprintf(stderr, "[FPGA][hw_init] stat /dev/gemm_dma_buf failed: errno=%d (%s)\n", errno, strerror(errno));
        return false;
    }

    g_hw.fd_mem = open("/dev/mem", O_RDWR | O_SYNC);
    if (g_hw.fd_mem < 0) {
        fprintf(stderr, "[FPGA][hw_init] open /dev/mem failed: errno=%d (%s)\n", errno, strerror(errno));
        return false;
    }

    g_hw.dma0 = (volatile uint32_t *) map_mmio(g_hw.fd_mem, FPGA_DMA0_BASE, FPGA_MAP_SIZE);
    if (!g_hw.dma0) {
        fprintf(stderr, "[FPGA][hw_init] mmap DMA0 failed base=0x%llx errno=%d (%s)\n",
                (unsigned long long) FPGA_DMA0_BASE, errno, strerror(errno));
        return false;
    }

    g_hw.dma1 = (volatile uint32_t *) map_mmio(g_hw.fd_mem, FPGA_DMA1_BASE, FPGA_MAP_SIZE);
    if (!g_hw.dma1) {
        fprintf(stderr, "[FPGA][hw_init] mmap DMA1 failed base=0x%llx errno=%d (%s)\n",
                (unsigned long long) FPGA_DMA1_BASE, errno, strerror(errno));
        return false;
    }

    g_hw.dma2 = (volatile uint32_t *) map_mmio(g_hw.fd_mem, FPGA_DMA2_BASE, FPGA_MAP_SIZE);
    if (!g_hw.dma2) {
        fprintf(stderr, "[FPGA][hw_init] mmap DMA2 failed base=0x%llx errno=%d (%s)\n",
                (unsigned long long) FPGA_DMA2_BASE, errno, strerror(errno));
        return false;
    }

    g_hw.ctrl = (volatile uint32_t *) map_mmio(g_hw.fd_mem, FPGA_CTRL_BASE, FPGA_MAP_SIZE);
    if (!g_hw.ctrl) {
        fprintf(stderr, "[FPGA][hw_init] mmap CTRL failed base=0x%llx errno=%d (%s)\n",
                (unsigned long long) FPGA_CTRL_BASE, errno, strerror(errno));
        return false;
    }

    g_hw.fd_buf = open("/dev/gemm_dma_buf", O_RDWR | O_SYNC);
    if (g_hw.fd_buf < 0) {
        fprintf(stderr, "[FPGA][hw_init] open /dev/gemm_dma_buf failed: errno=%d (%s)\n", errno, strerror(errno));
        return false;
    }

    gemm_dma_buf_info_ex info_ex = {};
    if (ioctl(g_hw.fd_buf, GEMM_DMA_BUF_IOCTL_GET_INFO_EX, &info_ex) == 0) {
        g_hw.a_phys = info_ex.a_phys;
        g_hw.b_phys = info_ex.b_phys;
        g_hw.c_phys = info_ex.c_phys;
        g_hw.a_size = (size_t) info_ex.a_size;
        g_hw.b_size = (size_t) info_ex.b_size;
        g_hw.c_size = (size_t) info_ex.c_size;
        fprintf(stderr, "[FPGA][hw_init] dma_buf EX: A=0x%llx/%zu B=0x%llx/%zu C=0x%llx/%zu\n",
                (unsigned long long) g_hw.a_phys, g_hw.a_size, (unsigned long long) g_hw.b_phys, g_hw.b_size,
                (unsigned long long) g_hw.c_phys, g_hw.c_size);
    } else {
        gemm_dma_buf_info_old info_old = {};
        if (ioctl(g_hw.fd_buf, GEMM_DMA_BUF_IOCTL_GET_INFO, &info_old) != 0) {
            fprintf(stderr, "[FPGA][hw_init] ioctl GET_INFO_EX and old GET_INFO failed: errno=%d (%s)\n", errno,
                    strerror(errno));
            return false;
        }

        g_hw.a_phys = info_old.a_phys;
        g_hw.b_phys = info_old.b_phys;
        g_hw.c_phys = info_old.c_phys;
        g_hw.a_size = (size_t) info_old.size;
        g_hw.b_size = (size_t) info_old.size;
        g_hw.c_size = (size_t) info_old.size;
        fprintf(stderr, "[FPGA][hw_init] dma_buf OLD: A=0x%llx B=0x%llx C=0x%llx size=%zu\n",
                (unsigned long long) g_hw.a_phys, (unsigned long long) g_hw.b_phys, (unsigned long long) g_hw.c_phys,
                g_hw.a_size);
    }

    const size_t feature_size = g_hw.a_size;
    const size_t weight_size  = g_hw.b_size;
    const size_t result_size  = g_hw.c_size;

    fpga_stats_set_b_buffer_limit_bytes((uint64_t) weight_size);

    if (feature_size == 0 || weight_size == 0 || result_size == 0) {
        fprintf(stderr, "[FPGA][hw_init] invalid dma_buf sizes A=%zu B=%zu C=%zu\n", feature_size, weight_size,
                result_size);
        return false;
    }

    // Driver mmap layout:
    //   offset 0*PAGE maps A/feature buffer
    //   offset 1*PAGE maps B/weight  buffer
    //   offset 2*PAGE maps C/result  buffer
    // Each mmap request must be <= GEMM_BUF_SIZE, so do NOT mmap A+B+C as one large region.
    g_hw.feature_map_size = round_up_page(feature_size);
    g_hw.weight_map_size  = round_up_page(weight_size);
    g_hw.result_map_size  = round_up_page(result_size);
    g_hw.buf_map_size     = std::max(g_hw.feature_map_size, std::max(g_hw.weight_map_size, g_hw.result_map_size));

    g_hw.feature_v =
        (uint8_t *) mmap(nullptr, g_hw.feature_map_size, PROT_READ | PROT_WRITE, MAP_SHARED, g_hw.fd_buf, 0);
    if (g_hw.feature_v == MAP_FAILED || g_hw.feature_v == nullptr) {
        fprintf(stderr, "[FPGA][hw_init] mmap feature/A buffer failed size=%zu errno=%d (%s)\n", g_hw.feature_map_size,
                errno, strerror(errno));
        g_hw.feature_v = nullptr;
        return false;
    }

    g_hw.weight_v =
        (uint8_t *) mmap(nullptr, g_hw.weight_map_size, PROT_READ | PROT_WRITE, MAP_SHARED, g_hw.fd_buf, (off_t) 4096);
    if (g_hw.weight_v == MAP_FAILED || g_hw.weight_v == nullptr) {
        fprintf(stderr, "[FPGA][hw_init] mmap weight/B buffer failed size=%zu errno=%d (%s)\n", g_hw.weight_map_size,
                errno, strerror(errno));
        g_hw.weight_v = nullptr;
        return false;
    }

    g_hw.result_v =
        (uint8_t *) mmap(nullptr, g_hw.result_map_size, PROT_READ | PROT_WRITE, MAP_SHARED, g_hw.fd_buf, (off_t) 8192);
    if (g_hw.result_v == MAP_FAILED || g_hw.result_v == nullptr) {
        fprintf(stderr, "[FPGA][hw_init] mmap result/C buffer failed size=%zu errno=%d (%s)\n", g_hw.result_map_size,
                errno, strerror(errno));
        g_hw.result_v = nullptr;
        return false;
    }

    g_hw.buf_base = nullptr;

    g_hw.ready = true;
    g_dma_reset_ready = false;

    fprintf(stderr, "[FPGA][hw_init] OK: dma0=0x%llx dma1=0x%llx dma2=0x%llx ctrl=0x%llx map_size=%zu\n",
            (unsigned long long) FPGA_DMA0_BASE, (unsigned long long) FPGA_DMA1_BASE,
            (unsigned long long) FPGA_DMA2_BASE, (unsigned long long) FPGA_CTRL_BASE, g_hw.buf_map_size);

    return true;
}

static void hw_close() {
    if (g_hw.feature_v) {
        munmap(g_hw.feature_v, g_hw.feature_map_size);
        g_hw.feature_v = nullptr;
    }
    if (g_hw.weight_v) {
        munmap(g_hw.weight_v, g_hw.weight_map_size);
        g_hw.weight_v = nullptr;
    }
    if (g_hw.result_v) {
        munmap(g_hw.result_v, g_hw.result_map_size);
        g_hw.result_v = nullptr;
    }
    g_hw.buf_base = nullptr;

    if (g_hw.dma0) {
        unmap_mmio_ptr(g_hw.dma0);
        g_hw.dma0 = nullptr;
    }
    if (g_hw.dma1) {
        unmap_mmio_ptr(g_hw.dma1);
        g_hw.dma1 = nullptr;
    }
    if (g_hw.dma2) {
        unmap_mmio_ptr(g_hw.dma2);
        g_hw.dma2 = nullptr;
    }
    if (g_hw.ctrl) {
        unmap_mmio_ptr(g_hw.ctrl);
        g_hw.ctrl = nullptr;
    }

    if (g_hw.fd_buf >= 0) {
        close(g_hw.fd_buf);
        g_hw.fd_buf = -1;
    }
    if (g_hw.fd_mem >= 0) {
        close(g_hw.fd_mem);
        g_hw.fd_mem = -1;
    }

    g_hw.ready = false;
    g_dma_reset_ready = false;
}

static bool reconstruct_tile_full_check(const int8_t *              qout,
                                        const PackedTile &          tile,
                                        const std::vector<float> &  scale_x,
                                        float *                     C,
                                        int                         M,
                                        int                         N,
                                        float                       shift_scale,
                                        bool                        k_tiling_used,
                                        uint64_t &                  sat_count,
                                        uint64_t &                  sat_total,
                                        uint64_t &                  k_tiling_sat_count,
                                        uint64_t &                  k_tiling_sat_total) {
    for (int m = 0; m < M; ++m) {
        for (int n = 0; n < tile.cur_N; ++n) {
            const int8_t q = qout[(size_t) m * (size_t) tile.N_pad + (size_t) n];

            if (q == 127 || q == -128 || q == -127) {
                sat_count++;
                if (k_tiling_used) {
                    k_tiling_sat_count++;
                }
            }
            sat_total++;
            if (k_tiling_used) {
                k_tiling_sat_total++;
            }

            const float value = (float) q * scale_x[(size_t) m] * tile.scale_w[(size_t) n] * shift_scale;
            const size_t c_index = (size_t) m * (size_t) N + (size_t) (tile.n0 + n);
            C[c_index] += value;
            if (!std::isfinite(value) || !std::isfinite(C[c_index])) {
                fpga_stats_record_reconstruction_failure();
                fpga_stats_record_job_failed(FPGA_FB_RECONSTRUCTION_FAILURE);
                fpga_stats_set_last_runtime_fallback_reason(FPGA_FB_RECONSTRUCTION_FAILURE);
                return false;
            }
        }
    }

    return true;
}

static void reconstruct_tile_check_off(const int8_t *              qout,
                                       const PackedTile &          tile,
                                       const std::vector<float> &  scale_x,
                                       float *                     C,
                                       int                         M,
                                       int                         N,
                                       float                       shift_scale,
                                       bool                        k_tiling_used,
                                       uint64_t &                  sat_count,
                                       uint64_t &                  sat_total,
                                       uint64_t &                  k_tiling_sat_count,
                                       uint64_t &                  k_tiling_sat_total) {
    for (int m = 0; m < M; ++m) {
        for (int n = 0; n < tile.cur_N; ++n) {
            const int8_t q = qout[(size_t) m * (size_t) tile.N_pad + (size_t) n];

            if (q == 127 || q == -128 || q == -127) {
                sat_count++;
                if (k_tiling_used) {
                    k_tiling_sat_count++;
                }
            }
            sat_total++;
            if (k_tiling_used) {
                k_tiling_sat_total++;
            }

            C[(size_t) m * (size_t) N + (size_t) (tile.n0 + n)] +=
                (float) q *
                scale_x[(size_t) m] *
                tile.scale_w[(size_t) n] *
                shift_scale;
        }
    }
}

static bool hw_gemm(PackedRecord *              rec,
                    const std::vector<int8_t> & qx,
                    const std::vector<float> &  scale_x,
                    const std::vector<float> &  max_abs_qx,
                    float *                     C,
                    int                         M,
                    int                         K,
                    int                         N) {
    // Limit fail logs so llama does not flood UART.
    static int s_hw_fail_log_count = 0;
#    define FPGA_HW_FAIL_LOG(fmt, ...)                                             \
        do {                                                                       \
            if (s_hw_fail_log_count < 64) {                                        \
                fprintf(stderr, "[FPGA][hw_gemm] fail: " fmt "\n", ##__VA_ARGS__); \
                s_hw_fail_log_count++;                                             \
            }                                                                      \
        } while (0)

    if (!g_hw.ready) {
        FPGA_HW_FAIL_LOG("g_hw not ready");
        fpga_stats_set_last_runtime_fallback_reason(FPGA_FB_NOT_READY);
        fpga_stats_record_pre_submit_rejection(FPGA_FB_NOT_READY);
        return false;
    }

    if (rec == nullptr) {
        FPGA_HW_FAIL_LOG("rec nullptr M=%d K=%d N=%d", M, K, N);
        fpga_stats_set_last_runtime_fallback_reason(FPGA_FB_CACHE_PLACEMENT_FAILED);
        fpga_stats_record_pre_submit_rejection(FPGA_FB_CACHE_PLACEMENT_FAILED);
        return false;
    }

    if (K <= 0 || (K % 32) != 0) {
        FPGA_HW_FAIL_LOG("K unsupported K=%d M=%d N=%d", K, M, N);
        fpga_stats_set_last_runtime_fallback_reason(FPGA_FB_SCOPE_POLICY);
        fpga_stats_record_pre_submit_rejection(FPGA_FB_SCOPE_POLICY);
        return false;
    }

    if (N > HW_N_MAX) {
        FPGA_HW_FAIL_LOG("N too large N=%d max=%d M=%d K=%d", N, HW_N_MAX, M, K);
        fpga_stats_set_last_runtime_fallback_reason(FPGA_FB_SCOPE_POLICY);
        fpga_stats_record_pre_submit_rejection(FPGA_FB_SCOPE_POLICY);
        return false;
    }

    if (g_hw.feature_v == nullptr || g_hw.weight_v == nullptr || g_hw.result_v == nullptr) {
        FPGA_HW_FAIL_LOG("null mapped buffer feature=%p weight=%p result=%p", (void *) g_hw.feature_v,
                         (void *) g_hw.weight_v, (void *) g_hw.result_v);
        fpga_stats_set_last_runtime_fallback_reason(FPGA_FB_DMA_RUNTIME_FAILED);
        fpga_stats_record_pre_submit_rejection(FPGA_FB_DMA_RUNTIME_FAILED);
        return false;
    }

    std::fill(C, C + (size_t) M * (size_t) N, 0.0f);

    uint64_t sat_count = 0;
    uint64_t sat_total = 0;
    uint64_t k_tiling_sat_count = 0;
    uint64_t k_tiling_sat_total = 0;
    const bool k_tiling_used = K != HW_K_SUPPORTED;

    double   shift_select_ms   = 0.0;
    double   feature_copy_ms   = 0.0;
    double   result_copy_ms    = 0.0;
    double   ctrl_config_ms    = 0.0;
    double   dma_reset_ms      = 0.0;
    double   dma_start_ms      = 0.0;
    double   dma_wait0_ms      = 0.0;
    double   dma_wait1_ms      = 0.0;
    double   dma_wait2_ms      = 0.0;
    uint64_t detail_tile_count = 0;

    const int M_hw_for_call = fpga_m_hw_for_runtime(M);
    if (M_hw_for_call > M) {
        fpga_stats_count_small_m_pad((uint64_t) M, (uint64_t) M_hw_for_call);
        static uint64_t s_small_m_log_count = 0;
        if (fpga_stats_audit_verbose() && s_small_m_log_count < 32) {
            fprintf(stderr, "[FPGA][SMALL_M] M=%d padded to M_hw=%d\n", M, M_hw_for_call);
            s_small_m_log_count++;
        }
    }

    auto log_dma_reset_failure = [&](const char * channel) {
        if (channel != nullptr && std::strcmp(channel, "DMA0") == 0) {
            FPGA_HW_FAIL_LOG("DMA0 reset failed DMACR=0x%08x DMASR=0x%08x", rd(g_hw.dma0, DMA_MM2S_DMACR),
                             rd(g_hw.dma0, DMA_MM2S_DMASR));
        } else if (channel != nullptr && std::strcmp(channel, "DMA1") == 0) {
            FPGA_HW_FAIL_LOG("DMA1 reset failed DMACR=0x%08x DMASR=0x%08x", rd(g_hw.dma1, DMA_MM2S_DMACR),
                             rd(g_hw.dma1, DMA_MM2S_DMASR));
        } else if (channel != nullptr && std::strcmp(channel, "DMA2") == 0) {
            FPGA_HW_FAIL_LOG("DMA2 reset failed DMACR=0x%08x DMASR=0x%08x", rd(g_hw.dma2, DMA_S2MM_DMACR),
                             rd(g_hw.dma2, DMA_S2MM_DMASR));
        } else {
            FPGA_HW_FAIL_LOG("DMA reset failed");
        }
    };

    auto log_dma_wait_failure = [&](const char * channel, DmaWaitStatus status) {
        FPGA_HW_FAIL_LOG(
            "%s wait %s DMA0_DMASR=0x%08x DMA1_DMASR=0x%08x DMA2_DMASR=0x%08x",
            channel, dma_wait_status_name(status), rd(g_hw.dma0, DMA_MM2S_DMASR), rd(g_hw.dma1, DMA_MM2S_DMASR),
            rd(g_hw.dma2, DMA_S2MM_DMASR));
    };

    auto reset_after_dma_wait_failure = [&]() {
        if (g_dma_reset_mode == DmaResetMode::EACH_TILE) {
            return;
        }

        const char * reset_failed_channel = nullptr;
        if (dma_full_reset_all(&dma_reset_ms, &reset_failed_channel)) {
            if (g_dma_reset_mode == DmaResetMode::ON_ERROR) {
                g_dma_reset_ready = true;
            }
        } else {
            g_dma_reset_ready = false;
            log_dma_reset_failure(reset_failed_channel);
        }
    };

    if (g_dma_reset_mode == DmaResetMode::ONCE_CALL ||
        (g_dma_reset_mode == DmaResetMode::ON_ERROR && !g_dma_reset_ready)) {
        const char * reset_failed_channel = nullptr;
        if (!dma_full_reset_all(&dma_reset_ms, &reset_failed_channel)) {
            log_dma_reset_failure(reset_failed_channel);
            fpga_stats_set_last_runtime_fallback_reason(FPGA_FB_DMA_RUNTIME_FAILED);
            fpga_stats_record_pre_submit_rejection(FPGA_FB_DMA_RUNTIME_FAILED);
            g_dma_reset_ready = false;
            return false;
        }
        if (g_dma_reset_mode == DmaResetMode::ON_ERROR) {
            g_dma_reset_ready = true;
        }
    }

    for (PackedTile & tile : rec->tiles) {
        uint64_t weight_phys  = 0;
        size_t   weight_bytes = 0;
        if (!place_tile_in_ddr(rec, tile, weight_phys, weight_bytes)) {
            FPGA_HW_FAIL_LOG("B cache placement failed n0=%d cur_N=%d N_pad=%d", tile.n0, tile.cur_N, tile.N_pad);
            fpga_stats_set_last_runtime_fallback_reason(FPGA_FB_CACHE_PLACEMENT_FAILED);
            fpga_stats_record_pre_submit_rejection(FPGA_FB_CACHE_PLACEMENT_FAILED);
            return false;
        }

        const int k_blocks = tile.K_tile / 32;

        // llama.cpp often calls GEMM during token generation with very small M
        // such as M=1 or M=2. The RTL/DMA2 path is more reliable when it sees
        // a full 32-row block, matching the 32x32 systolic/dataflow design.
        // We therefore pad feature/result transfers to M_hw rows, fill the
        // extra feature rows with zero, and copy back only the original M rows.
        const int M_hw = M_hw_for_call;

        if (tile.K_tile <= 0 || (tile.K_tile % 32) != 0 || k_blocks < 1 || k_blocks > 31 || M_hw < 1 || M_hw > 511 ||
            (M_hw * k_blocks) > HW_BUFFER_LIMIT) {
            FPGA_HW_FAIL_LOG(
                "RTL tile shape M=%d M_hw=%d K=%d N=%d k0=%d K_tile=%d k_blocks=%d M_hw*k_blocks=%d limit=%d", M, M_hw,
                K, N, tile.k0, tile.K_tile, k_blocks, M_hw * k_blocks, HW_BUFFER_LIMIT);
            fpga_stats_set_last_runtime_fallback_reason(FPGA_FB_RTL_SHAPE);
            fpga_stats_record_pre_submit_rejection(FPGA_FB_RTL_SHAPE);
            return false;
        }

        const size_t feature_bytes = (size_t) M_hw * (size_t) tile.K_tile;
        if (feature_bytes > g_hw.a_size) {
            FPGA_HW_FAIL_LOG("feature_bytes=%zu > A_size=%zu M=%d M_hw=%d K_tile=%d", feature_bytes, g_hw.a_size, M,
                             M_hw, tile.K_tile);
            fpga_stats_set_last_runtime_fallback_reason(FPGA_FB_FEATURE_BUFFER_LIMIT);
            fpga_stats_record_pre_submit_rejection(FPGA_FB_FEATURE_BUFFER_LIMIT);
            return false;
        }

        auto t_feature_copy0 = std::chrono::high_resolution_clock::now();

        std::memset(g_hw.feature_v, 0, feature_bytes);

        for (int m = 0; m < M; ++m) {
            std::memcpy(g_hw.feature_v + (size_t) m * (size_t) tile.K_tile,
                        qx.data() + (size_t) m * (size_t) K + (size_t) tile.k0, (size_t) tile.K_tile);
        }

        auto t_feature_copy1 = std::chrono::high_resolution_clock::now();
        feature_copy_ms += std::chrono::duration<double, std::milli>(t_feature_copy1 - t_feature_copy0).count();

        if (weight_phys == 0 || weight_bytes == 0) {
            FPGA_HW_FAIL_LOG(
                "tile DMA address invalid n0=%d cur_N=%d N_pad=%d hw_resident=%d phys=0x%llx bytes=%zu "
                "weight_buf_size=%zu",
                tile.n0, tile.cur_N, tile.N_pad, tile.hw_resident ? 1 : 0, (unsigned long long) weight_phys,
                weight_bytes, g_hw.b_size);
            fpga_stats_set_last_runtime_fallback_reason(FPGA_FB_WEIGHT_BUFFER_LIMIT);
            fpga_stats_record_pre_submit_rejection(FPGA_FB_WEIGHT_BUFFER_LIMIT);
            return false;
        }

        if (weight_bytes > g_hw.b_size) {
            FPGA_HW_FAIL_LOG("weight_bytes=%zu > weight_buf_size=%zu n0=%d cur_N=%d N_pad=%d", weight_bytes,
                             g_hw.b_size, tile.n0, tile.cur_N, tile.N_pad);
            fpga_stats_count_b_tile_too_large_fallback();
            fpga_stats_set_last_runtime_fallback_reason(FPGA_FB_WEIGHT_BUFFER_LIMIT);
            fpga_stats_record_pre_submit_rejection(FPGA_FB_WEIGHT_BUFFER_LIMIT);
            return false;
        }

        const size_t result_bytes = (size_t) M_hw * (size_t) tile.N_pad;
        if (result_bytes > g_hw.c_size) {
            FPGA_HW_FAIL_LOG("result_bytes=%zu > C_size=%zu M=%d M_hw=%d N_pad=%d n0=%d cur_N=%d", result_bytes,
                             g_hw.c_size, M, M_hw, tile.N_pad, tile.n0, tile.cur_N);
            fpga_stats_set_last_runtime_fallback_reason(FPGA_FB_RESULT_BUFFER_LIMIT);
            fpga_stats_record_pre_submit_rejection(FPGA_FB_RESULT_BUFFER_LIMIT);
            return false;
        }

        auto t_result_clear0 = std::chrono::high_resolution_clock::now();
        std::memset(g_hw.result_v, 0, result_bytes);
        auto t_result_clear1 = std::chrono::high_resolution_clock::now();
        result_copy_ms += std::chrono::duration<double, std::milli>(t_result_clear1 - t_result_clear0).count();

        auto t_shift0 = std::chrono::high_resolution_clock::now();
        int  shift    = 0;
        if (!choose_shift_for_tile(qx, max_abs_qx, tile, M, K, N, rec->quant, shift)) {
            auto t_shift_fail = std::chrono::high_resolution_clock::now();
            const double shift_fail_ms = std::chrono::duration<double, std::milli>(t_shift_fail - t_shift0).count();
            shift_select_ms += shift_fail_ms;
            fpga_stats_add_shift_select_time(shift_fail_ms);
            fpga_stats_set_last_runtime_fallback_reason(FPGA_FB_INVALID_SHIFT);
            fpga_stats_record_pre_submit_rejection(FPGA_FB_INVALID_SHIFT);
            return false;
        }
        auto t_shift1 = std::chrono::high_resolution_clock::now();
        const double shift_ms = std::chrono::duration<double, std::milli>(t_shift1 - t_shift0).count();
        shift_select_ms += shift_ms;
        fpga_stats_add_shift_select_time(shift_ms);

        auto t_ctrl0 = std::chrono::high_resolution_clock::now();
        hw_write_ctrl_config(shift, M_hw, k_blocks, tile.N_pad / 32);
        auto t_ctrl1 = std::chrono::high_resolution_clock::now();
        ctrl_config_ms += std::chrono::duration<double, std::milli>(t_ctrl1 - t_ctrl0).count();

        if (g_dma_reset_mode == DmaResetMode::EACH_TILE) {
            const char * reset_failed_channel = nullptr;
            if (!dma_full_reset_all(&dma_reset_ms, &reset_failed_channel)) {
                log_dma_reset_failure(reset_failed_channel);
                fpga_stats_set_last_runtime_fallback_reason(FPGA_FB_DMA_RUNTIME_FAILED);
                fpga_stats_record_pre_submit_rejection(FPGA_FB_DMA_RUNTIME_FAILED);
                return false;
            }
        } else {
            dma_prepare_tile_status_clear_all();
        }

        // DMA order must match the previously PASS-tested Linux flow:
        //   S2MM result first, then feature MM2S, then weight MM2S.
        const uint64_t padded_macs = (uint64_t) M_hw * (uint64_t) tile.K_tile * (uint64_t) tile.N_pad;
        auto t_dma_start0 = std::chrono::high_resolution_clock::now();
        const bool s2mm_started = dma_start_s2mm(g_hw.dma2, g_hw.c_phys, (uint32_t) result_bytes);
        const bool dma0_started = dma_start_mm2s(g_hw.dma0, g_hw.a_phys, (uint32_t) feature_bytes);
        const bool dma1_started = dma_start_mm2s(g_hw.dma1, weight_phys, (uint32_t) weight_bytes);
        auto t_dma_start1 = std::chrono::high_resolution_clock::now();
        dma_start_ms += std::chrono::duration<double, std::milli>(t_dma_start1 - t_dma_start0).count();
        fpga_stats_record_job_submitted(padded_macs);
        if (!s2mm_started || !dma0_started || !dma1_started) {
            FPGA_HW_FAIL_LOG("DMA start failed s2mm=%d dma0=%d dma1=%d", s2mm_started ? 1 : 0,
                             dma0_started ? 1 : 0, dma1_started ? 1 : 0);
            fpga_stats_record_illegal_job_submission();
            fpga_stats_record_job_failed(FPGA_FB_DMA_RUNTIME_FAILED);
            fpga_stats_set_last_runtime_fallback_reason(FPGA_FB_DMA_RUNTIME_FAILED);
            return false;
        }

        auto                t_dma_wait0_0 = std::chrono::high_resolution_clock::now();
        const DmaWaitStatus wait0         = dma_wait_mm2s_current(g_hw.dma0);
        if (wait0 != DmaWaitStatus::DONE) {
            log_dma_wait_failure("DMA0", wait0);
            FPGA_HW_FAIL_LOG("DMA0 wait context phys=0x%llx bytes=%zu M=%d M_hw=%d K=%d",
                             (unsigned long long) g_hw.a_phys, feature_bytes, M, M_hw, K);
            fpga_stats_count_dma_wait_status(wait0);
            fpga_stats_set_last_runtime_fallback_reason(wait0 == DmaWaitStatus::TIMEOUT ? FPGA_FB_DMA_TIMEOUT :
                                                                                          FPGA_FB_DMA_RUNTIME_FAILED);
            fpga_stats_record_job_failed(fpga_stats_get_last_runtime_fallback_reason());
            reset_after_dma_wait_failure();
            return false;
        }
        auto t_dma_wait0_1 = std::chrono::high_resolution_clock::now();
        dma_wait0_ms += std::chrono::duration<double, std::milli>(t_dma_wait0_1 - t_dma_wait0_0).count();

        auto                t_dma_wait1_0 = std::chrono::high_resolution_clock::now();
        const DmaWaitStatus wait1         = dma_wait_mm2s_current(g_hw.dma1);
        if (wait1 != DmaWaitStatus::DONE) {
            log_dma_wait_failure("DMA1", wait1);
            FPGA_HW_FAIL_LOG("DMA1 wait context phys=0x%llx bytes=%zu tile n0=%d cur_N=%d N_pad=%d",
                             (unsigned long long) weight_phys, weight_bytes, tile.n0, tile.cur_N, tile.N_pad);
            fpga_stats_count_dma_wait_status(wait1);
            fpga_stats_set_last_runtime_fallback_reason(wait1 == DmaWaitStatus::TIMEOUT ? FPGA_FB_DMA_TIMEOUT :
                                                                                          FPGA_FB_DMA_RUNTIME_FAILED);
            fpga_stats_record_job_failed(fpga_stats_get_last_runtime_fallback_reason());
            reset_after_dma_wait_failure();
            return false;
        }
        auto t_dma_wait1_1 = std::chrono::high_resolution_clock::now();
        dma_wait1_ms += std::chrono::duration<double, std::milli>(t_dma_wait1_1 - t_dma_wait1_0).count();

        auto                t_dma_wait2_0 = std::chrono::high_resolution_clock::now();
        const DmaWaitStatus wait2         = dma_wait_s2mm_current(g_hw.dma2);
        if (wait2 != DmaWaitStatus::DONE) {
            log_dma_wait_failure("DMA2", wait2);
            FPGA_HW_FAIL_LOG("DMA2 wait context phys=0x%llx bytes=%zu M=%d M_hw=%d N_pad=%d",
                             (unsigned long long) g_hw.c_phys, result_bytes, M, M_hw, tile.N_pad);
            fpga_stats_count_dma_wait_status(wait2);
            fpga_stats_set_last_runtime_fallback_reason(wait2 == DmaWaitStatus::TIMEOUT ? FPGA_FB_DMA_TIMEOUT :
                                                                                          FPGA_FB_DMA_RUNTIME_FAILED);
            fpga_stats_record_job_failed(fpga_stats_get_last_runtime_fallback_reason());
            reset_after_dma_wait_failure();
            return false;
        }
        auto t_dma_wait2_1 = std::chrono::high_resolution_clock::now();
        dma_wait2_ms += std::chrono::duration<double, std::milli>(t_dma_wait2_1 - t_dma_wait2_0).count();

        const int8_t * qout        = (const int8_t *) g_hw.result_v;
        const float    shift_scale = (float) (1u << shift);

        auto t_result_copy0 = std::chrono::high_resolution_clock::now();
        if (reconstruction_check_full()) {
            if (!reconstruct_tile_full_check(qout, tile, scale_x, C, M, N, shift_scale, k_tiling_used, sat_count,
                                             sat_total, k_tiling_sat_count, k_tiling_sat_total)) {
                return false;
            }
        } else {
            reconstruct_tile_check_off(qout, tile, scale_x, C, M, N, shift_scale, k_tiling_used, sat_count,
                                       sat_total, k_tiling_sat_count, k_tiling_sat_total);
        }
        auto t_result_copy1 = std::chrono::high_resolution_clock::now();
        result_copy_ms += std::chrono::duration<double, std::milli>(t_result_copy1 - t_result_copy0).count();
        detail_tile_count++;
        fpga_stats_record_job_completed();
    }

    fpga_stats_count_saturation(sat_count, sat_total);
    if (k_tiling_used) {
        fpga_stats_count_k_tiling_saturation(k_tiling_sat_count, k_tiling_sat_total);
    }
    fpga_stats_add_runtime_detail(shift_select_ms, feature_copy_ms, result_copy_ms, ctrl_config_ms, dma_reset_ms,
                                  dma_start_ms, dma_wait0_ms, dma_wait1_ms, dma_wait2_ms, detail_tile_count);
#    undef FPGA_HW_FAIL_LOG
    return true;
}
#endif

// -----------------------------------------------------------------------------
// Backend selection.
// Windows -> true hardware mock.
// KV260 Linux with overlay + /dev/gemm_dma_buf -> hardware.
// Linux without hardware -> not ready, CPU fallback.
// -----------------------------------------------------------------------------
static FpgaBackend choose_backend() {
#if defined(_WIN32)
    return fpga_win_mock_available() ? FpgaBackend::MOCK : FpgaBackend::NONE;
#else
    if (hw_init()) {
        return FpgaBackend::HW;
    }
    return FpgaBackend::NONE;
#endif
}

bool fpga_gemm_init(void) {
    std::lock_guard<std::mutex> init_lock(g_init_mutex);

    fpga_stats_register_atexit();
    init_b_cache_mode_once();
    init_shift_mode_once();
    init_dma_reset_mode_once();
    init_runtime_env_once();

    if (g_backend == FpgaBackend::UNINIT) {
        g_backend = choose_backend();

        if (g_backend == FpgaBackend::HW) {
            fprintf(stderr, "[FPGA][init] backend = KV260 hardware\n");
        } else if (g_backend == FpgaBackend::MOCK) {
            fprintf(stderr, "[FPGA][init] backend = mock\n");
        } else {
            fprintf(stderr, "[FPGA][init] backend = NONE\n");
        }
    }

    if (g_backend == FpgaBackend::HW) {
        std::lock_guard<std::mutex> lock(g_weight_mutex);
        load_dump_file_once_locked();
    }

    return g_backend == FpgaBackend::MOCK || g_backend == FpgaBackend::HW;
}

bool fpga_gemm_is_ready(void) {
    return fpga_gemm_init();
}

bool fpga_gemm_is_hardware_backend(void) {
    fpga_gemm_init();
    return g_backend == FpgaBackend::HW;
}

bool fpga_gemm_is_mock_backend(void) {
    fpga_gemm_init();
    return g_backend == FpgaBackend::MOCK;
}

void fpga_gemm_set_tensor_context(const char * tensor_name) {
    if (tensor_name != nullptr && tensor_name[0] != '\0') {
        g_tensor_context = tensor_name;
    } else {
        g_tensor_context.clear();
    }
}

const char * fpga_gemm_current_shift_mode(void) {
    init_shift_mode_once();
    return shift_mode_name();
}

void fpga_gemm_shutdown(void) {
    fpga_stats_print();

#if !defined(_WIN32)
    hw_close();
#endif

    {
        std::lock_guard<std::mutex> lock(g_weight_mutex);
        g_records.clear();
        g_prepared_cache.clear();
        g_dump_loaded = false;
#if !defined(_WIN32)
        g_weight_bank_offset = 0;
#endif
    }

    g_backend = FpgaBackend::UNINIT;
}

void fpga_gemm_cleanup(void) {
    fpga_gemm_shutdown();
}

static bool fpga_quant_supported(FpgaQuantType quant) {
    if (quant == FPGA_QUANT_F32) {
        return true;
    }

    const enum ggml_type type = fpga_quant_to_ggml_type(quant);
    if (type == GGML_TYPE_COUNT) {
        return false;
    }

    const struct ggml_type_traits * traits = ggml_get_type_traits(type);
    return traits != nullptr && traits->to_float != nullptr;
}

static bool fpga_force_abort_if_needed(const char * reason, int M, int K, int N, FpgaQuantType quant) {
    init_runtime_env_once();
    if (!g_force_full_offload) {
        return false;
    }

    fprintf(stderr, "[FPGA][fatal] forced full-offload failed: %s M=%d K=%d N=%d quant=%d\n",
            reason != nullptr ? reason : "unknown", M, K, N, (int) quant);
    fpga_stats_print();
    std::abort();
}

bool fpga_gemm_try_run(const void *  A_raw,
                       FpgaQuantType quant,
                       const float * B_f32,
                       float *       C,
                       int           M,
                       int           K_orig,
                       int           N_orig,
                       int           shift_in) {
    (void) shift_in;

    init_runtime_env_once();
    fpga_stats_set_last_runtime_fallback_reason(FPGA_FB_OTHER);

    const auto t0 = std::chrono::high_resolution_clock::now();

    if (A_raw == nullptr || B_f32 == nullptr || C == nullptr || M <= 0 || K_orig <= 0 || N_orig <= 0 ||
        !fpga_quant_supported(quant)) {
        fpga_stats_set_last_runtime_fallback_reason(FPGA_FB_UNSUPPORTED_QUANT_NO_DEQUANT);
        fpga_force_abort_if_needed("bad arguments or unsupported quant", M, K_orig, N_orig, quant);
        return false;
    }

    if ((K_orig % 32) != 0 || N_orig > HW_N_MAX) {
        fpga_stats_set_last_runtime_fallback_reason(N_orig > HW_N_MAX ? FPGA_FB_MAX_N : FPGA_FB_SHAPE_NOT_SUPPORTED);
        fpga_force_abort_if_needed("K/N outside software tiling policy", M, K_orig, N_orig, quant);
        return false;
    }

    if (K_orig != HW_K_SUPPORTED && !g_experimental_k_tiling) {
        fpga_stats_set_last_runtime_fallback_reason(FPGA_FB_SCOPE_POLICY);
        fpga_force_abort_if_needed("K tiling disabled for K != 896", M, K_orig, N_orig, quant);
        return false;
    }

    if (M < HW_M_MIN && !g_small_m_pad32) {
        fpga_stats_set_last_runtime_fallback_reason(FPGA_FB_SMALL_M);
        fpga_force_abort_if_needed("small-M pad32 disabled", M, K_orig, N_orig, quant);
        return false;
    }

    if (g_backend == FpgaBackend::UNINIT) {
        fpga_gemm_init();
    }

    std::vector<int8_t> qx;
    std::vector<float>  scale_x;
    std::vector<float>  max_abs_qx;

    if (!quantize_feature_rows(B_f32, M, K_orig, qx, scale_x, max_abs_qx)) {
        fpga_stats_set_last_runtime_fallback_reason(FPGA_FB_OTHER);
        return false;
    }

    const auto t_act_done = std::chrono::high_resolution_clock::now();

    PackedRecord * rec = get_or_prepare_weight(A_raw, quant, K_orig, N_orig);
    if (rec == nullptr) {
        fpga_stats_set_last_runtime_fallback_reason(FPGA_FB_CACHE_PLACEMENT_FAILED);
        fpga_force_abort_if_needed("weight packing/cache placement failed", M, K_orig, N_orig, quant);
        return false;
    }

    const auto t_weight_done = std::chrono::high_resolution_clock::now();

    if (K_orig != HW_K_SUPPORTED) {
        fpga_stats_count_k_tiling_call((uint64_t) rec->tiles.size());
        static uint64_t s_k_tile_log_count = 0;
        if (s_k_tile_log_count < 16) {
            fprintf(stderr,
                    "[FPGA][K_TILE] approximate software K-tiling M=%d K=%d N=%d hardware_tiles=%zu\n",
                    M, K_orig, N_orig, rec->tiles.size());
            s_k_tile_log_count++;
        }
    }

    bool ok = false;

    if (g_backend == FpgaBackend::HW) {
        fpga_stats_count_backend_hw();

#if !defined(_WIN32)
        ok = hw_gemm(rec, qx, scale_x, max_abs_qx, C, M, K_orig, N_orig);
#endif

        if (!ok && fpga_stats_get_last_runtime_fallback_reason() == FPGA_FB_OTHER) {
            fpga_stats_set_last_runtime_fallback_reason(FPGA_FB_DMA_RUNTIME_FAILED);
        }

        if (!ok && allow_hw_runtime_mock_fallback()) {
            // Explicit opt-in only. Default is no hidden mock: ggml should fall
            // through to its normal CPU implementation so outputs stay valid.
            fpga_stats_count_hw_runtime_fallback();
            ok = true_hw_mock_gemm(rec, qx, scale_x, max_abs_qx, C, M, K_orig, N_orig);
        }
        if (!ok) {
            fpga_force_abort_if_needed("hardware runtime failed", M, K_orig, N_orig, quant);
        }
    } else if (g_backend == FpgaBackend::MOCK) {
        fpga_stats_count_backend_mock();
        ok = true_hw_mock_gemm(rec, qx, scale_x, max_abs_qx, C, M, K_orig, N_orig);
        if (!ok) {
            if (fpga_stats_get_last_runtime_fallback_reason() == FPGA_FB_OTHER) {
                fpga_stats_set_last_runtime_fallback_reason(FPGA_FB_OTHER);
            }
            fpga_force_abort_if_needed("mock runtime failed", M, K_orig, N_orig, quant);
        }
    } else {
        fpga_stats_set_last_runtime_fallback_reason(FPGA_FB_NOT_READY);
        fpga_force_abort_if_needed("backend not ready", M, K_orig, N_orig, quant);
    }

    const auto t_done = std::chrono::high_resolution_clock::now();

    const double total_ms          = std::chrono::duration<double, std::milli>(t_done - t0).count();
    const double act_quant_ms      = std::chrono::duration<double, std::milli>(t_act_done - t0).count();
    const double weight_prepare_ms = std::chrono::duration<double, std::milli>(t_weight_done - t_act_done).count();
    const double dma_fpga_ms       = std::chrono::duration<double, std::milli>(t_done - t_weight_done).count();

    fpga_stats_add_runtime(total_ms, act_quant_ms, weight_prepare_ms, dma_fpga_ms, 0.0);

    return ok;
}

void fpga_gemm_run(const void *  A_raw,
                   FpgaQuantType quant,
                   const float * B_f32,
                   float *       C,
                   int           M,
                   int           K_orig,
                   int           N_orig,
                   int           shift_in) {
    (void) fpga_gemm_try_run(A_raw, quant, B_f32, C, M, K_orig, N_orig, shift_in);
}
