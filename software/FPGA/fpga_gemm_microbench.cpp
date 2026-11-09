#include "FPGA_GEMM.h"
#include "fpga_stats.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>
#include <vector>

#if defined(_WIN32)
#    include <direct.h>
#else
#    include <sys/stat.h>
#endif

struct ShapeCase {
    const char * group;
    int M;
    int K;
    int N;
};

static std::string output_path(void) {
    const char * dir = std::getenv("FPGA_PROFILE_DIR");
    std::string path = (dir != nullptr && dir[0] != '\0') ? dir : ".";
#if defined(_WIN32)
    _mkdir(path.c_str());
#else
    mkdir(path.c_str(), 0777);
#endif
    if (!path.empty() && path[path.size() - 1] != '/' && path[path.size() - 1] != '\\') {
        path += "/";
    }
    path += "paper_kernel_shape_table.tsv";
    return path;
}

static float deterministic_value(uint64_t i) {
    uint64_t x = i * 2862933555777941757ull + 3037000493ull;
    x ^= x >> 33;
    const int v = (int) (x % 2001ull) - 1000;
    return (float) v / 1000.0f;
}

static void cpu_ref(const std::vector<float> & A, const std::vector<float> & B, std::vector<float> & C,
                    int M, int K, int N) {
    std::fill(C.begin(), C.end(), 0.0f);
    for (int m = 0; m < M; ++m) {
        for (int n = 0; n < N; ++n) {
            double acc = 0.0;
            for (int k = 0; k < K; ++k) {
                acc += (double) B[(size_t) m * (size_t) K + (size_t) k] *
                       (double) A[(size_t) n * (size_t) K + (size_t) k];
            }
            C[(size_t) m * (size_t) N + (size_t) n] = (float) acc;
        }
    }
}

static std::string metric_or_na(double value, bool valid) {
    if (!valid || !std::isfinite(value)) {
        return "NA";
    }
    char buf[64];
    std::snprintf(buf, sizeof(buf), "%.6f", value);
    return std::string(buf);
}

