#!/usr/bin/env python3
"""
patch_software_depths.py [path/to/GEMM_32x32_KV260-main]

The ASIC core has smaller buffers than the KV260 bitstream (weight 1024,
feature 512, output 512 words instead of 2400 each). The driver must not send
a job that overflows them. This splits the single 2400 limit in
  software/FPGA/FPGA_GEMM.cpp, software/ggml-cpu/ggml-cpu.c
  and the copies under software/llama.cpp/...
into three limits that default to 2400 (FPGA build unchanged) and become
1024/512/512 when compiled with -DGEMM_ASIC_DEPTHS. Idempotent; keeps a .orig.
"""
import os, re, shutil, sys

repo = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "..", "GEMM_32x32_KV260-main")
cpp = ["software/FPGA/FPGA_GEMM.cpp", "software/llama.cpp/llama.cpp/ggml/src/ggml-cpu/FPGA_GEMM/FPGA_GEMM.cpp"]
cfile = ["software/ggml-cpu/ggml-cpu.c", "software/llama.cpp/llama.cpp/ggml/src/ggml-cpu/ggml-cpu.c"]
DEFS = """#ifdef GEMM_ASIC_DEPTHS          /* hardened ASIC core (gemm_asic_kit) */
#define IP_FEATURE_DEPTH 512
#define IP_WEIGHT_DEPTH  1024
#define IP_RESULT_DEPTH  512
#else                             /* KV260 bitstream */
#define IP_FEATURE_DEPTH 2400
#define IP_WEIGHT_DEPTH  2400
#define IP_RESULT_DEPTH  2400
#endif
"""

def patch(path, fn):
    p = os.path.join(repo, path)
    if not os.path.exists(p):
        print(f"skip (missing): {path}"); return
    s = open(p).read()
    if "IP_WEIGHT_DEPTH" in s:
        print(f"already patched: {path}"); return
    t = fn(s)
    if t == s:
        sys.exit(f"pattern not found in {path} - file changed, patch by hand")
    shutil.copy(p, p + ".orig")
    open(p, "w").write(t)
    print(f"patched: {path}")

def fix_cpp(s):
    s = s.replace("#define IP_BUFFER_DEPTH 2400\n", DEFS)
    s = s.replace("if (feature_beats > IP_BUFFER_DEPTH || weight_beats > IP_BUFFER_DEPTH || result_beats > IP_BUFFER_DEPTH) {",
                  "if (feature_beats > IP_FEATURE_DEPTH || weight_beats > IP_WEIGHT_DEPTH || result_beats > IP_RESULT_DEPTH) {")
    s = s.replace('result_beats=%llu depth=%d\\n",', 'result_beats=%llu depth(w)=%d\\n",')
    s = s.replace("(unsigned long long) result_beats,\n            IP_BUFFER_DEPTH);",
                  "(unsigned long long) result_beats,\n            IP_WEIGHT_DEPTH);")
    return s if "IP_BUFFER_DEPTH" not in s else s.replace("IP_BUFFER_DEPTH", "IP_WEIGHT_DEPTH")

def fix_c(s):
    old = "(M * k_blocks) <= 2400 && (k_blocks * 32 * n_blocks) <= 2400 &&"
    if old not in s:
        return s
    s = s.replace(old, "(M * k_blocks) <= IP_FEATURE_DEPTH && (k_blocks * 32 * n_blocks) <= IP_WEIGHT_DEPTH &&")
    s = re.sub(r"\(M \* n_blocks\) <= 2400;", "(M * n_blocks) <= IP_RESULT_DEPTH;", s, count=1)
    # definitions right before the statement that uses them (a preprocessor
    # line inside a function is fine in C; avoids landing in an #if block)
    i = s.index("IP_FEATURE_DEPTH")
    stmt = s.rfind("\n", 0, s.rfind("const bool rtl_shape_ok", 0, i)) + 1
    guarded = "#ifndef IP_FEATURE_DEPTH\n" + DEFS + "#endif\n"
    return s[:stmt] + guarded + s[stmt:]

for f in cpp:
    patch(f, fix_cpp)
for f in cfile:
    patch(f, fix_c)
print("build the ASIC driver with -DGEMM_ASIC_DEPTHS; without it nothing changes for the KV260")
