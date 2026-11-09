#include "fpga_stats.h"

#include <inttypes.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <ctime>
#include <fstream>
#include <map>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sstream>
#include <string>
#include <tuple>
#include <vector>

#if defined(_WIN32)
#    include <direct.h>
#else
#    include <sys/stat.h>
#    include <sys/types.h>
#endif

static uint64_t g_total_mul_mat_calls = 0;
static uint64_t g_offloaded_calls     = 0;
static uint64_t g_fallback_calls      = 0;

static uint64_t g_fallback_reason[FPGA_FB_COUNT] = { 0 };

static uint64_t g_quant_q5_0        = 0;
static uint64_t g_quant_q8_0        = 0;
static uint64_t g_quant_q6_K        = 0;
static uint64_t g_quant_generic     = 0;
static uint64_t g_quant_unsupported = 0;

static bool g_force_full_offload = false;

static uint64_t g_policy_small_m_fallback  = 0;
static uint64_t g_policy_min_macs_fallback = 0;
static uint64_t g_policy_max_n_fallback    = 0;
static uint64_t g_policy_m_range_fallback  = 0;
static uint64_t g_policy_m_list_fallback   = 0;

static uint64_t g_k_tiling_calls       = 0;
static uint64_t g_k_tiling_hw_tiles    = 0;
static uint64_t g_small_m_pad_calls    = 0;
static uint64_t g_small_m_padded_rows  = 0;
static uint64_t g_small_m_total_rows   = 0;
static uint64_t g_shift_exact_count    = 0;
static uint64_t g_shift_cached_count   = 0;
static uint64_t g_shift_fixed_count    = 0;
static uint64_t g_shift_table_calls    = 0;
static uint64_t g_shift_table_hits     = 0;
static uint64_t g_shift_table_misses   = 0;
static uint64_t g_shift_table_miss_cpu_fallbacks = 0;
static uint64_t g_shift_table_miss_fixed         = 0;
static uint64_t g_shift_table_miss_cached        = 0;
static uint64_t g_shift_table_miss_exact         = 0;
static double   g_shift_select_time_ms           = 0.0;

static uint64_t g_k_tiling_saturation_count = 0;
static uint64_t g_k_tiling_total_outputs    = 0;
static double   g_k_tiling_mae_sum          = 0.0;
static double   g_k_tiling_max_abs_error    = 0.0;
static double   g_k_tiling_match_rate_sum   = 0.0;
static uint64_t g_k_tiling_validation_count = 0;

static uint64_t g_shape_m_eq_1          = 0;
static uint64_t g_shape_m_eq_2          = 0;
static uint64_t g_shape_m_lt_32         = 0;
static uint64_t g_shape_m_ge_32         = 0;
static uint64_t g_shape_m_lt_32_fallback = 0;
static uint64_t g_shape_m_ge_32_offload  = 0;
static uint64_t g_shape_n_tile_count      = 0;

static uint64_t g_weight_cache_hit  = 0;
static uint64_t g_weight_cache_miss = 0;
static uint64_t g_weight_file_hit   = 0;
static uint64_t g_weight_file_miss  = 0;
static uint64_t g_weight_file_bytes = 0;
static uint64_t g_weight_ddr_bytes  = 0;

static char     g_b_cache_mode[16]                 = "persistent";
static uint64_t g_b_buffer_limit_bytes             = 0;
static uint64_t g_b_cache_max_used_bytes           = 0;
static uint64_t g_b_cache_full_count               = 0;
static uint64_t g_b_cache_clear_count              = 0;
static uint64_t g_b_scratch_copies                 = 0;
static uint64_t g_b_tile_too_large_fallback_count  = 0;

static char     g_dma_reset_mode[16]             = "each_tile";
static char     g_reconstruction_check_mode[8]   = "full";
static uint64_t g_dma_full_reset_calls      = 0;
static uint64_t g_dma_status_clear_calls    = 0;
static uint64_t g_dma_reset_failures        = 0;
static uint64_t g_dma_runtime_errors        = 0;
static uint64_t g_dma_runtime_timeouts      = 0;

static uint64_t g_backend_mock_calls  = 0;
static uint64_t g_backend_hw_calls    = 0;
static uint64_t g_hw_runtime_fallback = 0;

static uint64_t g_sat_count = 0;
static uint64_t g_sat_total = 0;

static FpgaFallbackReason g_last_runtime_fallback_reason = FPGA_FB_OTHER;

static double g_total_MACs   = 0.0;
static double g_offload_MACs = 0.0;

static uint64_t g_sum_M = 0;
static uint64_t g_sum_K = 0;
static uint64_t g_sum_N = 0;

static double g_total_ms          = 0.0;
static double g_act_quant_ms      = 0.0;
static double g_weight_prepare_ms = 0.0;
static double g_dma_fpga_ms       = 0.0;
static double g_result_dequant_ms = 0.0;

static double   g_shift_select_ms = 0.0;
static double   g_feature_copy_ms = 0.0;
static double   g_result_copy_ms  = 0.0;
static double   g_ctrl_config_ms  = 0.0;
static double   g_dma_reset_ms    = 0.0;
static double   g_dma_start_ms    = 0.0;
static double   g_dma_wait0_ms    = 0.0;
static double   g_dma_wait1_ms    = 0.0;
static double   g_dma_wait2_ms    = 0.0;
static uint64_t g_tile_count      = 0;

static bool g_atexit_registered = false;
static bool g_printed           = false;

struct ProfileConfig {
    bool        inited        = false;
    bool        enabled       = false;
    bool        compare       = false;
    bool        ggml_ops      = false;
    bool        verbose       = false;
    int         topk          = 30;
    uint64_t    flush_every_n = 1000;
    std::string dir           = ".";
    std::string run_id;
    std::chrono::steady_clock::time_point start_time;
};

struct ProfileKey {
    int64_t     layer_id = -1;
    std::string op_group;
    std::string tensor_name;
    std::string src0_name;
    std::string src1_name;
    std::string ggml_type;
    int64_t     M = 0;
    int64_t     K = 0;
    int64_t     N = 0;
    std::string decision;
    std::string fallback_reason;

    bool operator<(const ProfileKey & other) const {
        return std::tie(layer_id, op_group, tensor_name, src0_name, src1_name, ggml_type, M, K, N, decision,
                        fallback_reason) <
               std::tie(other.layer_id, other.op_group, other.tensor_name, other.src0_name, other.src1_name,
                        other.ggml_type, other.M, other.K, other.N, other.decision, other.fallback_reason);
    }
};

struct ProfileAgg {
    ProfileKey key;

    uint64_t calls              = 0;
    double   macs_total         = 0.0;
    uint64_t fpga_calls         = 0;
    uint64_t cpu_fallback_calls = 0;
    uint64_t fpga_tile_count    = 0;

    double cpu_latency_ms_total  = 0.0;
    double fpga_latency_ms_total = 0.0;
    bool   has_cpu_latency       = false;
    bool   has_fpga_latency      = false;

    uint64_t small_m_count              = 0;
    uint64_t max_n_count                = 0;
    uint64_t unsupported_quant_count    = 0;
    uint64_t dma_failed_count           = 0;
    uint64_t dma_timeout_count          = 0;
    uint64_t weight_cache_hit_count     = 0;
    uint64_t weight_cache_miss_count    = 0;

    double   max_abs_error_sum = 0.0;
    double   max_abs_error_max = 0.0;
    double   mae_sum           = 0.0;
    uint64_t compare_calls     = 0;
    uint64_t mismatch_count    = 0;
    uint64_t compared_count    = 0;
};

struct ShapeAgg {
    uint64_t calls       = 0;
    uint64_t fpga_calls  = 0;
    uint64_t cpu_calls   = 0;
    uint64_t tile_count  = 0;
    double   macs_total  = 0.0;
    double   fpga_ms     = 0.0;
};

static ProfileConfig               g_profile;
static std::map<ProfileKey, ProfileAgg> g_profile_ops;
static std::map<std::tuple<int64_t, int64_t, int64_t>, ShapeAgg> g_profile_shapes;
static uint64_t                    g_profile_record_count = 0;

struct PhaseAuditCounters {
    uint64_t total_logical_gemms                  = 0;
    uint64_t cpu_only_executed_gemms              = 0;
    uint64_t policy_rejected_cpu_gemms            = 0;
    uint64_t policy_eligible_logical_gemms        = 0;
    uint64_t successfully_offloaded_logical_gemms = 0;
    uint64_t runtime_failed_logical_gemms         = 0;
    uint64_t successful_hardware_jobs             = 0;
    uint64_t min_jobs_per_gemm                    = 0;
    uint64_t max_jobs_per_gemm                    = 0;
    uint64_t submitted_hardware_jobs             = 0;
    uint64_t completed_hardware_jobs             = 0;
    uint64_t failed_hardware_jobs                = 0;
    uint64_t pre_submit_rejections               = 0;
    uint64_t illegal_job_submissions             = 0;
    uint64_t dma_errors                          = 0;
    uint64_t dma_timeouts                        = 0;
    uint64_t reconstruction_failures             = 0;
    double   logical_macs_total                  = 0.0;
    double   offloaded_logical_macs              = 0.0;
    double   submitted_padded_macs               = 0.0;
    double   min_macs_observed                   = 0.0;
    double   max_macs_observed                   = 0.0;
    uint64_t fallback_reason[FPGA_FB_COUNT]      = { 0 };
};

struct NumericalL2Row {
    uint64_t    logical_gemm_id = 0;
    std::string mode;
    std::string phase;
    std::string tensor_name;
    int64_t     layer_id = -1;
    std::string operator_family;
    std::string ggml_type;
    int64_t     M = 0;
    int64_t     K = 0;
    int64_t     N = 0;
    uint64_t    hardware_jobs = 0;
    double      sum_diff_squared = 0.0;
    double      sum_cpu_squared = 0.0;
    double      relative_l2 = -1.0;
    bool        zero_cpu_nonzero_diff = false;
    bool        valid = false;
};

struct NumericalAggKey {
    std::string operator_family;
    std::string ggml_type;
    int64_t     M = 0;
    int64_t     K = 0;
    int64_t     N = 0;

    bool operator<(const NumericalAggKey & other) const {
        return std::tie(operator_family, ggml_type, M, K, N) <
               std::tie(other.operator_family, other.ggml_type, other.M, other.K, other.N);
    }
};

struct NumericalAgg {
    uint64_t calls = 0;
    uint64_t valid_calls = 0;
    uint64_t hardware_jobs = 0;
    uint64_t min_jobs_per_gemm = 0;
    uint64_t max_jobs_per_gemm = 0;
    double   sum_diff_squared = 0.0;
    double   sum_cpu_squared = 0.0;
    double   min_relative_l2 = 0.0;
    double   max_relative_l2 = 0.0;
    uint64_t zero_cpu_nonzero_diff = 0;
};

struct NumericalFallbackKey {
    std::string phase;
    std::string operator_family;
    std::string ggml_type;
    int64_t     M = 0;
    int64_t     K = 0;
    int64_t     N = 0;
    std::string reason;

    bool operator<(const NumericalFallbackKey & other) const {
        return std::tie(phase, operator_family, ggml_type, M, K, N, reason) <
               std::tie(other.phase, other.operator_family, other.ggml_type, other.M, other.K, other.N, other.reason);
    }
};

static PhaseAuditCounters g_phase_counters[FPGA_PHASE_COUNT];
static FpgaPhase          g_current_phase = FPGA_PHASE_UNKNOWN;
static uint64_t           g_logical_gemm_id = 0;
static uint64_t           g_current_logical_gemm_id = 0;
static bool               g_control_config_inited = false;
static FpgaRuntimeMode    g_runtime_mode = FPGA_RUNTIME_MODE_SELECTIVE;
static FpgaAuditLevel     g_audit_level = FPGA_AUDIT_SUMMARY;
static std::vector<NumericalL2Row> g_numerical_l2_rows;
static std::map<NumericalAggKey, NumericalAgg> g_numerical_l2_summary;
static std::map<NumericalFallbackKey, uint64_t> g_numerical_l2_fallback;

struct KTilingValidationRow {
    std::string tensor_name;
    int64_t     layer_id = -1;
    std::string op_group;
    std::string qtype;
    int64_t     M = 0;
    int64_t     K = 0;
    int64_t     N = 0;
    uint64_t    num_k_tiles = 0;
    uint64_t    num_hw_tiles = 0;
    std::string shift_mode;
    uint64_t    shift_table_hits = 0;
    uint64_t    shift_table_misses = 0;
    double      max_abs_error = -1.0;
    double      mae = -1.0;
    uint64_t    mismatch_count = 0;
    uint64_t    compared_count = 0;
    uint64_t    saturation_count = 0;
    uint64_t    saturation_total = 0;
    bool        used_fpga = false;
    std::string fallback_reason;
};

static std::vector<KTilingValidationRow> g_k_tiling_validation_rows;

static bool env_flag_enabled(const char * name, bool default_value) {
    const char * v = getenv(name);
    if (v == NULL || v[0] == '\0') {
        return default_value;
    }

    if (strcmp(v, "1") == 0 || strcmp(v, "true") == 0 || strcmp(v, "TRUE") == 0 ||
        strcmp(v, "yes") == 0 || strcmp(v, "YES") == 0 || strcmp(v, "on") == 0 ||
        strcmp(v, "ON") == 0) {
        return true;
    }

    if (strcmp(v, "0") == 0 || strcmp(v, "false") == 0 || strcmp(v, "FALSE") == 0 ||
        strcmp(v, "no") == 0 || strcmp(v, "NO") == 0 || strcmp(v, "off") == 0 ||
        strcmp(v, "OFF") == 0) {
        return false;
    }

    return default_value;
}

static int env_i32(const char * name, int default_value, int min_value) {
    const char * v = getenv(name);
    if (v == NULL || v[0] == '\0') {
        return default_value;
    }

    char * end = NULL;
    long   x   = strtol(v, &end, 10);
    if (end == v) {
        return default_value;
    }
    if (x < min_value) {
        return min_value;
    }
    return (int) x;
}

static uint64_t env_u64(const char * name, uint64_t default_value) {
    const char * v = getenv(name);
    if (v == NULL || v[0] == '\0') {
        return default_value;
    }

    char *              end = NULL;
    unsigned long long  x   = strtoull(v, &end, 10);
    if (end == v) {
        return default_value;
    }
    return (uint64_t) x;
}

