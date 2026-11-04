#!/usr/bin/env python3
"""Throughput of larger and LLM-like matrix shapes from RTL simulation of the configuration
that was built (sim/run_system.sh asic-sram, WRAP=lean AXIS_CG=1: OpenRAM macro models,
GEMM_DP_RESET=0; it matches the IP gate-level sim cycle for cycle on 64x64x64, 8x32x544,
16x992x32). Copy of the runner: run_system_paper.sh.

One hardware job must fit the buffers (rtl_asic/gemm_asic_cfg.vh, GEMM_top.v):
  feature words M*Kb <= 511, weight words Kpad*Nb <= 1023, output words M*Nb <= 511,
  Kb <= 31, Nb <= 31  (Kb = ceil(K/32), Nb = ceil(N/32), Kpad = 32*Kb). The word counters
  of In_buffer / Out_buffer are log2(depth) bits wide, so a full 512-word feature buffer
  wraps to 0 (128x128x128 as one job stalls after one feature beat: checked).
Larger shapes are split by the host along M and N only, into near-equal chunks (results are int8 after the shift,
so K cannot be split exactly): K <= 992. Each distinct sub-job shape is simulated
(testbench job 2) and the matrix total is the sum of the sub-job cycles, run back to back
(each sub-job pays its AXI-Lite configuration; the testbench status polling between jobs is
not counted, as in perf.py).
Two testbench modes: tb = original testbench (random gaps, TVALID dropped after each beat,
result TREADY low on 1/7 + 1/11 of cycles); fullrate = streams at one beat per cycle.
usage: perf_rtl.py <paper dir>"""
import sys, os, re, csv, math, subprocess, shutil
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from phases import split, PH
P = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
W = f"{P}/work/rtl"; os.makedirs(W, exist_ok=True)
F = 50.0; PEAK = 2 * 1024 * F / 1e3
REPO = "${KV260}"
SHAPES = [  # name, M, K, N, note
    ("gls_64", 64, 64, 64, "GLS shape"), ("gls_8x32x544", 8, 32, 544, "GLS shape"), ("gls_16x992x32", 16, 992, 32, "GLS shape"),
    ("sq_128", 128, 128, 128, "square"), ("sq_256", 256, 256, 256, "square"), ("sq_512", 512, 512, 512, "square"),
    ("attn_qk", 128, 64, 128, "attention scores Q.K^T, one head (d_head 64, 128 tokens)"),
    ("attn_v", 128, 128, 64, "attention P.V, one head (128 tokens, d_head 64)"),
    ("proj_prefill", 128, 768, 768, "QKV / output projection, d_model 768 (GPT-2 small, BERT-base), 128 tokens"),
    ("ffn_up_prefill", 128, 768, 3072, "FFN up projection 768 -> 3072, 128 tokens"),
    ("proj_decode_b8", 8, 768, 768, "projection, decode, batch 8"),
    ("proj_decode_b1", 1, 768, 768, "projection, decode, batch 1 (GEMV); M=1 gives wrong results in the RTL (row_count=1: wrong values, extra result beats), so the host pads to 2 rows"),
]

def chunks(total, most):
    k = math.ceil(total / most); q, r = divmod(total, k)
    return [q + 1] * r + [q] * (k - r)

