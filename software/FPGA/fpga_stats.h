#ifndef FPGA_STATS_H
#define FPGA_STATS_H

#include "FPGA_GEMM.h"

#include <stdbool.h>
#include <stdint.h>

#ifndef FPGA_STATS_API
#    if defined(GGML_SHARED)
#        if defined(_WIN32) && !defined(__MINGW32__)
#            if defined(GGML_BACKEND_BUILD) || defined(ggml_cpu_EXPORTS)
#                define FPGA_STATS_API __declspec(dllexport) extern
#            else
#                define FPGA_STATS_API __declspec(dllimport) extern
#            endif
#        else
#            define FPGA_STATS_API __attribute__ ((visibility ("default"))) extern
#        endif
#    else
#        define FPGA_STATS_API extern
#    endif
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef enum FpgaFallbackReason {
    FPGA_FB_NOT_READY                  = 0,
    FPGA_FB_UNSUPPORTED_TYPE           = 1,
    FPGA_FB_GGML_SHAPE                 = 2,
    FPGA_FB_RTL_SHAPE                  = 3,
    FPGA_FB_QUANT_ALIGN                = 4,
    FPGA_FB_LAYOUT                     = 5,
    FPGA_FB_USE_REF                    = 6,
    FPGA_FB_SCOPE_POLICY               = 7,
    FPGA_FB_B_CACHE_FULL_RECOVERED     = 8,
    FPGA_FB_B_TILE_TOO_LARGE           = 9,
    FPGA_FB_B_CACHE_DISABLED_SCRATCH   = 10,
    FPGA_FB_CACHE_PLACEMENT_FAILED     = 11,
    FPGA_FB_DMA_RUNTIME_FAILED         = 12,
    FPGA_FB_DMA_TIMEOUT                = 13,
    FPGA_FB_UNSUPPORTED_QUANT_NO_DEQUANT = 14,
    FPGA_FB_SMALL_M                    = 15,
    FPGA_FB_MAX_N                      = 16,
    FPGA_FB_SHAPE_NOT_SUPPORTED        = 17,
    FPGA_FB_BUFFER_TOO_SMALL           = 18,
    FPGA_FB_DISABLED_BY_ENV            = 19,
    FPGA_FB_INTERNAL_ERROR             = 20,
    FPGA_FB_SHIFT_TABLE_MISS           = 21,
    FPGA_FB_FEATURE_BUFFER_LIMIT       = 22,
    FPGA_FB_WEIGHT_BUFFER_LIMIT        = 23,
    FPGA_FB_RESULT_BUFFER_LIMIT        = 24,
    FPGA_FB_INVALID_SHIFT              = 25,
    FPGA_FB_RECONSTRUCTION_FAILURE     = 26,
    FPGA_FB_INVALID_FPGA_RESULT        = 27,
    FPGA_FB_ILLEGAL_JOB_SUBMISSION     = 28,
    FPGA_FB_OTHER                      = 29,
    FPGA_FB_COUNT                      = 30
} FpgaFallbackReason;

typedef enum FpgaRuntimeMode {
    FPGA_RUNTIME_MODE_SELECTIVE = 0,
    FPGA_RUNTIME_MODE_CPU_ONLY  = 1,
    FPGA_RUNTIME_MODE_COMPARE   = 2,
    FPGA_RUNTIME_MODE_INCLUSIVE = 3
} FpgaRuntimeMode;

typedef enum FpgaAuditLevel {
    FPGA_AUDIT_OFF     = 0,
    FPGA_AUDIT_SUMMARY = 1,
    FPGA_AUDIT_VERBOSE = 2
} FpgaAuditLevel;

typedef enum FpgaPhase {
    FPGA_PHASE_OVERALL = 0,
    FPGA_PHASE_PREFILL = 1,
    FPGA_PHASE_DECODE  = 2,
    FPGA_PHASE_UNKNOWN = 3,
    FPGA_PHASE_COUNT   = 4
} FpgaPhase;