static double env_double(const char * name, double default_value) {
    const char * v = getenv(name);
    if (v == NULL || v[0] == '\0') {
        return default_value;
    }

    char * end = NULL;
    double x   = strtod(v, &end);
    if (end == v) {
        return default_value;
    }
    return x;
}

static bool ascii_equal_ignore_case_local(const char * a, const char * b) {
    if (a == NULL || b == NULL) {
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

static void ensure_control_config(void) {
    if (g_control_config_inited) {
        return;
    }

    g_control_config_inited = true;

    const char * mode = getenv("FPGA_MODE");
    if (mode == NULL || mode[0] == '\0' || ascii_equal_ignore_case_local(mode, "FPGA_SELECTIVE") ||
        ascii_equal_ignore_case_local(mode, "SELECTIVE")) {
        g_runtime_mode = FPGA_RUNTIME_MODE_SELECTIVE;
    } else if (ascii_equal_ignore_case_local(mode, "CPU_ONLY") ||
               ascii_equal_ignore_case_local(mode, "FPGA_CPU_ONLY")) {
        g_runtime_mode = FPGA_RUNTIME_MODE_CPU_ONLY;
    } else if (ascii_equal_ignore_case_local(mode, "FPGA_COMPARE") ||
               ascii_equal_ignore_case_local(mode, "COMPARE")) {
        g_runtime_mode = FPGA_RUNTIME_MODE_COMPARE;
    } else if (ascii_equal_ignore_case_local(mode, "FPGA_INCLUSIVE") ||
               ascii_equal_ignore_case_local(mode, "INCLUSIVE")) {
        g_runtime_mode = FPGA_RUNTIME_MODE_INCLUSIVE;
    } else {
        g_runtime_mode = FPGA_RUNTIME_MODE_SELECTIVE;
    }

    const char * audit = getenv("FPGA_AUDIT");
    if (audit == NULL || audit[0] == '\0' || ascii_equal_ignore_case_local(audit, "SUMMARY")) {
        g_audit_level = FPGA_AUDIT_SUMMARY;
    } else if (ascii_equal_ignore_case_local(audit, "OFF") || ascii_equal_ignore_case_local(audit, "0")) {
        g_audit_level = FPGA_AUDIT_OFF;
    } else if (ascii_equal_ignore_case_local(audit, "VERBOSE") || ascii_equal_ignore_case_local(audit, "1")) {
        g_audit_level = FPGA_AUDIT_VERBOSE;
    } else {
        g_audit_level = FPGA_AUDIT_SUMMARY;
    }
}

static double logical_macs(int64_t M, int64_t K, int64_t N) {
    return (M > 0 && K > 0 && N > 0) ? (double) M * (double) K * (double) N : 0.0;
}

static void update_min_max_macs(PhaseAuditCounters & c, double macs) {
    if (macs <= 0.0) {
        return;
    }
    if (c.min_macs_observed == 0.0 || macs < c.min_macs_observed) {
        c.min_macs_observed = macs;
    }
    if (macs > c.max_macs_observed) {
        c.max_macs_observed = macs;
    }
}

static FpgaPhase current_phase_for_accounting(void) {
    if (g_current_phase >= FPGA_PHASE_PREFILL && g_current_phase < FPGA_PHASE_COUNT) {
        return g_current_phase;
    }
    return FPGA_PHASE_UNKNOWN;
}

static void ensure_profile_config(void);

static void ensure_output_dir_created(void) {
    ensure_profile_config();
#if defined(_WIN32)
    _mkdir(g_profile.dir.c_str());
#else
    mkdir(g_profile.dir.c_str(), 0777);
#endif
}

static std::string make_run_id() {
    const auto now = std::chrono::system_clock::now();
    const auto ms  = std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch()).count();
    char       buf[64];
    snprintf(buf, sizeof(buf), "run_%lld", (long long) ms);
    return std::string(buf);
}

static void ensure_profile_config(void) {
    if (g_profile.inited) {
        return;
    }

    ensure_control_config();

    g_profile.inited        = true;
    g_profile.enabled       = env_flag_enabled("FPGA_PROFILE", false);
    g_profile.compare       = env_flag_enabled("FPGA_PROFILE_COMPARE", g_runtime_mode == FPGA_RUNTIME_MODE_COMPARE);
    g_profile.ggml_ops      = env_flag_enabled("FPGA_PROFILE_GGML_OPS", false);
    g_profile.verbose       = env_flag_enabled("FPGA_PROFILE_VERBOSE", false);
    g_profile.topk          = env_i32("FPGA_PROFILE_PRINT_TOPK", 30, 1);
    g_profile.flush_every_n = env_u64("FPGA_PROFILE_FLUSH_EVERY_N", 1000);
    g_profile.start_time    = std::chrono::steady_clock::now();
    g_profile.run_id        = make_run_id();

    const char * dir = getenv("FPGA_PROFILE_DIR");
    if (dir != NULL && dir[0] != '\0') {
        g_profile.dir = dir;
    }

    if (g_profile.enabled) {
        ensure_output_dir_created();
        fprintf(stderr,
                "[FPGA][profile] enabled dir=%s run_id=%s compare=%d topk=%d flush_every=%" PRIu64 "\n",
                g_profile.dir.c_str(), g_profile.run_id.c_str(), g_profile.compare ? 1 : 0, g_profile.topk,
                g_profile.flush_every_n);
    }
}

static std::string profile_path(const char * filename) {
    ensure_profile_config();
    std::string path = g_profile.dir;
    if (!path.empty() && path[path.size() - 1] != '/' && path[path.size() - 1] != '\\') {
        path += "/";
    }
    path += filename;
    return path;
}

FPGA_STATS_API FpgaRuntimeMode fpga_stats_get_runtime_mode(void) {
    ensure_control_config();
    return g_runtime_mode;
}

FPGA_STATS_API const char * fpga_stats_runtime_mode_name(FpgaRuntimeMode mode) {
    switch (mode) {
        case FPGA_RUNTIME_MODE_CPU_ONLY: return "CPU_ONLY";
        case FPGA_RUNTIME_MODE_COMPARE: return "FPGA_COMPARE";
        case FPGA_RUNTIME_MODE_INCLUSIVE: return "FPGA_INCLUSIVE";
        case FPGA_RUNTIME_MODE_SELECTIVE:
        default: return "FPGA_SELECTIVE";
    }
}

FpgaAuditLevel fpga_stats_get_audit_level(void) {
    ensure_control_config();
    return g_audit_level;
}

bool fpga_stats_audit_enabled(void) {
    return fpga_stats_get_audit_level() != FPGA_AUDIT_OFF;
}

bool fpga_stats_audit_verbose(void) {
    return fpga_stats_get_audit_level() == FPGA_AUDIT_VERBOSE;
}

FPGA_STATS_API void fpga_stats_set_phase(FpgaPhase phase) {
    if ((int) phase < 0 || (int) phase >= FPGA_PHASE_COUNT) {
        phase = FPGA_PHASE_UNKNOWN;
    }
    g_current_phase = phase;
}

FpgaPhase fpga_stats_get_phase(void) {
    return g_current_phase;
}

FPGA_STATS_API const char * fpga_stats_phase_name(FpgaPhase phase) {
    switch (phase) {
        case FPGA_PHASE_OVERALL: return "OVERALL";
        case FPGA_PHASE_PREFILL: return "PREFILL";
        case FPGA_PHASE_DECODE: return "DECODE";
        case FPGA_PHASE_UNKNOWN:
        default: return "UNKNOWN";
    }
}

uint64_t fpga_stats_get_current_logical_gemm_id(void) {
    return g_current_logical_gemm_id;
}

uint64_t fpga_stats_get_submitted_hardware_job_count(void) {
    return g_phase_counters[FPGA_PHASE_OVERALL].submitted_hardware_jobs;
}

uint64_t fpga_stats_get_completed_hardware_job_count(void) {
    return g_phase_counters[FPGA_PHASE_OVERALL].completed_hardware_jobs;
}

uint64_t fpga_stats_get_failed_hardware_job_count(void) {
    return g_phase_counters[FPGA_PHASE_OVERALL].failed_hardware_jobs;
}

static void snapshot_from_counter(const PhaseAuditCounters & c, FpgaStatsSnapshot * out) {
    if (out == NULL) {
        return;
    }

    memset(out, 0, sizeof(*out));
    out->total_logical_gemms                  = c.total_logical_gemms;
    out->cpu_only_executed_gemms              = c.cpu_only_executed_gemms;
    out->policy_rejected_cpu_gemms            = c.policy_rejected_cpu_gemms;
    out->policy_eligible_logical_gemms        = c.policy_eligible_logical_gemms;
    out->successfully_offloaded_logical_gemms = c.successfully_offloaded_logical_gemms;
    out->runtime_failed_logical_gemms         = c.runtime_failed_logical_gemms;
    out->successful_hardware_jobs             = c.successful_hardware_jobs;
    out->min_jobs_per_gemm                    = c.min_jobs_per_gemm;
    out->max_jobs_per_gemm                    = c.max_jobs_per_gemm;
    out->submitted_hardware_jobs              = c.submitted_hardware_jobs;
    out->completed_hardware_jobs              = c.completed_hardware_jobs;
    out->failed_hardware_jobs                 = c.failed_hardware_jobs;
    out->pre_submit_rejections                = c.pre_submit_rejections;
    out->illegal_job_submissions              = c.illegal_job_submissions;
    out->dma_errors                           = c.dma_errors;
    out->dma_timeouts                         = c.dma_timeouts;
    out->reconstruction_failures              = c.reconstruction_failures;
    out->logical_macs_total                   = c.logical_macs_total;
    out->offloaded_logical_macs               = c.offloaded_logical_macs;
    out->submitted_padded_macs                = c.submitted_padded_macs;
    out->min_macs_observed                    = c.min_macs_observed;
    out->max_macs_observed                    = c.max_macs_observed;
    memcpy(out->fallback_reason, c.fallback_reason, sizeof(out->fallback_reason));
}

FPGA_STATS_API void fpga_stats_get_snapshot(FpgaPhase phase, FpgaStatsSnapshot * out) {
    if ((int) phase < 0 || (int) phase >= FPGA_PHASE_COUNT) {
        phase = FPGA_PHASE_UNKNOWN;
    }
    snapshot_from_counter(g_phase_counters[(int) phase], out);
}

static int accounting_phases(FpgaPhase phases[2]) {
    phases[0] = FPGA_PHASE_OVERALL;
    const FpgaPhase phase = current_phase_for_accounting();
    if (phase != FPGA_PHASE_OVERALL) {
        phases[1] = phase;
        return 2;
    }
    return 1;
}

static void count_reason_for_phases(FpgaFallbackReason reason) {
    if ((int) reason < 0 || (int) reason >= FPGA_FB_COUNT) {
        reason = FPGA_FB_OTHER;
    }

    FpgaPhase phases[2];
    const int nphases = accounting_phases(phases);
    for (int i = 0; i < nphases; ++i) {
        g_phase_counters[(int) phases[i]].fallback_reason[(int) reason]++;
    }
}

FPGA_STATS_API void fpga_stats_reset_benchmark_counters(void) {
    fpga_stats_register_atexit();
    memset(g_phase_counters, 0, sizeof(g_phase_counters));
    g_current_phase = FPGA_PHASE_UNKNOWN;
}

void fpga_stats_record_cpu_only_gemm(int64_t M, int64_t K, int64_t N) {
    fpga_stats_register_atexit();

    const double macs = logical_macs(M, K, N);
    FpgaPhase phases[2];
    const int nphases = accounting_phases(phases);
    for (int i = 0; i < nphases; ++i) {
        PhaseAuditCounters & c = g_phase_counters[(int) phases[i]];
        c.cpu_only_executed_gemms++;
        c.logical_macs_total += macs;
        update_min_max_macs(c, macs);
    }
}

void fpga_stats_record_policy_eligible(int64_t M, int64_t K, int64_t N) {
    fpga_stats_register_atexit();

    const double macs = logical_macs(M, K, N);
    FpgaPhase phases[2];
    const int nphases = accounting_phases(phases);
    for (int i = 0; i < nphases; ++i) {
        PhaseAuditCounters & c = g_phase_counters[(int) phases[i]];
        c.policy_eligible_logical_gemms++;
        c.logical_macs_total += macs;
        update_min_max_macs(c, macs);
    }
}

void fpga_stats_record_policy_rejection(FpgaFallbackReason reason, int64_t M, int64_t K, int64_t N) {
    fpga_stats_register_atexit();

    const double macs = logical_macs(M, K, N);
    FpgaPhase phases[2];
    const int nphases = accounting_phases(phases);
    for (int i = 0; i < nphases; ++i) {
        PhaseAuditCounters & c = g_phase_counters[(int) phases[i]];
        c.policy_rejected_cpu_gemms++;
        c.logical_macs_total += macs;
        update_min_max_macs(c, macs);
    }
    count_reason_for_phases(reason);
}

void fpga_stats_record_offload_success(int64_t M, int64_t K, int64_t N, uint64_t hardware_jobs) {
    fpga_stats_register_atexit();

    const double macs = logical_macs(M, K, N);
    FpgaPhase phases[2];
    const int nphases = accounting_phases(phases);
    for (int i = 0; i < nphases; ++i) {
        PhaseAuditCounters & c = g_phase_counters[(int) phases[i]];
        c.successfully_offloaded_logical_gemms++;
        c.successful_hardware_jobs += hardware_jobs;
        if (c.min_jobs_per_gemm == 0 || hardware_jobs < c.min_jobs_per_gemm) {
            c.min_jobs_per_gemm = hardware_jobs;
        }
        if (hardware_jobs > c.max_jobs_per_gemm) {
            c.max_jobs_per_gemm = hardware_jobs;
        }
        c.offloaded_logical_macs += macs;
        update_min_max_macs(c, macs);
    }
}

void fpga_stats_record_runtime_failure(FpgaFallbackReason reason, int64_t M, int64_t K, int64_t N) {
    fpga_stats_register_atexit();

    const double macs = logical_macs(M, K, N);
    FpgaPhase phases[2];
    const int nphases = accounting_phases(phases);
    for (int i = 0; i < nphases; ++i) {
        PhaseAuditCounters & c = g_phase_counters[(int) phases[i]];
        c.runtime_failed_logical_gemms++;
        if (reason == FPGA_FB_DMA_RUNTIME_FAILED || reason == FPGA_FB_ILLEGAL_JOB_SUBMISSION) {
            c.dma_errors++;
        }
        if (reason == FPGA_FB_DMA_TIMEOUT) {
            c.dma_timeouts++;
        }
        update_min_max_macs(c, macs);
    }
    count_reason_for_phases(reason);
}

void fpga_stats_record_pre_submit_rejection(FpgaFallbackReason reason) {
    (void) reason;

    fpga_stats_register_atexit();
    FpgaPhase phases[2];
    const int nphases = accounting_phases(phases);
    for (int i = 0; i < nphases; ++i) {
        g_phase_counters[(int) phases[i]].pre_submit_rejections++;
    }
}

void fpga_stats_record_job_submitted(uint64_t padded_macs) {
    fpga_stats_register_atexit();

    FpgaPhase phases[2];
    const int nphases = accounting_phases(phases);
    for (int i = 0; i < nphases; ++i) {
        PhaseAuditCounters & c = g_phase_counters[(int) phases[i]];
        c.submitted_hardware_jobs++;
        c.submitted_padded_macs += (double) padded_macs;
    }
}

void fpga_stats_record_job_completed(void) {
    fpga_stats_register_atexit();

    FpgaPhase phases[2];
    const int nphases = accounting_phases(phases);
    for (int i = 0; i < nphases; ++i) {
        g_phase_counters[(int) phases[i]].completed_hardware_jobs++;
    }
}

void fpga_stats_record_job_failed(FpgaFallbackReason reason) {
    (void) reason;

    fpga_stats_register_atexit();

    FpgaPhase phases[2];
    const int nphases = accounting_phases(phases);
    for (int i = 0; i < nphases; ++i) {
        g_phase_counters[(int) phases[i]].failed_hardware_jobs++;
    }
}

void fpga_stats_record_illegal_job_submission(void) {
    fpga_stats_register_atexit();

    FpgaPhase phases[2];
    const int nphases = accounting_phases(phases);
    for (int i = 0; i < nphases; ++i) {
        g_phase_counters[(int) phases[i]].illegal_job_submissions++;
    }
}

void fpga_stats_record_reconstruction_failure(void) {
    fpga_stats_register_atexit();

    FpgaPhase phases[2];
    const int nphases = accounting_phases(phases);
    for (int i = 0; i < nphases; ++i) {
        g_phase_counters[(int) phases[i]].reconstruction_failures++;
    }
}

static std::string csv_escape(const std::string & s) {
    bool needs_quote = false;
    for (char c : s) {
        if (c == ',' || c == '"' || c == '\n' || c == '\r') {
            needs_quote = true;
            break;
        }
    }
    if (!needs_quote) {
        return s;
    }

    std::string out = "\"";
    for (char c : s) {
        if (c == '"') {
            out += "\"\"";
        } else {
            out += c;
        }
    }
    out += "\"";
    return out;
}

static std::string metric_or_na(double value, bool valid) {
    if (!valid || !std::isfinite(value)) {
        return "NA";
    }
    char buf[64];
    snprintf(buf, sizeof(buf), "%.6f", value);
    return std::string(buf);
}

static std::string u64_or_na(uint64_t value, bool valid) {
    if (!valid) {
        return "NA";
    }
    char buf[64];
    snprintf(buf, sizeof(buf), "%" PRIu64, value);
    return std::string(buf);
}

static bool reconstruction_check_performed(void) {
    return strcmp(g_reconstruction_check_mode, "off") != 0;
}

static int64_t parse_layer_id(const std::string & name) {
    const std::string marker = "blk.";
    const size_t      pos    = name.find(marker);
    if (pos == std::string::npos) {
        return -1;
    }

    const size_t start = pos + marker.size();
    size_t       end   = start;
    while (end < name.size() && name[end] >= '0' && name[end] <= '9') {
        ++end;
    }
    if (end == start) {
        return -1;
    }

    return (int64_t) strtoll(name.substr(start, end - start).c_str(), NULL, 10);
}

static std::string parse_op_group(const std::string & name, int64_t M) {
    (void) M;

    if (name.find("attn_q") != std::string::npos) {
        return "attn_q";
    }
    if (name.find("attn_k") != std::string::npos) {
        return "attn_k";
    }
    if (name.find("attn_v") != std::string::npos) {
        return "attn_v";
    }
    if (name.find("attn_output") != std::string::npos || name.find("attn_o") != std::string::npos) {
        return "attn_output";
    }
    if (name.find("ffn_gate") != std::string::npos) {
        return "ffn_gate";
    }
    if (name.find("ffn_up") != std::string::npos) {
        return "ffn_up";
    }
    if (name.find("ffn_down") != std::string::npos) {
        return "ffn_down";
    }
    if (name.find("token_embd") != std::string::npos || name.find("token_embedding") != std::string::npos) {
        return "token_embedding";
    }
    if (name.find("output.weight") != std::string::npos || name == "output") {
        return "output_projection";
    }
    return "unknown";
}

FPGA_STATS_API const char * fpga_stats_fallback_reason_name(FpgaFallbackReason reason) {
    switch (reason) {
        case FPGA_FB_UNSUPPORTED_TYPE:
        case FPGA_FB_UNSUPPORTED_QUANT_NO_DEQUANT: return "unsupported_weight_type";
        case FPGA_FB_LAYOUT: return "unsupported_layout";
        case FPGA_FB_SMALL_M: return "small_m";
        case FPGA_FB_GGML_SHAPE:
        case FPGA_FB_MAX_N:
        case FPGA_FB_SHAPE_NOT_SUPPORTED: return "shape_not_supported";
        case FPGA_FB_QUANT_ALIGN: return "alignment_failure";
        case FPGA_FB_RTL_SHAPE: return "tile_limit";
        case FPGA_FB_FEATURE_BUFFER_LIMIT: return "feature_buffer_limit";
        case FPGA_FB_B_TILE_TOO_LARGE:
        case FPGA_FB_WEIGHT_BUFFER_LIMIT:
        case FPGA_FB_CACHE_PLACEMENT_FAILED: return "weight_buffer_limit";
        case FPGA_FB_RESULT_BUFFER_LIMIT:
        case FPGA_FB_BUFFER_TOO_SMALL: return "result_buffer_limit";
        case FPGA_FB_SHIFT_TABLE_MISS:
        case FPGA_FB_INVALID_SHIFT: return "invalid_shift";
        case FPGA_FB_NOT_READY:
        case FPGA_FB_DISABLED_BY_ENV: return "unavailable_fpga_backend";
        case FPGA_FB_SCOPE_POLICY:
        case FPGA_FB_B_CACHE_DISABLED_SCRATCH:
        case FPGA_FB_B_CACHE_FULL_RECOVERED:
        case FPGA_FB_USE_REF: return "other_policy_rejection";
        case FPGA_FB_DMA_RUNTIME_FAILED:
        case FPGA_FB_ILLEGAL_JOB_SUBMISSION: return "dma_error";
        case FPGA_FB_DMA_TIMEOUT: return "timeout";
        case FPGA_FB_RECONSTRUCTION_FAILURE: return "reconstruction_failure";
        case FPGA_FB_INVALID_FPGA_RESULT: return "invalid_fpga_result";
        case FPGA_FB_INTERNAL_ERROR: return "other_runtime_failure";
        case FPGA_FB_OTHER:
        case FPGA_FB_COUNT:
        default: return "other_runtime_failure";
    }
}

double L2_compare_func(const float * cpu_output,
                       const float * fpga_output,
                       uint64_t      element_count,
                       double *      sum_diff_squared,
                       double *      sum_cpu_squared,
                       bool *        zero_cpu_nonzero_diff) {
    double diff2 = 0.0;
    double cpu2  = 0.0;
    bool   zero_cpu_nonzero = false;

    if (sum_diff_squared != NULL) {
        *sum_diff_squared = 0.0;
    }
    if (sum_cpu_squared != NULL) {
        *sum_cpu_squared = 0.0;
    }
    if (zero_cpu_nonzero_diff != NULL) {
        *zero_cpu_nonzero_diff = false;
    }

    if (cpu_output == NULL || fpga_output == NULL || element_count == 0) {
        return -1.0;
    }

    for (uint64_t i = 0; i < element_count; ++i) {
        const double cpu = (double) cpu_output[i];
        const double acc = (double) fpga_output[i];
        if (!std::isfinite(cpu) || !std::isfinite(acc)) {
            return -1.0;
        }
        const double d = acc - cpu;
        diff2 += d * d;
        cpu2 += cpu * cpu;
    }

    if (sum_diff_squared != NULL) {
        *sum_diff_squared = diff2;
    }
    if (sum_cpu_squared != NULL) {
        *sum_cpu_squared = cpu2;
    }

    if (cpu2 == 0.0) {
        if (diff2 == 0.0) {
            return 0.0;
        }
        zero_cpu_nonzero = true;
        if (zero_cpu_nonzero_diff != NULL) {
            *zero_cpu_nonzero_diff = true;
        }
        return -1.0;
    }

    const double rel = std::sqrt(diff2 / cpu2);
    if (!std::isfinite(rel)) {
        return -1.0;
    }
    return rel;
}

void fpga_stats_record_numerical_l2(uint64_t           logical_gemm_id,
                                    const char *       tensor_name,
                                    const char *       ggml_type_name,
                                    int64_t            M,
                                    int64_t            K,
                                    int64_t            N,
                                    uint64_t           hardware_jobs,
                                    double             sum_diff_squared,
                                    double             sum_cpu_squared,
                                    double             relative_l2,
                                    bool               zero_cpu_nonzero_diff,
                                    bool               valid) {
    fpga_stats_register_atexit();
    ensure_profile_config();

    const std::string tensor = tensor_name != NULL && tensor_name[0] != '\0' ? tensor_name : "";
    const std::string type   = ggml_type_name != NULL && ggml_type_name[0] != '\0' ? ggml_type_name : "unknown";

    NumericalL2Row row;
    row.logical_gemm_id = logical_gemm_id;
    row.mode = fpga_stats_runtime_mode_name(fpga_stats_get_runtime_mode());
    row.phase = fpga_stats_phase_name(fpga_stats_get_phase());
    row.tensor_name = tensor;
    row.layer_id = parse_layer_id(tensor);
    row.operator_family = parse_op_group(tensor, M);
    row.ggml_type = type;
    row.M = M;
    row.K = K;
    row.N = N;
    row.hardware_jobs = hardware_jobs;
    row.sum_diff_squared = sum_diff_squared;
    row.sum_cpu_squared = sum_cpu_squared;
    row.relative_l2 = relative_l2;
    row.zero_cpu_nonzero_diff = zero_cpu_nonzero_diff;
    row.valid = valid && std::isfinite(sum_diff_squared) && std::isfinite(sum_cpu_squared) &&
                (relative_l2 >= 0.0 && std::isfinite(relative_l2));
    g_numerical_l2_rows.push_back(row);

    NumericalAggKey key;
    key.operator_family = row.operator_family;
    key.ggml_type = row.ggml_type;
    key.M = M;
    key.K = K;
    key.N = N;

    NumericalAgg & agg = g_numerical_l2_summary[key];
    agg.calls++;
    agg.hardware_jobs += hardware_jobs;
    if (agg.min_jobs_per_gemm == 0 || hardware_jobs < agg.min_jobs_per_gemm) {
        agg.min_jobs_per_gemm = hardware_jobs;
    }
    if (hardware_jobs > agg.max_jobs_per_gemm) {
        agg.max_jobs_per_gemm = hardware_jobs;
    }
    if (row.valid) {
        agg.valid_calls++;
        agg.sum_diff_squared += sum_diff_squared;
        agg.sum_cpu_squared += sum_cpu_squared;
        if (agg.valid_calls == 1 || relative_l2 < agg.min_relative_l2) {
            agg.min_relative_l2 = relative_l2;
        }
        if (relative_l2 > agg.max_relative_l2) {
            agg.max_relative_l2 = relative_l2;
        }
    }
    if (zero_cpu_nonzero_diff) {
        agg.zero_cpu_nonzero_diff++;
    }
}

void fpga_stats_record_numerical_fallback(uint64_t           logical_gemm_id,
                                          const char *       tensor_name,
                                          const char *       ggml_type_name,
                                          int64_t            M,
                                          int64_t            K,
                                          int64_t            N,
                                          FpgaFallbackReason reason) {
    (void) logical_gemm_id;

    fpga_stats_register_atexit();
    ensure_profile_config();

    const std::string tensor = tensor_name != NULL && tensor_name[0] != '\0' ? tensor_name : "";

    NumericalFallbackKey key;
    key.phase = fpga_stats_phase_name(fpga_stats_get_phase());
    key.operator_family = parse_op_group(tensor, M);
    key.ggml_type = ggml_type_name != NULL && ggml_type_name[0] != '\0' ? ggml_type_name : "unknown";
    key.M = M;
    key.K = K;
    key.N = N;
    key.reason = fpga_stats_fallback_reason_name(reason);
    g_numerical_l2_fallback[key]++;
}

static void profile_write_outputs(bool final_write);
static void audit_write_outputs(bool final_write);
static std::string main_fallback_reason(void);

void fpga_stats_print(void) {
    if (g_printed) {
        return;
    }
    g_printed = true;
    ensure_control_config();

    const uint64_t accounted = g_offloaded_calls + g_fallback_calls;
    const PhaseAuditCounters & audit = g_phase_counters[FPGA_PHASE_OVERALL];
    const uint64_t audit_terminal = audit.cpu_only_executed_gemms + audit.policy_rejected_cpu_gemms +
                                    audit.successfully_offloaded_logical_gemms +
                                    audit.runtime_failed_logical_gemms;
    const bool logical_ok = audit.total_logical_gemms == audit_terminal;
    const bool policy_partition_ok =
        g_runtime_mode == FPGA_RUNTIME_MODE_CPU_ONLY ?
            audit.total_logical_gemms == audit.cpu_only_executed_gemms :
            audit.total_logical_gemms == audit.policy_rejected_cpu_gemms + audit.policy_eligible_logical_gemms;
    const bool eligible_partition_ok =
        g_runtime_mode == FPGA_RUNTIME_MODE_CPU_ONLY ?
            audit.policy_eligible_logical_gemms == 0 :
            audit.policy_eligible_logical_gemms ==
                audit.successfully_offloaded_logical_gemms + audit.runtime_failed_logical_gemms;
    const bool jobs_ok = audit.submitted_hardware_jobs == audit.completed_hardware_jobs + audit.failed_hardware_jobs;
    const bool illegal_ok = audit.illegal_job_submissions == 0;
    if (g_total_mul_mat_calls == 0 && accounted == 0 && audit.total_logical_gemms == 0 &&
        g_numerical_l2_rows.empty() && g_numerical_l2_fallback.empty()) {
        return;
    }

    audit_write_outputs(true);

    if (!fpga_stats_audit_enabled()) {
        profile_write_outputs(true);
        return;
    }

    const double call_ratio =
        g_total_mul_mat_calls > 0 ? 100.0 * (double) g_offloaded_calls / (double) g_total_mul_mat_calls : 0.0;

    const double mac_ratio = g_total_MACs > 0.0 ? 100.0 * g_offload_MACs / g_total_MACs : 0.0;

    printf("\n========== FPGA OFFLOAD STATS ==========\n");
    printf("Runtime mode                  : %s\n",
           fpga_stats_runtime_mode_name((FpgaRuntimeMode) g_runtime_mode));
    printf("Audit level                   : %s\n",
           g_audit_level == FPGA_AUDIT_VERBOSE ? "VERBOSE" : "SUMMARY");
    printf("Logical GEMM invariant        : %s (%" PRIu64 " == %" PRIu64 ")\n",
           logical_ok ? "PASS" : "FAIL", audit.total_logical_gemms, audit_terminal);
    printf("Policy partition invariant    : %s\n", policy_partition_ok ? "PASS" : "FAIL");
    printf("Eligible partition invariant  : %s\n", eligible_partition_ok ? "PASS" : "FAIL");
    printf("Hardware job invariant        : %s (%" PRIu64 " == %" PRIu64 " + %" PRIu64 ")\n",
           jobs_ok ? "PASS" : "FAIL", audit.submitted_hardware_jobs, audit.completed_hardware_jobs,
           audit.failed_hardware_jobs);
    printf("Illegal job submissions       : %" PRIu64 " (%s)\n",
           audit.illegal_job_submissions, illegal_ok ? "PASS" : "FAIL");
    printf("Policy eligible logical GEMMs : %" PRIu64 "\n", audit.policy_eligible_logical_gemms);
    printf("Policy rejected CPU GEMMs     : %" PRIu64 "\n", audit.policy_rejected_cpu_gemms);
    printf("CPU-only executed GEMMs       : %" PRIu64 "\n", audit.cpu_only_executed_gemms);
    printf("Offloaded logical GEMMs       : %" PRIu64 "\n", audit.successfully_offloaded_logical_gemms);
    printf("Runtime failed logical GEMMs  : %" PRIu64 "\n", audit.runtime_failed_logical_gemms);
    if (audit.successfully_offloaded_logical_gemms > 0) {
        printf("Avg jobs/successful GEMM      : %.3f\n",
               (double) audit.successful_hardware_jobs /
                   (double) audit.successfully_offloaded_logical_gemms);
        printf("Min/Max jobs/successful GEMM  : %" PRIu64 " / %" PRIu64 "\n",
               audit.min_jobs_per_gemm, audit.max_jobs_per_gemm);
    }
    printf("Submitted hardware jobs       : %" PRIu64 "\n", audit.submitted_hardware_jobs);
    printf("Completed hardware jobs       : %" PRIu64 "\n", audit.completed_hardware_jobs);
    printf("Failed hardware jobs          : %" PRIu64 "\n", audit.failed_hardware_jobs);
    printf("Pre-submit rejections         : %" PRIu64 "\n", audit.pre_submit_rejections);
    printf("DMA errors                    : %" PRIu64 "\n", audit.dma_errors);
    printf("DMA timeouts                  : %" PRIu64 "\n", audit.dma_timeouts);
    if (reconstruction_check_performed()) {
        printf("Reconstruction check          : full\n");
        printf("Reconstruction failures       : %" PRIu64 "\n", audit.reconstruction_failures);
    } else {
        printf("Reconstruction check          : OFF (not checked)\n");
        printf("Reconstruction failures       : NA\n");
    }
    if (audit.logical_macs_total > 0.0) {
        printf("Offloaded logical MAC ratio   : %.2f %%\n",
               100.0 * audit.offloaded_logical_macs / audit.logical_macs_total);
    }
    if (audit.submitted_padded_macs > 0.0 && audit.offloaded_logical_macs > 0.0) {
        printf("Padding overhead by MACs      : %.2f %%\n",
               100.0 * (audit.submitted_padded_macs - audit.offloaded_logical_macs) /
                   audit.offloaded_logical_macs);
    }
    printf("Main fallback reason          : %s\n",
           g_runtime_mode == FPGA_RUNTIME_MODE_CPU_ONLY ? "N/A" : main_fallback_reason().c_str());
    printf("\nLegacy counters:\n");
    printf("Total ggml_mul_mat calls      : %" PRIu64 "\n", g_total_mul_mat_calls);
    printf("FPGA offloaded calls          : %" PRIu64 "\n", g_offloaded_calls);
    printf("CPU fallback calls            : %" PRIu64 "\n", g_fallback_calls);
    printf("Offload ratio by calls        : %.2f %%\n", call_ratio);
    printf("Total observed MACs           : %.0f\n", g_total_MACs);
    printf("FPGA offloaded MACs           : %.0f\n", g_offload_MACs);
    printf("Offload ratio by MACs         : %.2f %%\n", mac_ratio);
    printf("Forced full-offload mode      : %s\n", g_force_full_offload ? "on" : "off");

    printf("\nBackend calls:\n");
    printf("  True HW mock                : %" PRIu64 "\n", g_backend_mock_calls);
    printf("  KV260 hardware              : %" PRIu64 "\n", g_backend_hw_calls);
    printf("  HW runtime fallback mock    : %" PRIu64 "\n", g_hw_runtime_fallback);

    printf("\nFallback reasons:\n");
    printf("  FPGA not ready              : %" PRIu64 "\n", g_fallback_reason[FPGA_FB_NOT_READY]);
    printf("  Unsupported quant type      : %" PRIu64 "\n", g_fallback_reason[FPGA_FB_UNSUPPORTED_TYPE]);
    printf("  Unsupported ggml shape      : %" PRIu64 "\n", g_fallback_reason[FPGA_FB_GGML_SHAPE]);
    printf("  RTL shape/buffer limit      : %" PRIu64 "\n", g_fallback_reason[FPGA_FB_RTL_SHAPE]);
    printf("  Quant row not aligned       : %" PRIu64 "\n", g_fallback_reason[FPGA_FB_QUANT_ALIGN]);
    printf("  Non-contiguous layout       : %" PRIu64 "\n", g_fallback_reason[FPGA_FB_LAYOUT]);
    printf("  use_ref/init/finalize       : %" PRIu64 "\n", g_fallback_reason[FPGA_FB_USE_REF]);
    printf("  Scope policy                : %" PRIu64 "\n", g_fallback_reason[FPGA_FB_SCOPE_POLICY]);
    printf("  B cache full recovered      : %" PRIu64 "\n", g_fallback_reason[FPGA_FB_B_CACHE_FULL_RECOVERED]);
    printf("  B tile too large            : %" PRIu64 "\n", g_fallback_reason[FPGA_FB_B_TILE_TOO_LARGE]);
    printf("  B cache disabled/scratch    : %" PRIu64 "\n", g_fallback_reason[FPGA_FB_B_CACHE_DISABLED_SCRATCH]);
    printf("  Cache placement failed      : %" PRIu64 "\n", g_fallback_reason[FPGA_FB_CACHE_PLACEMENT_FAILED]);
    printf("  DMA/runtime failed          : %" PRIu64 "\n", g_fallback_reason[FPGA_FB_DMA_RUNTIME_FAILED]);
    printf("  DMA timeout                 : %" PRIu64 "\n", g_fallback_reason[FPGA_FB_DMA_TIMEOUT]);
    printf("  Unsupported no dequant      : %" PRIu64 "\n", g_fallback_reason[FPGA_FB_UNSUPPORTED_QUANT_NO_DEQUANT]);
    printf("  Small M                     : %" PRIu64 "\n", g_fallback_reason[FPGA_FB_SMALL_M]);
    printf("  Max N                       : %" PRIu64 "\n", g_fallback_reason[FPGA_FB_MAX_N]);
    printf("  Shape not supported         : %" PRIu64 "\n", g_fallback_reason[FPGA_FB_SHAPE_NOT_SUPPORTED]);
    printf("  Buffer too small            : %" PRIu64 "\n", g_fallback_reason[FPGA_FB_BUFFER_TOO_SMALL]);
    printf("  Disabled by env/backend     : %" PRIu64 "\n", g_fallback_reason[FPGA_FB_DISABLED_BY_ENV]);
    printf("  Internal error              : %" PRIu64 "\n", g_fallback_reason[FPGA_FB_INTERNAL_ERROR]);
    printf("  Shift table miss            : %" PRIu64 "\n", g_fallback_reason[FPGA_FB_SHIFT_TABLE_MISS]);
    printf("  Other                       : %" PRIu64 "\n", g_fallback_reason[FPGA_FB_OTHER]);

    printf("\nPolicy fallback counters:\n");
    printf("  Small M                     : %" PRIu64 "\n", g_policy_small_m_fallback);
    printf("  Min MACs                    : %" PRIu64 "\n", g_policy_min_macs_fallback);
    printf("  Max N                       : %" PRIu64 "\n", g_policy_max_n_fallback);
    printf("  M range                     : %" PRIu64 "\n", g_policy_m_range_fallback);
    printf("  M list                      : %" PRIu64 "\n", g_policy_m_list_fallback);

    printf("\nQuant type calls:\n");
    printf("  Q5_0                        : %" PRIu64 "\n", g_quant_q5_0);
    printf("  Q6_K                        : %" PRIu64 "\n", g_quant_q6_K);
    printf("  Q8_0                        : %" PRIu64 "\n", g_quant_q8_0);
    printf("  Generic supported           : %" PRIu64 "\n", g_quant_generic);
    printf("  Unsupported                 : %" PRIu64 "\n", g_quant_unsupported);

    printf("\nPacked weight system:\n");
    printf("  B cache mode                : %s\n", g_b_cache_mode);
    printf("  B buffer limit bytes        : %" PRIu64 "\n", g_b_buffer_limit_bytes);
    printf("  B cache max used bytes      : %" PRIu64 "\n", g_b_cache_max_used_bytes);
    printf("  B cache full count          : %" PRIu64 "\n", g_b_cache_full_count);
    printf("  B cache clear count         : %" PRIu64 "\n", g_b_cache_clear_count);
    printf("  B scratch copies            : %" PRIu64 "\n", g_b_scratch_copies);
    printf("  B tile too large fallbacks  : %" PRIu64 "\n", g_b_tile_too_large_fallback_count);
    printf("  Runtime cache hit           : %" PRIu64 "\n", g_weight_cache_hit);
    printf("  Runtime cache miss          : %" PRIu64 "\n", g_weight_cache_miss);
    if (g_weight_cache_hit + g_weight_cache_miss > 0) {
        printf("  Runtime cache hit rate      : %.2f %%\n",
               100.0 * (double) g_weight_cache_hit / (double) (g_weight_cache_hit + g_weight_cache_miss));
    }
    printf("  Dump file hit               : %" PRIu64 "\n", g_weight_file_hit);
    printf("  Dump file miss/new pack     : %" PRIu64 "\n", g_weight_file_miss);
    printf("  Packed bytes from file/new  : %" PRIu64 "\n", g_weight_file_bytes);
    printf("  Weight bytes placed in DDR  : %" PRIu64 "\n", g_weight_ddr_bytes);

    printf("\nRTL INT8 output saturation:\n");
    printf("  Saturated outputs           : %" PRIu64 "\n", g_sat_count);
    printf("  Total outputs checked       : %" PRIu64 "\n", g_sat_total);
    if (g_sat_total > 0) {
        printf("  Saturation ratio            : %.4f %%\n", 100.0 * (double) g_sat_count / (double) g_sat_total);
    }

    printf("\nOffloaded shape totals:\n");
    printf("  Sum M/K/N                   : %" PRIu64 " / %" PRIu64 " / %" PRIu64 "\n", g_sum_M, g_sum_K, g_sum_N);

    printf("\nShape histogram:\n");
    printf("  M == 1 calls                : %" PRIu64 "\n", g_shape_m_eq_1);
    printf("  M == 2 calls                : %" PRIu64 "\n", g_shape_m_eq_2);
    printf("  M < 32 calls                : %" PRIu64 "\n", g_shape_m_lt_32);
    printf("  M >= 32 calls               : %" PRIu64 "\n", g_shape_m_ge_32);
    printf("  M < 32 fallbacks            : %" PRIu64 "\n", g_shape_m_lt_32_fallback);
    printf("  M >= 32 offloads            : %" PRIu64 "\n", g_shape_m_ge_32_offload);
    printf("  N tile count                : %" PRIu64 "\n", g_shape_n_tile_count);
    if (g_offloaded_calls > 0) {
        printf("  Avg tiles/offloaded call    : %.3f\n", (double) g_shape_n_tile_count / (double) g_offloaded_calls);
    }

    printf("\nExperimental FPGA paths:\n");
    printf("  K-tiling calls              : %" PRIu64 "\n", g_k_tiling_calls);
    printf("  K-tiling hardware tiles     : %" PRIu64 "\n", g_k_tiling_hw_tiles);
    printf("  Small-M pad32 calls         : %" PRIu64 "\n", g_small_m_pad_calls);
    printf("  Small-M padded rows         : %" PRIu64 "\n", g_small_m_padded_rows);
    if (g_small_m_total_rows > 0) {
        printf("  Small-M wasted ratio        : %.2f %%\n",
               100.0 * (double) g_small_m_padded_rows / (double) g_small_m_total_rows);
    }
    printf("  Shift exact count           : %" PRIu64 "\n", g_shift_exact_count);
    printf("  Shift cached count          : %" PRIu64 "\n", g_shift_cached_count);
    printf("  Shift fixed count           : %" PRIu64 "\n", g_shift_fixed_count);
    printf("  Shift table calls           : %" PRIu64 "\n", g_shift_table_calls);
    printf("  Shift table hits            : %" PRIu64 "\n", g_shift_table_hits);
    printf("  Shift table misses          : %" PRIu64 "\n", g_shift_table_misses);
    printf("  Shift table miss CPU fb     : %" PRIu64 "\n", g_shift_table_miss_cpu_fallbacks);
    printf("  Shift table miss fixed      : %" PRIu64 "\n", g_shift_table_miss_fixed);
    printf("  Shift table miss cached     : %" PRIu64 "\n", g_shift_table_miss_cached);
    printf("  Shift table miss exact      : %" PRIu64 "\n", g_shift_table_miss_exact);
    printf("  Exact shift search calls    : %" PRIu64 "\n", g_shift_exact_count);
    printf("  Cached shift calls          : %" PRIu64 "\n", g_shift_cached_count);
    printf("  Fixed shift calls           : %" PRIu64 "\n", g_shift_fixed_count);
    printf("  Shift select time ms        : %.3f ms\n", g_shift_select_time_ms);
    printf("  K-tiling saturation count   : %" PRIu64 "\n", g_k_tiling_saturation_count);
    printf("  K-tiling total outputs      : %" PRIu64 "\n", g_k_tiling_total_outputs);
    if (g_k_tiling_total_outputs > 0) {
        printf("  K-tiling saturation rate    : %.4f %%\n",
               100.0 * (double) g_k_tiling_saturation_count / (double) g_k_tiling_total_outputs);
    }
    printf("  K-tiling validation count   : %" PRIu64 "\n", g_k_tiling_validation_count);
    if (g_k_tiling_validation_count > 0) {
        printf("  K-tiling MAE                : %.6f\n", g_k_tiling_mae_sum / (double) g_k_tiling_validation_count);
        printf("  K-tiling max abs error      : %.6f\n", g_k_tiling_max_abs_error);
        printf("  K-tiling match rate         : %.6f\n",
               g_k_tiling_match_rate_sum / (double) g_k_tiling_validation_count);
    }

    printf("\nRuntime inside FPGA hook:\n");
    printf("  Total fpga_gemm_run         : %.3f ms\n", g_total_ms);
    printf("  Activation quantization     : %.3f ms\n", g_act_quant_ms);
    printf("  Weight prepare/load/cache   : %.3f ms\n", g_weight_prepare_ms);
    printf("  DMA + FPGA/mock compute     : %.3f ms\n", g_dma_fpga_ms);
    printf("  Result dequantization       : %.3f ms\n", g_result_dequant_ms);
    if (g_offloaded_calls > 0) {
        printf("  Avg fpga_gemm_run/call      : %.3f ms\n", g_total_ms / (double) g_offloaded_calls);
    }

    printf("\nDetailed FPGA timing:\n");
    printf("  Shift select                : %.3f ms\n", g_shift_select_ms);
    printf("  Feature copy/memset         : %.3f ms\n", g_feature_copy_ms);
    printf("  Result copy/output          : %.3f ms\n", g_result_copy_ms);
    printf("  Control config              : %.3f ms\n", g_ctrl_config_ms);
    printf("  DMA reset                   : %.3f ms\n", g_dma_reset_ms);
    printf("  DMA start                   : %.3f ms\n", g_dma_start_ms);
    printf("  DMA0 wait feature           : %.3f ms\n", g_dma_wait0_ms);
    printf("  DMA1 wait weight            : %.3f ms\n", g_dma_wait1_ms);
    printf("  DMA2 wait result            : %.3f ms\n", g_dma_wait2_ms);
    printf("  FPGA tile count             : %" PRIu64 "\n", g_tile_count);
    printf("  DMA reset mode              : %s\n", g_dma_reset_mode);
    printf("  DMA full reset calls        : %" PRIu64 "\n", g_dma_full_reset_calls);
    printf("  DMA status clear calls      : %" PRIu64 "\n", g_dma_status_clear_calls);
    printf("  DMA reset failures          : %" PRIu64 "\n", g_dma_reset_failures);
    printf("  DMA runtime errors          : %" PRIu64 "\n", g_dma_runtime_errors);
    printf("  DMA runtime timeouts        : %" PRIu64 "\n", g_dma_runtime_timeouts);
    if (g_tile_count > 0) {
        const double dma_wait_total_ms = g_dma_wait0_ms + g_dma_wait1_ms + g_dma_wait2_ms;
        printf("  Avg total ms/tile           : %.3f ms\n", g_total_ms / (double) g_tile_count);
        printf("  Avg DMA reset ms/tile       : %.3f ms\n", g_dma_reset_ms / (double) g_tile_count);
        printf("  Avg DMA wait total ms/tile  : %.3f ms\n", dma_wait_total_ms / (double) g_tile_count);
    }
    printf("========================================\n");
    fflush(stdout);

    profile_write_outputs(true);
}

void fpga_stats_register_atexit(void) {
    if (!g_atexit_registered) {
        atexit(fpga_stats_print);
        g_atexit_registered = true;
    }
}

void fpga_stats_count_mul_mat(int64_t M, int64_t K, int64_t N) {
    fpga_stats_register_atexit();
    g_total_mul_mat_calls++;
    g_current_logical_gemm_id = ++g_logical_gemm_id;

    if (M > 0 && K > 0 && N > 0) {
        g_total_MACs += (double) M * (double) K * (double) N;
    }

    FpgaPhase phases[2];
    const int nphases = accounting_phases(phases);
    for (int i = 0; i < nphases; ++i) {
        g_phase_counters[(int) phases[i]].total_logical_gemms++;
    }
}

void fpga_stats_count_offload(FpgaQuantType quant, int64_t M, int64_t K, int64_t N) {
    fpga_stats_register_atexit();
    g_offloaded_calls++;

    if (M > 0) {
        g_sum_M += (uint64_t) M;
    }
    if (K > 0) {
        g_sum_K += (uint64_t) K;
    }
    if (N > 0) {
        g_sum_N += (uint64_t) N;
    }

    if (M > 0 && K > 0 && N > 0) {
        g_offload_MACs += (double) M * (double) K * (double) N;
    }

    (void) quant;
}

void fpga_stats_count_fallback(FpgaFallbackReason reason, int64_t M, int64_t K, int64_t N, int type) {
    (void) M;
    (void) K;
    (void) N;
    (void) type;

    fpga_stats_register_atexit();
    g_fallback_calls++;

    if ((int) reason < 0 || (int) reason >= FPGA_FB_COUNT) {
        reason = FPGA_FB_OTHER;
    }

    g_fallback_reason[(int) reason]++;
}

void fpga_stats_count_quant_type(bool supported, FpgaQuantType quant) {
    fpga_stats_register_atexit();

    if (!supported) {
        g_quant_unsupported++;
        return;
    }

    if (quant == FPGA_QUANT_Q5_0) {
        g_quant_q5_0++;
    } else if (quant == FPGA_QUANT_Q6_K) {
        g_quant_q6_K++;
    } else if (quant == FPGA_QUANT_Q8_0) {
        g_quant_q8_0++;
    } else {
        g_quant_generic++;
    }
}

void fpga_stats_set_force_full_offload(bool enabled) {
    fpga_stats_register_atexit();
    g_force_full_offload = enabled;
}

void fpga_stats_count_small_m_fallback(void) {
    fpga_stats_register_atexit();
    g_policy_small_m_fallback++;
}

void fpga_stats_count_min_macs_fallback(void) {
    fpga_stats_register_atexit();
    g_policy_min_macs_fallback++;
}

void fpga_stats_count_max_n_fallback(void) {
    fpga_stats_register_atexit();
    g_policy_max_n_fallback++;
}

void fpga_stats_count_m_range_fallback(void) {
    fpga_stats_register_atexit();
    g_policy_m_range_fallback++;
}

void fpga_stats_count_m_list_fallback(void) {
    fpga_stats_register_atexit();
    g_policy_m_list_fallback++;
}

void fpga_stats_count_k_tiling_call(uint64_t hardware_tiles) {
    fpga_stats_register_atexit();
    g_k_tiling_calls++;
    g_k_tiling_hw_tiles += hardware_tiles;
}

void fpga_stats_count_small_m_pad(uint64_t M, uint64_t M_hw) {
    fpga_stats_register_atexit();
    g_small_m_pad_calls++;
    if (M_hw > M) {
        g_small_m_padded_rows += M_hw - M;
    }
    g_small_m_total_rows += M_hw;
}

void fpga_stats_count_shift_exact(void) {
    fpga_stats_register_atexit();
    g_shift_exact_count++;
}

void fpga_stats_count_shift_cached(void) {
    fpga_stats_register_atexit();
    g_shift_cached_count++;
}

void fpga_stats_count_shift_fixed(void) {
    fpga_stats_register_atexit();
    g_shift_fixed_count++;
}

void fpga_stats_count_shift_table_call(void) {
    fpga_stats_register_atexit();
    g_shift_table_calls++;
}

void fpga_stats_count_shift_table_hit(void) {
    fpga_stats_register_atexit();
    g_shift_table_hits++;
}

void fpga_stats_count_shift_table_miss(void) {
    fpga_stats_register_atexit();
    g_shift_table_misses++;
}

void fpga_stats_count_shift_table_miss_cpu_fallback(void) {
    fpga_stats_register_atexit();
    g_shift_table_miss_cpu_fallbacks++;
}

void fpga_stats_count_shift_table_miss_fixed(void) {
    fpga_stats_register_atexit();
    g_shift_table_miss_fixed++;
}

void fpga_stats_count_shift_table_miss_cached(void) {
    fpga_stats_register_atexit();
    g_shift_table_miss_cached++;
}

void fpga_stats_count_shift_table_miss_exact(void) {
    fpga_stats_register_atexit();
    g_shift_table_miss_exact++;
}

void fpga_stats_add_shift_select_time(double ms) {
    fpga_stats_register_atexit();
    g_shift_select_time_ms += ms;
}

void fpga_stats_count_shape(int64_t M, int64_t K, int64_t N) {
    (void) K;
    (void) N;

    fpga_stats_register_atexit();

    if (M == 1) {
        g_shape_m_eq_1++;
    }
    if (M == 2) {
        g_shape_m_eq_2++;
    }
    if (M < 32) {
        g_shape_m_lt_32++;
    } else {
        g_shape_m_ge_32++;
    }
}

void fpga_stats_count_shape_offload(int64_t M, int64_t K, int64_t N, uint64_t tiles) {
    (void) K;
    (void) N;

    fpga_stats_register_atexit();

    if (M >= 32) {
        g_shape_m_ge_32_offload++;
    }
    g_shape_n_tile_count += tiles;
}

void fpga_stats_count_shape_fallback(int64_t M, int64_t K, int64_t N) {
    (void) K;
    (void) N;

    fpga_stats_register_atexit();

    if (M < 32) {
        g_shape_m_lt_32_fallback++;
    }
}

void fpga_stats_count_k_tiling_saturation(uint64_t saturated, uint64_t total) {
    fpga_stats_register_atexit();
    g_k_tiling_saturation_count += saturated;
    g_k_tiling_total_outputs += total;
}

void fpga_stats_count_weight_cache_hit(void) {
    fpga_stats_register_atexit();
    g_weight_cache_hit++;
}

void fpga_stats_count_weight_cache_miss(void) {
    fpga_stats_register_atexit();
    g_weight_cache_miss++;
}

void fpga_stats_count_weight_file_hit(void) {
    fpga_stats_register_atexit();
    g_weight_file_hit++;
}

void fpga_stats_count_weight_file_miss(void) {
    fpga_stats_register_atexit();
    g_weight_file_miss++;
}

void fpga_stats_add_weight_file_bytes(uint64_t bytes) {
    fpga_stats_register_atexit();
    g_weight_file_bytes += bytes;
}

void fpga_stats_add_weight_ddr_bytes(uint64_t bytes) {
    fpga_stats_register_atexit();
    g_weight_ddr_bytes += bytes;
}

void fpga_stats_set_b_cache_mode(const char * mode) {
    fpga_stats_register_atexit();

    if (mode == NULL || mode[0] == '\0') {
        mode = "persistent";
    }

    snprintf(g_b_cache_mode, sizeof(g_b_cache_mode), "%s", mode);
}

void fpga_stats_set_b_buffer_limit_bytes(uint64_t bytes) {
    fpga_stats_register_atexit();
    g_b_buffer_limit_bytes = bytes;
}

void fpga_stats_update_b_cache_used_bytes(uint64_t bytes) {
    fpga_stats_register_atexit();
    if (bytes > g_b_cache_max_used_bytes) {
        g_b_cache_max_used_bytes = bytes;
    }
}

void fpga_stats_count_b_cache_full(void) {
    fpga_stats_register_atexit();
    g_b_cache_full_count++;
}

void fpga_stats_count_b_cache_clear(void) {
    fpga_stats_register_atexit();
    g_b_cache_clear_count++;
}

void fpga_stats_count_b_scratch_copy(void) {
    fpga_stats_register_atexit();
    g_b_scratch_copies++;
}

void fpga_stats_count_b_tile_too_large_fallback(void) {
    fpga_stats_register_atexit();
    g_b_tile_too_large_fallback_count++;
}

void fpga_stats_set_dma_reset_mode(const char * mode) {
    fpga_stats_register_atexit();

    if (mode == NULL || mode[0] == '\0') {
        mode = "each_tile";
    }

    snprintf(g_dma_reset_mode, sizeof(g_dma_reset_mode), "%s", mode);
}

void fpga_stats_set_reconstruction_check_mode(const char * mode) {
    fpga_stats_register_atexit();

    if (mode == NULL || mode[0] == '\0') {
        mode = "full";
    }

    if (strcmp(mode, "off") != 0) {
        mode = "full";
    }

    snprintf(g_reconstruction_check_mode, sizeof(g_reconstruction_check_mode), "%s", mode);
}

void fpga_stats_count_dma_full_reset_call(void) {
    fpga_stats_register_atexit();
    g_dma_full_reset_calls++;
}

void fpga_stats_count_dma_status_clear_call(void) {
    fpga_stats_register_atexit();
    g_dma_status_clear_calls++;
}

void fpga_stats_count_dma_reset_failure(void) {
    fpga_stats_register_atexit();
    g_dma_reset_failures++;
}

void fpga_stats_count_dma_runtime_error(void) {
    fpga_stats_register_atexit();
    g_dma_runtime_errors++;
}

void fpga_stats_count_dma_runtime_timeout(void) {
    fpga_stats_register_atexit();
    g_dma_runtime_timeouts++;
}

void fpga_stats_set_last_runtime_fallback_reason(FpgaFallbackReason reason) {
    if ((int) reason < 0 || (int) reason >= FPGA_FB_COUNT) {
        reason = FPGA_FB_OTHER;
    }
    g_last_runtime_fallback_reason = reason;
}

FpgaFallbackReason fpga_stats_get_last_runtime_fallback_reason(void) {
    if ((int) g_last_runtime_fallback_reason < 0 || (int) g_last_runtime_fallback_reason >= FPGA_FB_COUNT) {
        return FPGA_FB_OTHER;
    }
    return g_last_runtime_fallback_reason;
}

void fpga_stats_count_backend_mock(void) {
    fpga_stats_register_atexit();
    g_backend_mock_calls++;
}

void fpga_stats_count_backend_hw(void) {
    fpga_stats_register_atexit();
    g_backend_hw_calls++;
}

void fpga_stats_count_hw_runtime_fallback(void) {
    fpga_stats_register_atexit();
    g_hw_runtime_fallback++;
}

void fpga_stats_count_saturation(uint64_t saturated, uint64_t total) {
    fpga_stats_register_atexit();
    g_sat_count += saturated;
    g_sat_total += total;
}

void fpga_stats_add_runtime(double total_ms,
                            double act_quant_ms,
                            double weight_prepare_ms,
                            double dma_fpga_ms,
                            double result_dequant_ms) {
    fpga_stats_register_atexit();
    g_total_ms += total_ms;
    g_act_quant_ms += act_quant_ms;
    g_weight_prepare_ms += weight_prepare_ms;
    g_dma_fpga_ms += dma_fpga_ms;
    g_result_dequant_ms += result_dequant_ms;
}

void fpga_stats_add_runtime_detail(double shift_select_ms,
                                   double feature_copy_ms,
                                   double result_copy_ms,
                                   double ctrl_config_ms,
                                   double dma_reset_ms,
                                   double dma_start_ms,
                                   double dma_wait0_ms,
                                   double dma_wait1_ms,
                                   double dma_wait2_ms,
                                   uint64_t tile_count) {
    fpga_stats_register_atexit();
    g_shift_select_ms += shift_select_ms;
    g_feature_copy_ms += feature_copy_ms;
    g_result_copy_ms += result_copy_ms;
    g_ctrl_config_ms += ctrl_config_ms;
    g_dma_reset_ms += dma_reset_ms;
    g_dma_start_ms += dma_start_ms;
    g_dma_wait0_ms += dma_wait0_ms;
    g_dma_wait1_ms += dma_wait1_ms;
    g_dma_wait2_ms += dma_wait2_ms;
    g_tile_count += tile_count;
}

bool fpga_profile_enabled(void) {
    ensure_profile_config();
    return g_profile.enabled;
}

bool fpga_profile_compare_enabled(void) {
    ensure_profile_config();
    return (g_profile.enabled && g_profile.compare) || g_runtime_mode == FPGA_RUNTIME_MODE_COMPARE;
}

double fpga_profile_compare_tol(void) {
    return env_double("FPGA_COMPARE_TOL", 1.0);
}

uint64_t fpga_profile_compare_max_elements(void) {
    return env_u64("FPGA_COMPARE_MAX_ELEMENTS", 0);
}

uint64_t fpga_stats_get_weight_cache_hit_count(void) {
    return g_weight_cache_hit;
}

uint64_t fpga_stats_get_weight_cache_miss_count(void) {
    return g_weight_cache_miss;
}

uint64_t fpga_stats_get_dma_runtime_error_count(void) {
    return g_dma_runtime_errors;
}

uint64_t fpga_stats_get_dma_runtime_timeout_count(void) {
    return g_dma_runtime_timeouts;
}

uint64_t fpga_stats_get_tile_count(void) {
    return g_tile_count;
}

uint64_t fpga_stats_get_shift_table_hit_count(void) {
    return g_shift_table_hits;
}

uint64_t fpga_stats_get_shift_table_miss_count(void) {
    return g_shift_table_misses;
}

uint64_t fpga_stats_get_k_tiling_saturation_count(void) {
    return g_k_tiling_saturation_count;
}

uint64_t fpga_stats_get_k_tiling_total_output_count(void) {
    return g_k_tiling_total_outputs;
}

void fpga_stats_record_k_tiling_validation(const char *       tensor_name,
                                           const char *       qtype,
                                           int64_t            M,
                                           int64_t            K,
                                           int64_t            N,
                                           uint64_t           num_k_tiles,
                                           uint64_t           num_hw_tiles,
                                           const char *       shift_mode,
                                           uint64_t           shift_table_hits,
                                           uint64_t           shift_table_misses,
                                           double             max_abs_error,
                                           double             mae,
                                           uint64_t           mismatch_count,
                                           uint64_t           compared_count,
                                           uint64_t           saturation_count,
                                           uint64_t           saturation_total,
                                           bool               used_fpga,
                                           FpgaFallbackReason fallback_reason) {
    ensure_profile_config();
    if (!g_profile.enabled) {
        return;
    }

    KTilingValidationRow row;
    row.tensor_name = tensor_name != NULL ? tensor_name : "";
    row.layer_id = parse_layer_id(row.tensor_name);
    row.op_group = parse_op_group(row.tensor_name, M);
    row.qtype = qtype != NULL ? qtype : "unknown";
    row.M = M;
    row.K = K;
    row.N = N;
    row.num_k_tiles = num_k_tiles;
    row.num_hw_tiles = num_hw_tiles;
    row.shift_mode = shift_mode != NULL ? shift_mode : "unknown";
    row.shift_table_hits = shift_table_hits;
    row.shift_table_misses = shift_table_misses;
    row.max_abs_error = max_abs_error;
    row.mae = mae;
    row.mismatch_count = mismatch_count;
    row.compared_count = compared_count;
    row.saturation_count = saturation_count;
    row.saturation_total = saturation_total;
    row.used_fpga = used_fpga;
    row.fallback_reason = used_fpga ? "none" : fpga_stats_fallback_reason_name(fallback_reason);
    g_k_tiling_validation_rows.push_back(row);

    if (compared_count > 0 && max_abs_error >= 0.0 && mae >= 0.0) {
        const double match_rate = (double) (compared_count - mismatch_count) / (double) compared_count;
        g_k_tiling_mae_sum += mae;
        g_k_tiling_max_abs_error = std::max(g_k_tiling_max_abs_error, max_abs_error);
        g_k_tiling_match_rate_sum += match_rate;
        g_k_tiling_validation_count++;
    }
}

void fpga_stats_record_matmul_profile(const char *       tensor_name,
                                      const char *       src0_name,
                                      const char *       src1_name,
                                      const char *       ggml_type_name,
                                      int                ggml_type,
                                      int64_t            M,
                                      int64_t            K,
                                      int64_t            N,
                                      bool               used_fpga,
                                      FpgaFallbackReason reason,
                                      uint64_t           tile_count,
                                      double             cpu_latency_ms,
                                      double             fpga_latency_ms,
                                      uint64_t           weight_cache_hits,
                                      uint64_t           weight_cache_misses,
                                      uint64_t           dma_runtime_errors,
                                      uint64_t           dma_runtime_timeouts,
                                      double             max_abs_error,
                                      double             mae,
                                      uint64_t           mismatch_count,
                                      uint64_t           compared_count) {
    (void) ggml_type;

    ensure_profile_config();
    if (!g_profile.enabled) {
        return;
    }

    fpga_stats_register_atexit();

    const std::string tensor = tensor_name != NULL && tensor_name[0] != '\0' ? tensor_name :
                               (src0_name != NULL ? src0_name : "");

    ProfileKey key;
    key.layer_id        = parse_layer_id(tensor);
    key.op_group        = parse_op_group(tensor, M);
    key.tensor_name     = tensor;
    key.src0_name       = src0_name != NULL ? src0_name : "";
    key.src1_name       = src1_name != NULL ? src1_name : "";
    key.ggml_type       = ggml_type_name != NULL ? ggml_type_name : "unknown";
    key.M               = M;
    key.K               = K;
    key.N               = N;
    key.decision        = used_fpga ? "fpga" : "cpu";
    key.fallback_reason = used_fpga ? "none" : fpga_stats_fallback_reason_name(reason);

    ProfileAgg & agg = g_profile_ops[key];
    if (agg.calls == 0) {
        agg.key = key;
    }

    const double macs = (M > 0 && K > 0 && N > 0) ? (double) M * (double) K * (double) N : 0.0;
    agg.calls++;
    agg.macs_total += macs;

    if (used_fpga) {
        agg.fpga_calls++;
        agg.fpga_tile_count += tile_count;
        if (fpga_latency_ms >= 0.0) {
            agg.fpga_latency_ms_total += fpga_latency_ms;
            agg.has_fpga_latency = true;
        }
    } else {
        agg.cpu_fallback_calls++;
        if (cpu_latency_ms >= 0.0) {
            agg.cpu_latency_ms_total += cpu_latency_ms;
            agg.has_cpu_latency = true;
        }
    }

    if (reason == FPGA_FB_SMALL_M || key.fallback_reason == "small_m") {
        agg.small_m_count++;
    }
    if (reason == FPGA_FB_MAX_N || key.fallback_reason == "shape_not_supported") {
        agg.max_n_count++;
    }
    if (reason == FPGA_FB_UNSUPPORTED_TYPE || reason == FPGA_FB_UNSUPPORTED_QUANT_NO_DEQUANT ||
        key.fallback_reason == "unsupported_weight_type") {
        agg.unsupported_quant_count++;
    }
    if (reason == FPGA_FB_DMA_RUNTIME_FAILED || key.fallback_reason == "dma_error") {
        agg.dma_failed_count++;
    }
    if (reason == FPGA_FB_DMA_TIMEOUT || key.fallback_reason == "timeout") {
        agg.dma_timeout_count++;
    }

    agg.weight_cache_hit_count += weight_cache_hits;
    agg.weight_cache_miss_count += weight_cache_misses;
    agg.dma_failed_count += dma_runtime_errors;
    agg.dma_timeout_count += dma_runtime_timeouts;

    if (compared_count > 0 && max_abs_error >= 0.0 && mae >= 0.0) {
        agg.max_abs_error_sum += max_abs_error;
        agg.max_abs_error_max = std::max(agg.max_abs_error_max, max_abs_error);
        agg.mae_sum += mae;
        agg.compare_calls++;
        agg.mismatch_count += mismatch_count;
        agg.compared_count += compared_count;
    }

    ShapeAgg & shape = g_profile_shapes[std::make_tuple(M, K, N)];
    shape.calls++;
    shape.macs_total += macs;
    shape.tile_count += tile_count;
    if (used_fpga) {
        shape.fpga_calls++;
        if (fpga_latency_ms >= 0.0) {
            shape.fpga_ms += fpga_latency_ms;
        }
    } else {
        shape.cpu_calls++;
    }

    g_profile_record_count++;
    if (g_profile.verbose) {
        fprintf(stderr,
                "[FPGA][profile] tensor=%s type=%s M=%" PRId64 " K=%" PRId64 " N=%" PRId64
                " decision=%s reason=%s\n",
                key.tensor_name.c_str(), key.ggml_type.c_str(), M, K, N, key.decision.c_str(),
                key.fallback_reason.c_str());
    }

    if (g_profile.flush_every_n > 0 && (g_profile_record_count % g_profile.flush_every_n) == 0) {
        profile_write_outputs(false);
    }
}

static std::string full_shape(const ProfileKey & key) {
    char buf[96];
    snprintf(buf, sizeof(buf), "%" PRId64 "x%" PRId64 "x%" PRId64, key.M, key.K, key.N);
    return std::string(buf);
}

static std::string phase_for_m(int64_t M) {
    return M >= 32 ? "prefill_like" : "decode_like";
}

static double elapsed_seconds(void) {
    ensure_profile_config();
    const auto now = std::chrono::steady_clock::now();
    const double sec = std::chrono::duration<double>(now - g_profile.start_time).count();
    return sec > 0.0 ? sec : 0.0;
}

static void write_profile_ops_csv(void) {
    std::ofstream os(profile_path("fpga_profile_ops.csv").c_str());
    if (!os.good()) {
        return;
    }

    os << "run_id,phase,layer_id,op_group,tensor_name,src0_name,src1_name,ggml_type,M,K,N,full_shape,calls,"
          "macs_total,decision,fallback_reason,fpga_calls,cpu_fallback_calls,fpga_tile_count,cpu_latency_ms_total,"
          "fpga_latency_ms_total,avg_cpu_latency_ms,avg_fpga_latency_ms,gops,speedup,small_m_count,max_n_count,"
          "unsupported_quant_count,dma_failed_count,dma_timeout_count,weight_cache_hit_count,weight_cache_miss_count,"
          "max_abs_error,mae,mismatch_count,match_rate\n";

    for (const auto & it : g_profile_ops) {
        const ProfileAgg & a = it.second;
        const ProfileKey & k = a.key;
        const double avg_cpu = a.cpu_fallback_calls > 0 ? a.cpu_latency_ms_total / (double) a.cpu_fallback_calls : 0.0;
        const double avg_fpga = a.fpga_calls > 0 ? a.fpga_latency_ms_total / (double) a.fpga_calls : 0.0;
        const double gops = a.has_fpga_latency && a.fpga_latency_ms_total > 0.0 ?
            (a.macs_total / 1.0e9) / (a.fpga_latency_ms_total / 1000.0) : 0.0;
        const bool speedup_valid = a.has_cpu_latency && a.has_fpga_latency && a.fpga_latency_ms_total > 0.0;
        const double speedup = speedup_valid ? a.cpu_latency_ms_total / a.fpga_latency_ms_total : 0.0;
        const bool compare_valid = a.compare_calls > 0 && a.compared_count > 0;
        const double mae_avg = compare_valid ? a.mae_sum / (double) a.compare_calls : 0.0;
        const double match_rate = compare_valid ?
            (double) (a.compared_count - a.mismatch_count) / (double) a.compared_count : 0.0;

        os << csv_escape(g_profile.run_id) << ','
           << phase_for_m(k.M) << ','
           << k.layer_id << ','
           << csv_escape(k.op_group) << ','
           << csv_escape(k.tensor_name) << ','
           << csv_escape(k.src0_name) << ','
           << csv_escape(k.src1_name) << ','
           << csv_escape(k.ggml_type) << ','
           << k.M << ',' << k.K << ',' << k.N << ','
           << full_shape(k) << ','
           << a.calls << ','
           << (uint64_t) a.macs_total << ','
           << k.decision << ','
           << k.fallback_reason << ','
           << a.fpga_calls << ','
           << a.cpu_fallback_calls << ','
           << a.fpga_tile_count << ','
           << metric_or_na(a.cpu_latency_ms_total, a.has_cpu_latency) << ','
           << metric_or_na(a.fpga_latency_ms_total, a.has_fpga_latency) << ','
           << metric_or_na(avg_cpu, a.has_cpu_latency && a.cpu_fallback_calls > 0) << ','
           << metric_or_na(avg_fpga, a.has_fpga_latency && a.fpga_calls > 0) << ','
           << metric_or_na(gops, a.has_fpga_latency && a.fpga_latency_ms_total > 0.0) << ','
           << metric_or_na(speedup, speedup_valid) << ','
           << a.small_m_count << ','
           << a.max_n_count << ','
           << a.unsupported_quant_count << ','
           << a.dma_failed_count << ','
           << a.dma_timeout_count << ','
           << a.weight_cache_hit_count << ','
           << a.weight_cache_miss_count << ','
           << metric_or_na(a.max_abs_error_max, compare_valid) << ','
           << metric_or_na(mae_avg, compare_valid) << ','
           << u64_or_na(a.mismatch_count, compare_valid) << ','
           << metric_or_na(match_rate, compare_valid) << '\n';
    }
}

static void write_profile_summary_tsv(void) {
    std::ofstream os(profile_path("fpga_profile_summary.tsv").c_str());
    if (!os.good()) {
        return;
    }

    os << "run_id\tlayer_id\top_group\tggml_type\tM\tK\tN\tcalls\tfpga_calls\tcpu_fallback_calls\tmacs_total\t"
          "fpga_latency_ms_total\tmain_fallback_reason\n";
    for (const auto & it : g_profile_ops) {
        const ProfileAgg & a = it.second;
        const ProfileKey & k = a.key;
        os << g_profile.run_id << '\t'
           << k.layer_id << '\t'
           << k.op_group << '\t'
           << k.ggml_type << '\t'
           << k.M << '\t' << k.K << '\t' << k.N << '\t'
           << a.calls << '\t'
           << a.fpga_calls << '\t'
           << a.cpu_fallback_calls << '\t'
           << (uint64_t) a.macs_total << '\t'
           << metric_or_na(a.fpga_latency_ms_total, a.has_fpga_latency) << '\t'
           << k.fallback_reason << '\n';
    }
}

static void write_shape_hist_csv(void) {
    std::ofstream os(profile_path("fpga_shape_hist.csv").c_str());
    if (!os.good()) {
        return;
    }

    os << "run_id,M,K,N,full_shape,calls,fpga_calls,cpu_calls,macs_total,tile_count,fpga_latency_ms_total\n";
    for (const auto & it : g_profile_shapes) {
        int64_t M = 0;
        int64_t K = 0;
        int64_t N = 0;
        std::tie(M, K, N) = it.first;
        const ShapeAgg & a = it.second;
        os << g_profile.run_id << ','
           << M << ',' << K << ',' << N << ','
           << M << 'x' << K << 'x' << N << ','
           << a.calls << ','
           << a.fpga_calls << ','
           << a.cpu_calls << ','
           << (uint64_t) a.macs_total << ','
           << a.tile_count << ','
           << metric_or_na(a.fpga_ms, a.fpga_ms > 0.0) << '\n';
    }
}

static void write_fallback_detail_csv(void) {
    std::ofstream os(profile_path("fpga_fallback_detail.csv").c_str());
    if (!os.good()) {
        return;
    }

    os << "run_id,layer_id,op_group,tensor_name,ggml_type,M,K,N,fallback_reason,calls,macs_total\n";
    for (const auto & it : g_profile_ops) {
        const ProfileAgg & a = it.second;
        const ProfileKey & k = a.key;
        if (k.fallback_reason == "none") {
            continue;
        }
        os << csv_escape(g_profile.run_id) << ','
           << k.layer_id << ','
           << csv_escape(k.op_group) << ','
           << csv_escape(k.tensor_name) << ','
           << csv_escape(k.ggml_type) << ','
           << k.M << ',' << k.K << ',' << k.N << ','
           << k.fallback_reason << ','
           << a.calls << ','
           << (uint64_t) a.macs_total << '\n';
    }
}

static void write_k_tiling_validation_tsv(void) {
    std::ofstream os(profile_path("k_tiling_validation.tsv").c_str(), std::ios::app);
    if (!os.good()) {
        return;
    }

    const bool empty_file = os.tellp() == std::streampos(0);
    if (empty_file) {
        os << "tensor_name\tlayer_id\top_group\tqtype\tM\tK\tN\tnum_k_tiles\tnum_hw_tiles\tshift_mode\t"
              "shift_table_hits\tshift_table_misses\tmax_abs_error\tmae\tmismatch_count\tcompared_count\t"
              "match_rate\tsaturation_count\tsaturation_rate\tused_fpga\tfallback_reason\n";
    }

    for (const KTilingValidationRow & r : g_k_tiling_validation_rows) {
        const bool compare_valid = r.compared_count > 0 && r.max_abs_error >= 0.0 && r.mae >= 0.0;
        const double match_rate = compare_valid ?
            (double) (r.compared_count - r.mismatch_count) / (double) r.compared_count : 0.0;
        const bool sat_valid = r.saturation_total > 0;
        const double sat_rate = sat_valid ? (double) r.saturation_count / (double) r.saturation_total : 0.0;

        os << r.tensor_name << '\t'
           << r.layer_id << '\t'
           << r.op_group << '\t'
           << r.qtype << '\t'
           << r.M << '\t' << r.K << '\t' << r.N << '\t'
           << r.num_k_tiles << '\t'
           << r.num_hw_tiles << '\t'
           << r.shift_mode << '\t'
           << r.shift_table_hits << '\t'
           << r.shift_table_misses << '\t'
           << metric_or_na(r.max_abs_error, compare_valid) << '\t'
           << metric_or_na(r.mae, compare_valid) << '\t'
           << u64_or_na(r.mismatch_count, compare_valid) << '\t'
           << u64_or_na(r.compared_count, compare_valid) << '\t'
           << metric_or_na(match_rate, compare_valid) << '\t'
           << r.saturation_count << '\t'
           << metric_or_na(sat_rate, sat_valid) << '\t'
           << (r.used_fpga ? "1" : "0") << '\t'
           << r.fallback_reason << '\n';
    }

    g_k_tiling_validation_rows.clear();
}

static void write_paper_kernel_shape_table(void) {
    std::ofstream os(profile_path("paper_kernel_shape_table.tsv").c_str());
    if (!os.good()) {
        return;
    }

    os << "Kernel / Shape group\tM\tK\tN\tFull shape MxKxN\tCPU latency\tFPGA latency\tGOPS\tMaxAbsError\tMAE\t"
          "Mismatch count\tMatch Rate\tSpeedup\n";
    for (const auto & it : g_profile_ops) {
        const ProfileAgg & a = it.second;
        const ProfileKey & k = a.key;
        const double gops = a.has_fpga_latency && a.fpga_latency_ms_total > 0.0 ?
            (a.macs_total / 1.0e9) / (a.fpga_latency_ms_total / 1000.0) : 0.0;
        const bool speedup_valid = a.has_cpu_latency && a.has_fpga_latency && a.fpga_latency_ms_total > 0.0;
        const double speedup = speedup_valid ? a.cpu_latency_ms_total / a.fpga_latency_ms_total : 0.0;
        const bool compare_valid = a.compare_calls > 0 && a.compared_count > 0;
        const double mae_avg = compare_valid ? a.mae_sum / (double) a.compare_calls : 0.0;
        const double match_rate = compare_valid ?
            (double) (a.compared_count - a.mismatch_count) / (double) a.compared_count : 0.0;

        os << k.op_group << '\t'
           << k.M << '\t' << k.K << '\t' << k.N << '\t'
           << full_shape(k) << '\t'
           << metric_or_na(a.cpu_latency_ms_total, a.has_cpu_latency) << '\t'
           << metric_or_na(a.fpga_latency_ms_total, a.has_fpga_latency) << '\t'
           << metric_or_na(gops, a.has_fpga_latency && a.fpga_latency_ms_total > 0.0) << '\t'
           << metric_or_na(a.max_abs_error_max, compare_valid) << '\t'
           << metric_or_na(mae_avg, compare_valid) << '\t'
           << u64_or_na(a.mismatch_count, compare_valid) << '\t'
           << metric_or_na(match_rate, compare_valid) << '\t'
           << metric_or_na(speedup, speedup_valid) << '\n';
    }
}

static std::string main_fallback_reason(void) {
    uint64_t best = 0;
    FpgaFallbackReason best_reason = FPGA_FB_OTHER;
    for (int i = 0; i < FPGA_FB_COUNT; ++i) {
        if (g_fallback_reason[i] > best) {
            best = g_fallback_reason[i];
            best_reason = (FpgaFallbackReason) i;
        }
    }
    return fpga_stats_fallback_reason_name(best_reason);
}

static void write_paper_offload_summary(void) {
    std::ofstream os(profile_path("paper_offload_summary.tsv").c_str());
    if (!os.good()) {
        return;
    }

    const double call_ratio =
        g_total_mul_mat_calls > 0 ? 100.0 * (double) g_offloaded_calls / (double) g_total_mul_mat_calls : 0.0;
    const double mac_ratio = g_total_MACs > 0.0 ? 100.0 * g_offload_MACs / g_total_MACs : 0.0;

    os << "FPGA offloaded calls\tOffload ratio by calls\tOffload ratio by MACs\tSmall M fallback\t"
          "Total fpga_gemm_run\tAvg fpga_gemm_run/call\tDMA reset time\tDMA runtime errors\tDMA runtime timeouts\n";
    os << g_offloaded_calls << '\t'
       << call_ratio << '\t'
       << mac_ratio << '\t'
       << g_policy_small_m_fallback << '\t'
       << g_total_ms << '\t'
       << metric_or_na(g_offloaded_calls > 0 ? g_total_ms / (double) g_offloaded_calls : 0.0, g_offloaded_calls > 0) << '\t'
       << g_dma_reset_ms << '\t'
       << g_dma_runtime_errors << '\t'
       << g_dma_runtime_timeouts << '\n';
}

static void write_paper_end_to_end(void) {
    std::ofstream os(profile_path("paper_end_to_end_table.tsv").c_str());
    if (!os.good()) {
        return;
    }

    const double sec = elapsed_seconds();
    const double fpga_call_rate = sec > 0.0 ? (double) g_offloaded_calls / sec : 0.0;
    const double hw_call_rate   = sec > 0.0 ? (double) g_backend_hw_calls / sec : 0.0;

    os << "Mode\tPrompt processing tokens/s\tDecode tokens/s\tFirst-token latency ms\tEnd-to-end latency s\t"
          "End-to-end speedup\tFPGA call rate\tKV260 hardware call rate\n";
    os << "profiled_run\tNA\tNA\tNA\tNA\tNA\t"
       << metric_or_na(fpga_call_rate, sec > 0.0) << '\t'
       << metric_or_na(hw_call_rate, sec > 0.0) << '\n';
}

static void write_paper_matmul_summary(void) {
    std::ofstream os(profile_path("paper_matmul_summary.tsv").c_str());
    if (!os.good()) {
        return;
    }

    const double call_ratio =
        g_total_mul_mat_calls > 0 ? 100.0 * (double) g_offloaded_calls / (double) g_total_mul_mat_calls : 0.0;
    const bool cache_valid = (g_weight_cache_hit + g_weight_cache_miss) > 0;
    const double cache_hit_rate = cache_valid ?
        100.0 * (double) g_weight_cache_hit / (double) (g_weight_cache_hit + g_weight_cache_miss) : 0.0;

    os << "Total matmul calls\tFPGA offloaded\tCPU fallback\tOffload ratio\tMain fallback reason\tWeight cache hit rate\n";
    os << g_total_mul_mat_calls << '\t'
       << g_offloaded_calls << '\t'
       << g_fallback_calls << '\t'
       << call_ratio << '\t'
       << main_fallback_reason() << '\t'
       << metric_or_na(cache_hit_rate, cache_valid) << '\n';
}

static void write_paper_non_gemm_timing(void) {
    std::ofstream os(profile_path("paper_non_gemm_timing.tsv").c_str());
    if (!os.good()) {
        return;
    }

    os << "Operation\tcall/count token\tlatency per token ms\t% decoder block time\n";
    const char * ops[] = { "RMSNorm1", "RMSNorm2", "SwiGLU / SiLU", "Softmax", "KV cache update/read" };
    for (const char * op : ops) {
        os << op << "\tNA\tNA\tNA\n";
    }
    if (g_profile.ggml_ops) {
        fprintf(stderr,
                "[FPGA][profile] FPGA_PROFILE_GGML_OPS=1 requested, but non-GEMM timing is not wired in this backend. "
                "paper_non_gemm_timing.tsv uses NA.\n");
    }
}

static const char * main_reason_for_counter(const PhaseAuditCounters & c) {
    uint64_t best = 0;
    FpgaFallbackReason best_reason = FPGA_FB_OTHER;
    for (int i = 0; i < FPGA_FB_COUNT; ++i) {
        if (c.fallback_reason[i] > best) {
            best = c.fallback_reason[i];
            best_reason = (FpgaFallbackReason) i;
        }
    }
    return best == 0 ? "N/A" : fpga_stats_fallback_reason_name(best_reason);
}

static void write_audit_summary_tsv(void) {
    std::ofstream os(profile_path("fpga_audit_summary.tsv").c_str());
    if (!os.good()) {
        return;
    }

    os << "run_id\tmode\tphase\ttotal_logical_gemms\tcpu_only_executed_gemms\tpolicy_rejected_cpu_gemms\t"
          "policy_eligible_logical_gemms\tsuccessfully_offloaded_logical_gemms\truntime_failed_logical_gemms\t"
          "avg_jobs_per_gemm\tmin_jobs_per_gemm\tmax_jobs_per_gemm\tsubmitted_hardware_jobs\t"
          "completed_hardware_jobs\tfailed_hardware_jobs\tpre_submit_rejections\t"
          "illegal_job_submissions\tdma_errors\tdma_timeouts\treconstruction_failures\tcoverage_check\t"
          "logical_gemm_invariant_ok\tpolicy_partition_invariant_ok\teligible_partition_invariant_ok\t"
          "hardware_job_invariant_ok\tlogical_macs_total\toffloaded_logical_macs\t"
          "submitted_padded_macs\tmac_coverage_ratio\tpadding_overhead_ratio\tmin_macs_observed\t"
          "max_macs_observed\tmain_fallback_reason\n";

    const FpgaPhase phases[] = { FPGA_PHASE_OVERALL, FPGA_PHASE_PREFILL, FPGA_PHASE_DECODE, FPGA_PHASE_UNKNOWN };
    for (FpgaPhase phase : phases) {
        const PhaseAuditCounters & c = g_phase_counters[(int) phase];
        const uint64_t terminal = c.cpu_only_executed_gemms + c.policy_rejected_cpu_gemms +
                                  c.successfully_offloaded_logical_gemms + c.runtime_failed_logical_gemms;
        const bool logical_ok = c.total_logical_gemms == terminal;
        const bool policy_partition_ok =
            g_runtime_mode == FPGA_RUNTIME_MODE_CPU_ONLY ?
                c.total_logical_gemms == c.cpu_only_executed_gemms :
                c.total_logical_gemms == c.policy_rejected_cpu_gemms + c.policy_eligible_logical_gemms;
        const bool eligible_partition_ok =
            g_runtime_mode == FPGA_RUNTIME_MODE_CPU_ONLY ?
                c.policy_eligible_logical_gemms == 0 :
                c.policy_eligible_logical_gemms ==
                    c.successfully_offloaded_logical_gemms + c.runtime_failed_logical_gemms;
        const bool jobs_ok = c.submitted_hardware_jobs == c.completed_hardware_jobs + c.failed_hardware_jobs;
        const double mac_ratio = c.logical_macs_total > 0.0 ? c.offloaded_logical_macs / c.logical_macs_total : 0.0;
        const double pad_ratio = c.offloaded_logical_macs > 0.0 ?
            (c.submitted_padded_macs - c.offloaded_logical_macs) / c.offloaded_logical_macs : 0.0;
        const double avg_jobs = c.successfully_offloaded_logical_gemms > 0 ?
            (double) c.successful_hardware_jobs / (double) c.successfully_offloaded_logical_gemms : 0.0;

        os << g_profile.run_id << '\t'
           << fpga_stats_runtime_mode_name(g_runtime_mode) << '\t'
           << fpga_stats_phase_name(phase) << '\t'
           << c.total_logical_gemms << '\t'
           << c.cpu_only_executed_gemms << '\t'
           << c.policy_rejected_cpu_gemms << '\t'
           << c.policy_eligible_logical_gemms << '\t'
           << c.successfully_offloaded_logical_gemms << '\t'
           << c.runtime_failed_logical_gemms << '\t'
           << metric_or_na(avg_jobs, c.successfully_offloaded_logical_gemms > 0) << '\t'
           << u64_or_na(c.min_jobs_per_gemm, c.successfully_offloaded_logical_gemms > 0) << '\t'
           << u64_or_na(c.max_jobs_per_gemm, c.successfully_offloaded_logical_gemms > 0) << '\t'
           << c.submitted_hardware_jobs << '\t'
           << c.completed_hardware_jobs << '\t'
           << c.failed_hardware_jobs << '\t'
           << c.pre_submit_rejections << '\t'
           << c.illegal_job_submissions << '\t'
           << c.dma_errors << '\t'
           << c.dma_timeouts << '\t'
           << u64_or_na(c.reconstruction_failures, reconstruction_check_performed()) << '\t'
           << (logical_ok && policy_partition_ok && eligible_partition_ok && jobs_ok &&
               c.illegal_job_submissions == 0 ? "PASS" : "FAIL") << '\t'
           << (logical_ok ? "1" : "0") << '\t'
           << (policy_partition_ok ? "1" : "0") << '\t'
           << (eligible_partition_ok ? "1" : "0") << '\t'
           << (jobs_ok ? "1" : "0") << '\t'
           << (uint64_t) c.logical_macs_total << '\t'
           << (uint64_t) c.offloaded_logical_macs << '\t'
           << (uint64_t) c.submitted_padded_macs << '\t'
           << metric_or_na(mac_ratio, c.logical_macs_total > 0.0) << '\t'
           << metric_or_na(pad_ratio, c.offloaded_logical_macs > 0.0) << '\t'
           << metric_or_na(c.min_macs_observed, c.min_macs_observed > 0.0) << '\t'
           << metric_or_na(c.max_macs_observed, c.max_macs_observed > 0.0) << '\t'
           << (g_runtime_mode == FPGA_RUNTIME_MODE_CPU_ONLY ? "N/A" : main_reason_for_counter(c)) << '\n';
    }
}

static void write_policy_fallbacks_tsv(void) {
    std::ofstream os(profile_path("policy_fallback_summary.tsv").c_str());
    if (!os.good()) {
        return;
    }

    os << "run_id\tmode\tphase\tfallback_reason\tcalls\n";
    const FpgaPhase phases[] = { FPGA_PHASE_OVERALL, FPGA_PHASE_PREFILL, FPGA_PHASE_DECODE, FPGA_PHASE_UNKNOWN };
    for (FpgaPhase phase : phases) {
        const PhaseAuditCounters & c = g_phase_counters[(int) phase];
        for (int i = 0; i < FPGA_FB_COUNT; ++i) {
            if (c.fallback_reason[i] == 0) {
                continue;
            }
            os << g_profile.run_id << '\t'
               << fpga_stats_runtime_mode_name(g_runtime_mode) << '\t'
               << fpga_stats_phase_name(phase) << '\t'
               << fpga_stats_fallback_reason_name((FpgaFallbackReason) i) << '\t'
               << c.fallback_reason[i] << '\n';
        }
    }
}

static void write_numerical_l2_tsv(void) {
    if (g_numerical_l2_rows.empty()) {
        return;
    }

    std::ofstream os(profile_path("numerical_l2_calls.tsv").c_str());
    if (!os.good()) {
        return;
    }

    os << "run_id\tmode\tphase\tlogical_gemm_id\tlayer_id\toperator_family\ttensor_name\tweight_type\tM\tK\tN\t"
          "hardware_jobs\tsum_diff_squared\tsum_cpu_squared\trelative_l2\tstatus\n";
    for (const NumericalL2Row & r : g_numerical_l2_rows) {
        const char * status = r.valid ? "ok" : (r.zero_cpu_nonzero_diff ? "zero_cpu_nonzero_diff" : "invalid");
        os << g_profile.run_id << '\t'
           << r.mode << '\t'
           << r.phase << '\t'
           << r.logical_gemm_id << '\t'
           << r.layer_id << '\t'
           << r.operator_family << '\t'
           << r.tensor_name << '\t'
           << r.ggml_type << '\t'
           << r.M << '\t' << r.K << '\t' << r.N << '\t'
           << r.hardware_jobs << '\t'
           << metric_or_na(r.sum_diff_squared, r.valid || r.zero_cpu_nonzero_diff) << '\t'
           << metric_or_na(r.sum_cpu_squared, r.valid || r.zero_cpu_nonzero_diff) << '\t'
           << metric_or_na(r.relative_l2, r.valid) << '\t'
           << status << '\n';
    }
}

static void write_numerical_l2_summary_tsv(void) {
    if (g_numerical_l2_summary.empty()) {
        return;
    }

    std::ofstream os(profile_path("numerical_l2_summary.tsv").c_str());
    if (!os.good()) {
        return;
    }

    os << "run_id\tmode\toperator_family\tweight_type\tM\tK\tN\tlogical_calls\tvalid_calls\ttotal_hardware_jobs\t"
          "avg_jobs_per_gemm\tmin_jobs_per_gemm\tmax_jobs_per_gemm\t"
          "sum_diff_squared\tsum_cpu_squared\trelative_l2\tmin_relative_l2\tmax_relative_l2\t"
          "zero_cpu_nonzero_diff\n";
    for (const auto & it : g_numerical_l2_summary) {
        const NumericalAggKey & k = it.first;
        const NumericalAgg & a = it.second;
        const bool rel_valid = a.valid_calls > 0 && a.sum_cpu_squared > 0.0;
        const double rel = rel_valid ? std::sqrt(a.sum_diff_squared / a.sum_cpu_squared) : 0.0;
        const double avg_jobs = a.calls > 0 ? (double) a.hardware_jobs / (double) a.calls : 0.0;
        os << g_profile.run_id << '\t'
           << fpga_stats_runtime_mode_name(g_runtime_mode) << '\t'
           << k.operator_family << '\t'
           << k.ggml_type << '\t'
           << k.M << '\t' << k.K << '\t' << k.N << '\t'
           << a.calls << '\t'
           << a.valid_calls << '\t'
           << a.hardware_jobs << '\t'
           << metric_or_na(avg_jobs, a.calls > 0) << '\t'
           << u64_or_na(a.min_jobs_per_gemm, a.calls > 0) << '\t'
           << u64_or_na(a.max_jobs_per_gemm, a.calls > 0) << '\t'
           << metric_or_na(a.sum_diff_squared, a.valid_calls > 0) << '\t'
           << metric_or_na(a.sum_cpu_squared, a.valid_calls > 0) << '\t'
           << metric_or_na(rel, rel_valid) << '\t'
           << metric_or_na(a.min_relative_l2, a.valid_calls > 0) << '\t'
           << metric_or_na(a.max_relative_l2, a.valid_calls > 0) << '\t'
           << a.zero_cpu_nonzero_diff << '\n';
    }
}

static void write_numerical_l2_fallbacks_tsv(void) {
    if (g_numerical_l2_fallback.empty()) {
        return;
    }

    std::ofstream os(profile_path("numerical_fallback_summary.tsv").c_str());
    if (!os.good()) {
        return;
    }

    os << "run_id\tmode\tphase\toperator_family\tweight_type\tM\tK\tN\tprimary_fallback_reason\tlogical_calls\n";
    for (const auto & it : g_numerical_l2_fallback) {
        const NumericalFallbackKey & k = it.first;
        os << g_profile.run_id << '\t'
           << fpga_stats_runtime_mode_name(g_runtime_mode) << '\t'
           << k.phase << '\t'
           << k.operator_family << '\t'
           << k.ggml_type << '\t'
           << k.M << '\t' << k.K << '\t' << k.N << '\t'
           << k.reason << '\t'
           << it.second << '\n';
    }
}

static void audit_write_outputs(bool final_write) {
    ensure_control_config();
    if (!fpga_stats_audit_enabled() && g_numerical_l2_rows.empty() && g_numerical_l2_fallback.empty()) {
        return;
    }

    ensure_output_dir_created();
    if (fpga_stats_audit_enabled()) {
        write_audit_summary_tsv();
        write_policy_fallbacks_tsv();
    }
    write_numerical_l2_tsv();
    write_numerical_l2_summary_tsv();
    write_numerical_l2_fallbacks_tsv();

    if (final_write && fpga_stats_audit_enabled()) {
        fprintf(stderr, "[FPGA][audit] wrote TSV files to %s\n", g_profile.dir.c_str());
    }
}

static void print_top_profile_summary(void) {
    if (!g_profile.enabled || g_profile_ops.empty()) {
        return;
    }

    std::vector<const ProfileAgg *> rows;
    rows.reserve(g_profile_ops.size());
    for (const auto & it : g_profile_ops) {
        rows.push_back(&it.second);
    }

    auto print_row = [](const ProfileAgg * a) {
        fprintf(stderr,
                "layer=%" PRId64 " op=%s tensor=%s type=%s M=%" PRId64 " K=%" PRId64 " N=%" PRId64
                " calls=%" PRIu64 " reason=%s fpga_ms=%s\n",
                a->key.layer_id, a->key.op_group.c_str(), a->key.tensor_name.c_str(), a->key.ggml_type.c_str(),
                a->key.M, a->key.K, a->key.N, a->calls, a->key.fallback_reason.c_str(),
                metric_or_na(a->fpga_latency_ms_total, a->has_fpga_latency).c_str());
    };

    std::sort(rows.begin(), rows.end(), [](const ProfileAgg * a, const ProfileAgg * b) {
        return a->calls > b->calls;
    });
    fprintf(stderr, "\nFPGA PROFILE TOP FALLBACKS BY CALLS:\n");
    int printed = 0;
    for (const ProfileAgg * a : rows) {
        if (a->key.fallback_reason == "none") {
            continue;
        }
        print_row(a);
        if (++printed >= g_profile.topk) {
            break;
        }
    }

    std::sort(rows.begin(), rows.end(), [](const ProfileAgg * a, const ProfileAgg * b) {
        return a->macs_total > b->macs_total;
    });
    fprintf(stderr, "\nFPGA PROFILE TOP FALLBACKS BY MACS:\n");
    printed = 0;
    for (const ProfileAgg * a : rows) {
        if (a->key.fallback_reason == "none") {
            continue;
        }
        print_row(a);
        if (++printed >= g_profile.topk) {
            break;
        }
    }

    std::sort(rows.begin(), rows.end(), [](const ProfileAgg * a, const ProfileAgg * b) {
        return a->fpga_latency_ms_total > b->fpga_latency_ms_total;
    });
    fprintf(stderr, "\nFPGA PROFILE TOP FPGA GROUPS BY RUNTIME:\n");
    printed = 0;
    for (const ProfileAgg * a : rows) {
        if (a->fpga_calls == 0) {
            continue;
        }
        print_row(a);
        if (++printed >= g_profile.topk) {
            break;
        }
    }

    fprintf(stderr, "\nSMALL_M_DETAIL:\n");
    printed = 0;
    for (const ProfileAgg * a : rows) {
        if (a->key.fallback_reason != "small_m") {
            continue;
        }
        print_row(a);
        if (++printed >= g_profile.topk) {
            break;
        }
    }

    fprintf(stderr, "\nUNSUPPORTED_QUANT_DETAIL:\n");
    printed = 0;
    for (const ProfileAgg * a : rows) {
        if (a->key.fallback_reason != "unsupported_weight_type") {
            continue;
        }
        print_row(a);
        if (++printed >= g_profile.topk) {
            break;
        }
    }
}

static void profile_write_outputs(bool final_write) {
    ensure_profile_config();
    if (!g_profile.enabled) {
        return;
    }

    write_profile_ops_csv();
    write_profile_summary_tsv();
    write_shape_hist_csv();
    write_fallback_detail_csv();
    write_k_tiling_validation_tsv();
    write_paper_kernel_shape_table();
    write_paper_offload_summary();
    write_paper_end_to_end();
    write_paper_matmul_summary();
    write_paper_non_gemm_timing();

    if (final_write) {
        print_top_profile_summary();
        fprintf(stderr, "[FPGA][profile] wrote CSV/TSV files to %s\n", g_profile.dir.c_str());
    }
}