def plan(M, K, N, lim=(511, 1023, 511)):
    """sub-jobs within the word limits (feature, weight, result) of one job"""
    Kb = math.ceil(K / 32); assert Kb <= 31, "K > 992 needs a K split"
    Nb = math.ceil(N / 32); nbmax = min(31, lim[1] // (32 * Kb)); assert nbmax >= 1, "K too large for the weight limit"
    nbs = chunks(Nb, nbmax); ns = [32 * b for b in nbs]; ns[-1] -= 32 * Nb - N
    ms = chunks(M, min(lim[0] // Kb, lim[2] // max(nbs)))
    jobs = {}
    for m in ms:
        for n in ns:
            jobs[(m, K, n)] = jobs.get((m, K, n), 0) + 1
    return jobs

def sim(shape, mode):
    M, K, N = shape; tag = f"{M}x{K}x{N}_{mode}"; log = f"{W}/{tag}.log"
    if not os.path.exists(log):
        b = f"{W}/b_{tag}"
        env = dict(os.environ, BUILD=b, FULLRATE="1" if mode == "fullrate" else "0", WRAP="lean", AXIS_CG="1",
                   EXTRA_V=f"{W}/fsm_mon.v", TB_SHAPE=f"{M},{K},{N}", PDK_ROOT=os.path.expanduser("~/.ciel"))
        r = subprocess.run([f"{P}/scripts/run_system_paper.sh", "asic-sram", REPO], env=env, capture_output=True, text=True)
        ok = "OVERALL PASS" in r.stdout
        shutil.copy(f"{b}/system.log", log); shutil.rmtree(b)
        if not ok: print(f"PERFRTL {tag}: no OVERALL PASS");
    s = open(log).read()
    # data check: no mismatch and no protocol error in either job (OVERALL can also fail on
    # the testbench's busy-status poll, which misses very short jobs)
    ok = (s.count("Mismatch count = 0") == 2 and s.count("Protocol error count = 0") == 2
          and "FAIL job=" not in s and "FAIL extra" not in s)
    _, _, _, info = split(log, 2)
    return ok, info

if __name__ == "__main__":
    subrows, rows = [], []
    for name, M, K, N, note in SHAPES:
        jobs = plan(max(M, 2), K, N)          # M = 1 is padded to 2 rows (see SHAPES)
        for mode in ("tb", "fullrate"):
            tot = {p: 0 for p in PH}; cyc = 0; ok_all = True; byin = byout = 0
            for (m, k, n), cnt in jobs.items():
                ok, i = sim((m, k, n), mode); ok_all &= ok
                Kb, Nb = math.ceil(k / 32), math.ceil(n / 32)
                subrows.append(dict(shape=name, mode=mode, sub_job=f"{m}x{k}x{n}", count=cnt, sim_pass=ok, cycles=i["cycles"],
                                    **{f"{p}_cycles": i[f"{p}_cycles"] for p in PH}, weight_tiles=i["weight_tiles"],
                                    feature_beats=i["feature_beats"], weight_beats=i["weight_beats"], result_beats=i["result_beats"],
                                    pe_util_pct=round(100 * m * k * n / (1024 * i["cycles"]), 2)))
                print("PERFRTL", subrows[-1])
                cyc += cnt * i["cycles"]
                for p in PH: tot[p] += cnt * i[f"{p}_cycles"]
                byin += cnt * 32 * (i["feature_beats"] + i["weight_beats"]); byout += cnt * 32 * i["result_beats"]
            mac = M * K * N; t_us = cyc / F
            rows.append(dict(shape=name, M=M, K=K, N=N, mode=mode, note=note, sub_jobs=sum(jobs.values()),
                             sub_job_shapes=" + ".join(f"{c} x {a}x{b}x{d}" for (a, b, d), c in jobs.items()), sim_pass=ok_all,
                             cycles=cyc, time_us=round(t_us, 2), macs=mac, gops=round(2 * mac / (t_us * 1e3), 3),
                             pe_util_pct=round(100 * mac / (1024 * cyc), 2), peak_gops=PEAK,
                             **{f"{p}_pct": round(100 * tot[p] / cyc, 1) for p in PH},
                             bytes_in=byin, bytes_out=byout, ops_per_byte=round(2 * mac / (byin + byout), 2),
                             in_bw_used_gbs=round(byin / (t_us * 1e3), 3)))
            print("PERFRTL", rows[-1])
    for fn, rr in (("perf_rtl_subjobs.csv", subrows), ("perf_rtl_shapes.csv", rows)):
        with open(f"{P}/data/{fn}", "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(rr[0])); w.writeheader(); w.writerows(rr)