typedef struct FpgaStatsSnapshot {
    uint64_t total_logical_gemms;
    uint64_t cpu_only_executed_gemms;
    uint64_t policy_rejected_cpu_gemms;
    uint64_t policy_eligible_logical_gemms;
    uint64_t successfully_offloaded_logical_gemms;
    uint64_t runtime_failed_logical_gemms;
    uint64_t successful_hardware_jobs;
    uint64_t min_jobs_per_gemm;
    uint64_t max_jobs_per_gemm;
    uint64_t submitted_hardware_jobs;
    uint64_t completed_hardware_jobs;
    uint64_t failed_hardware_jobs;
    uint64_t pre_submit_rejections;
    uint64_t illegal_job_submissions;
    uint64_t dma_errors;
    uint64_t dma_timeouts;
    uint64_t reconstruction_failures;
    double   logical_macs_total;
    double   offloaded_logical_macs;
    double   submitted_padded_macs;
    double   min_macs_observed;
    double   max_macs_observed;
    uint64_t fallback_reason[FPGA_FB_COUNT];
} FpgaStatsSnapshot;

void fpga_stats_register_atexit(void);

void fpga_stats_count_mul_mat(int64_t M, int64_t K, int64_t N);
void fpga_stats_count_offload(FpgaQuantType quant, int64_t M, int64_t K, int64_t N);
void fpga_stats_count_fallback(FpgaFallbackReason reason, int64_t M, int64_t K, int64_t N, int type);
void fpga_stats_count_quant_type(bool supported, FpgaQuantType quant);
void fpga_stats_set_force_full_offload(bool enabled);

void fpga_stats_count_small_m_fallback(void);
void fpga_stats_count_min_macs_fallback(void);
void fpga_stats_count_max_n_fallback(void);
void fpga_stats_count_m_range_fallback(void);
void fpga_stats_count_m_list_fallback(void);
void fpga_stats_count_k_tiling_call(uint64_t hardware_tiles);
void fpga_stats_count_small_m_pad(uint64_t M, uint64_t M_hw);
void fpga_stats_count_shift_exact(void);
void fpga_stats_count_shift_cached(void);
void fpga_stats_count_shift_fixed(void);
void fpga_stats_count_shift_table_call(void);
void fpga_stats_count_shift_table_hit(void);
void fpga_stats_count_shift_table_miss(void);
void fpga_stats_count_shift_table_miss_cpu_fallback(void);
void fpga_stats_count_shift_table_miss_fixed(void);
void fpga_stats_count_shift_table_miss_cached(void);
void fpga_stats_count_shift_table_miss_exact(void);
void fpga_stats_add_shift_select_time(double ms);

void fpga_stats_count_shape(int64_t M, int64_t K, int64_t N);
void fpga_stats_count_shape_offload(int64_t M, int64_t K, int64_t N, uint64_t tiles);
void fpga_stats_count_shape_fallback(int64_t M, int64_t K, int64_t N);
void fpga_stats_count_k_tiling_saturation(uint64_t saturated, uint64_t total);

void fpga_stats_count_weight_cache_hit(void);
void fpga_stats_count_weight_cache_miss(void);
void fpga_stats_count_weight_file_hit(void);
void fpga_stats_count_weight_file_miss(void);
void fpga_stats_add_weight_file_bytes(uint64_t bytes);
void fpga_stats_add_weight_ddr_bytes(uint64_t bytes);

void fpga_stats_set_b_cache_mode(const char * mode);
void fpga_stats_set_b_buffer_limit_bytes(uint64_t bytes);
void fpga_stats_update_b_cache_used_bytes(uint64_t bytes);
void fpga_stats_count_b_cache_full(void);
void fpga_stats_count_b_cache_clear(void);
void fpga_stats_count_b_scratch_copy(void);
void fpga_stats_count_b_tile_too_large_fallback(void);

void fpga_stats_set_dma_reset_mode(const char * mode);
void fpga_stats_set_reconstruction_check_mode(const char * mode);
void fpga_stats_count_dma_full_reset_call(void);
void fpga_stats_count_dma_status_clear_call(void);
void fpga_stats_count_dma_reset_failure(void);
void fpga_stats_count_dma_runtime_error(void);
void fpga_stats_count_dma_runtime_timeout(void);

void fpga_stats_set_last_runtime_fallback_reason(FpgaFallbackReason reason);
FpgaFallbackReason fpga_stats_get_last_runtime_fallback_reason(void);
FPGA_STATS_API const char * fpga_stats_fallback_reason_name(FpgaFallbackReason reason);