int main(void) {
#if !defined(_WIN32)
    setenv("FPGA_EXPERIMENTAL_K_TILING", "1", 0);
    setenv("FPGA_SMALL_M_PAD32", "1", 0);
#endif

    const ShapeCase cases[] = {
        { "Q/O projection", 32, 896, 896 },
        { "Q/O projection", 64, 896, 896 },
        { "Q/O projection", 128, 896, 896 },
        { "K/V projection", 32, 896, 896 },
        { "K/V projection", 64, 896, 896 },
        { "K/V projection", 128, 896, 896 },
        { "Gate/Up projection", 32, 896, 4864 },
        { "Gate/Up projection", 64, 896, 4864 },
        { "Gate/Up projection", 128, 896, 4864 },
        { "Down projection", 32, 4864, 896 },
        { "Down projection", 64, 4864, 896 },
        { "Down projection", 128, 4864, 896 },
        { "Decode-like GEMV", 1, 896, 896 },
        { "Decode-like large projection", 1, 896, 4864 },
    };

    std::ofstream os(output_path().c_str());
    if (!os.good()) {
        std::fprintf(stderr, "failed to open paper_kernel_shape_table.tsv\n");
        return 1;
    }

    os << "Kernel / Shape group\tM\tK\tN\tFull shape MxKxN\tshift_mode\tshift_table_hit_rate\tk_tiling_used\t"
          "num_k_tiles\tsaturation_rate\tCPU latency\tFPGA latency\tMACs\tGOPS\tSpeedup\tMaxAbsError\tMAE\t"
          "Mismatch count\tMatch Rate\n";

    const double tol = 1.0;
    for (const ShapeCase & c : cases) {
        std::vector<float> A((size_t) c.N * (size_t) c.K);
        std::vector<float> B((size_t) c.M * (size_t) c.K);
        std::vector<float> C_cpu((size_t) c.M * (size_t) c.N);
        std::vector<float> C_fpga((size_t) c.M * (size_t) c.N, 0.0f);

        for (size_t i = 0; i < A.size(); ++i) {
            A[i] = deterministic_value(i);
        }
        for (size_t i = 0; i < B.size(); ++i) {
            B[i] = deterministic_value(i + 17);
        }

        const auto cpu0 = std::chrono::high_resolution_clock::now();
        cpu_ref(A, B, C_cpu, c.M, c.K, c.N);
        const auto cpu1 = std::chrono::high_resolution_clock::now();
        const double cpu_ms = std::chrono::duration<double, std::milli>(cpu1 - cpu0).count();

        fpga_gemm_set_tensor_context(c.group);
        const uint64_t shift_hits_before = fpga_stats_get_shift_table_hit_count();
        const uint64_t shift_misses_before = fpga_stats_get_shift_table_miss_count();
        const uint64_t k_sat_before = fpga_stats_get_k_tiling_saturation_count();
        const uint64_t k_total_before = fpga_stats_get_k_tiling_total_output_count();

        const auto fpga0 = std::chrono::high_resolution_clock::now();
        const bool fpga_ok = fpga_gemm_try_run(A.data(), FPGA_QUANT_F32, B.data(), C_fpga.data(), c.M, c.K, c.N, 0);
        const auto fpga1 = std::chrono::high_resolution_clock::now();
        const double fpga_ms = std::chrono::duration<double, std::milli>(fpga1 - fpga0).count();
        const uint64_t shift_hits = fpga_stats_get_shift_table_hit_count() - shift_hits_before;
        const uint64_t shift_misses = fpga_stats_get_shift_table_miss_count() - shift_misses_before;
        const uint64_t k_sat = fpga_stats_get_k_tiling_saturation_count() - k_sat_before;
        const uint64_t k_total = fpga_stats_get_k_tiling_total_output_count() - k_total_before;

        double max_abs = 0.0;
        double mae = 0.0;
        uint64_t mismatch = 0;
        if (fpga_ok) {
            for (size_t i = 0; i < C_cpu.size(); ++i) {
                const double err = std::fabs((double) C_fpga[i] - (double) C_cpu[i]);
                max_abs = std::max(max_abs, err);
                mae += err;
                if (err > tol) {
                    mismatch++;
                }
            }
            mae /= (double) C_cpu.size();
        }

        const double macs = (double) c.M * (double) c.K * (double) c.N;
        const double gops = fpga_ok && fpga_ms > 0.0 ? (macs / 1.0e9) / (fpga_ms / 1000.0) : 0.0;
        const double speedup = fpga_ok && fpga_ms > 0.0 ? cpu_ms / fpga_ms : 0.0;
        const double match_rate = fpga_ok && !C_cpu.empty() ? (double) (C_cpu.size() - mismatch) / (double) C_cpu.size() : 0.0;
        const uint64_t shift_total = shift_hits + shift_misses;
        const double shift_hit_rate = shift_total > 0 ? (double) shift_hits / (double) shift_total : 0.0;
        const bool k_tiling_used = c.K != 896;
        const uint64_t num_k_tiles = k_tiling_used ? (uint64_t) ((c.K + 895) / 896) : 1;
        const double saturation_rate = k_total > 0 ? (double) k_sat / (double) k_total : 0.0;

        os << c.group << '\t'
           << c.M << '\t' << c.K << '\t' << c.N << '\t'
           << c.M << 'x' << c.K << 'x' << c.N << '\t'
           << fpga_gemm_current_shift_mode() << '\t'
           << metric_or_na(shift_hit_rate, shift_total > 0) << '\t'
           << (k_tiling_used ? "1" : "0") << '\t'
           << num_k_tiles << '\t'
           << metric_or_na(saturation_rate, k_total > 0) << '\t'
           << metric_or_na(cpu_ms, true) << '\t'
           << metric_or_na(fpga_ms, fpga_ok) << '\t'
           << (uint64_t) macs << '\t'
           << metric_or_na(gops, fpga_ok) << '\t'
           << metric_or_na(speedup, fpga_ok) << '\t'
           << metric_or_na(max_abs, fpga_ok) << '\t'
           << metric_or_na(mae, fpga_ok) << '\t'
           << (fpga_ok ? std::to_string(mismatch) : "NA") << '\t'
           << metric_or_na(match_rate, fpga_ok) << '\n';
    }

    std::fprintf(stderr, "wrote %s\n", output_path().c_str());
    fpga_gemm_shutdown();
    return 0;
}
