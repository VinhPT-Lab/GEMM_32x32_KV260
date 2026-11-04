#!/usr/bin/env python3
"""ESTIMATE (not a simulation of a modified design) of the PE utilisation if the IP overlapped
load, compute and output across jobs (ping-pong / double buffering), from the per-phase cycles
that the RTL of v1 really takes for each sub-job (phases.py on perf_rtl.py runs, full-rate
streams). Per sub-job:
  C config, L input_load, W weight_tile, P compute, R tile_reload, D output_drain (measured)
  L_stream = max(feature beats, weight beats)  (one beat per cycle per stream)
  L_xfer   = L - L_stream  (first K-block from InputBuffer to the tile memories; stays on the
             compute side)
  serial (v1):          T = C + L + W + P + R + D
  job-level overlap:    T = max(C + L_stream, L_xfer + W + P + R, D)
                        (next job streams in and the previous job drains while this one computes)
  + weight preload:     T = max(C + L_stream, L_xfer + P + R, D)  (weight tiles hidden behind the
                        previous tile, as the PE's weight_shift / weight_value pair would allow)
  bound, tiles back to back: T = max(C + L_stream, tiles * m + FILL, D) with FILL = 97 cycles
                        (array fill / drain paid once per job instead of once per tile; measured
                        compute = tiles * (m + 97.5) on every RTL run)
Buffer cases: "current SRAM" = the 80 macros split in two halves, so one job may use at most
(255, 511, 255) feature / weight / result words; "2x SRAM" = two copies of today's buffers,
(511, 1023, 511) words per job as in v1. Sum over sub-jobs, run back to back.
usage: perf_overlap.py <paper dir>"""
import sys, os, csv, math
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import perf_rtl as pr
P = sys.argv[1]
CASES = [("v1 serial", (511, 1023, 511), "serial"),
         ("overlap, current SRAM (ping-pong halves)", (255, 511, 255), "overlap"),
         ("overlap, 2x SRAM", (511, 1023, 511), "overlap"),
         ("overlap + weight preload, 2x SRAM", (511, 1023, 511), "overlap_wp"),
         ("bound: overlap + tiles back to back, 2x SRAM", (511, 1023, 511), "bound")]
FILL = 97
def tjob(i, mode):
    C, L, W, Pc, R, D = (i[f"{p}_cycles"] for p in ("config", "input_load", "weight_tile", "compute", "tile_reload", "output_drain"))
    ls = max(i["feature_beats"], i["weight_beats"]); lx = max(0, L - ls)
    if mode == "serial": return C + L + W + Pc + R + D
    if mode == "overlap": return max(C + ls, lx + W + Pc + R, D)
    if mode == "overlap_wp": return max(C + ls, lx + Pc + R, D)
    return max(C + ls, i["weight_tiles"] * m_of(i) + FILL, D)
def m_of(i): return int(i["shape"].split("x")[0])
rows = []
for name, M, K, N, note in pr.SHAPES:
    rec = dict(shape=name, M=M, K=K, N=N)
    for cname, lim, mode in CASES:
        try:
            jobs = pr.plan(max(M, 2), K, N, lim)
        except AssertionError as e:
            rec[f"{cname}: util_pct"] = ""; continue
        tot = 0
        for (m, k, n), cnt in jobs.items():
            ok, i = pr.sim((m, k, n), "fullrate")
            if not ok: print("PEROVL data error", m, k, n)
            tot += cnt * tjob(i, mode)
        rec[f"{cname}: sub_jobs"] = sum(jobs.values())
        rec[f"{cname}: util_pct"] = round(100 * M * K * N / (1024 * tot), 2)
    rows.append(rec); print("OVERLAP", rec)
with open(f"{P}/data/perf_overlap_estimate.csv", "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0])); w.writeheader(); w.writerows(rows)