FPGA_STATS_API FpgaRuntimeMode fpga_stats_get_runtime_mode(void);
FPGA_STATS_API const char * fpga_stats_runtime_mode_name(FpgaRuntimeMode mode);
FpgaAuditLevel fpga_stats_get_audit_level(void);
bool fpga_stats_audit_enabled(void);
bool fpga_stats_audit_verbose(void);
FPGA_STATS_API void fpga_stats_set_phase(FpgaPhase phase);
FpgaPhase fpga_stats_get_phase(void);
FPGA_STATS_API const char * fpga_stats_phase_name(FpgaPhase phase);
uint64_t fpga_stats_get_current_logical_gemm_id(void);
uint64_t fpga_stats_get_submitted_hardware_job_count(void);
uint64_t fpga_stats_get_completed_hardware_job_count(void);
uint64_t fpga_stats_get_failed_hardware_job_count(void);
FPGA_STATS_API void fpga_stats_get_snapshot(FpgaPhase phase, FpgaStatsSnapshot * out);
FPGA_STATS_API void fpga_stats_reset_benchmark_counters(void);
void fpga_stats_record_cpu_only_gemm(int64_t M, int64_t K, int64_t N);
void fpga_stats_record_policy_eligible(int64_t M, int64_t K, int64_t N);
void fpga_stats_record_policy_rejection(FpgaFallbackReason reason, int64_t M, int64_t K, int64_t N);
void fpga_stats_record_offload_success(int64_t M, int64_t K, int64_t N, uint64_t hardware_jobs);
void fpga_stats_record_runtime_failure(FpgaFallbackReason reason, int64_t M, int64_t K, int64_t N);
void fpga_stats_record_pre_submit_rejection(FpgaFallbackReason reason);
void fpga_stats_record_job_submitted(uint64_t padded_macs);
void fpga_stats_record_job_completed(void);
void fpga_stats_record_job_failed(FpgaFallbackReason reason);
void fpga_stats_record_illegal_job_submission(void);
void fpga_stats_record_reconstruction_failure(void);
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
                                    bool               valid);
void fpga_stats_record_numerical_fallback(uint64_t           logical_gemm_id,
                                          const char *       tensor_name,
                                          const char *       ggml_type_name,
                                          int64_t            M,
                                          int64_t            K,
                                          int64_t            N,
                                          FpgaFallbackReason reason);
double L2_compare_func(const float * cpu_output,
                       const float * fpga_output,
                       uint64_t      element_count,
                       double *      sum_diff_squared,
                       double *      sum_cpu_squared,
                       bool *        zero_cpu_nonzero_diff);

void fpga_stats_count_backend_mock(void);
void fpga_stats_count_backend_hw(void);
void fpga_stats_count_hw_runtime_fallback(void);

void fpga_stats_count_saturation(uint64_t saturated, uint64_t total);

void fpga_stats_add_runtime(double total_ms,
                            double act_quant_ms,
                            double weight_prepare_ms,
                            double dma_fpga_ms,
                            double result_dequant_ms);

void fpga_stats_add_runtime_detail(double shift_select_ms,
                                   double feature_copy_ms,
                                   double result_copy_ms,
                                   double ctrl_config_ms,
                                   double dma_reset_ms,
                                   double dma_start_ms,
                                   double dma_wait0_ms,
                                   double dma_wait1_ms,
                                   double dma_wait2_ms,
                                   uint64_t tile_count);

bool fpga_profile_enabled(void);
bool fpga_profile_compare_enabled(void);
double fpga_profile_compare_tol(void);
uint64_t fpga_profile_compare_max_elements(void);

uint64_t fpga_stats_get_weight_cache_hit_count(void);
uint64_t fpga_stats_get_weight_cache_miss_count(void);
uint64_t fpga_stats_get_dma_runtime_error_count(void);
uint64_t fpga_stats_get_dma_runtime_timeout_count(void);
uint64_t fpga_stats_get_tile_count(void);
uint64_t fpga_stats_get_shift_table_hit_count(void);
uint64_t fpga_stats_get_shift_table_miss_count(void);
uint64_t fpga_stats_get_k_tiling_saturation_count(void);
uint64_t fpga_stats_get_k_tiling_total_output_count(void);

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
                                           FpgaFallbackReason fallback_reason);

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
                                      uint64_t           compared_count);

void fpga_stats_print(void);

#ifdef __cplusplus
}
#endif

#endif  // FPGA_STATS_H
