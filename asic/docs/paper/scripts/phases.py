#!/usr/bin/env python3
"""Cycle split of one job by phase, from a simulation log (GLS or RTL) that has the
testbench lines (JOB_k_START, AXIL_*, FEATURE/WEIGHT/RESULT_ACCEPT) and the FSM_STATE
lines of vcd_job_ip.py. Job = JOB_k_START .. last RESULT_ACCEPT (as perf.py). Each cycle
gets one phase, in this priority:
  compute      BufferFeeder state SET_FEATURE: feature rows stream through the array
  weight_tile  state SET_WEIGHT: one 32x32 weight tile is shifted into the PEs
  config       state IDLE before the first input beat: AXI-Lite writes, readback, idle poll
  input_load   state IDLE from the first input beat until the first weight tile: the
               feature and weight AXI-Stream beats go into the SRAM buffers (both streams
               interleaved, so they share these cycles)
  tile_reload  state IDLE between two tiles (after the first, before the last): the next
               K-block moves from InputBuffer to the tile memories (only when Kb > 1)
  output_drain state IDLE after the last tile: pipeline drain and the last result beats
Result beats accepted during compute / weight_tile are counted separately (overlap).
usage: phases.py <out.csv> <log>...   (job 2 of every log; env JOB to change)"""
import re, sys, os, csv
PH = ("config", "input_load", "weight_tile", "compute", "tile_reload", "output_drain")

def split(log, job=2):
    s = open(log).read()
    M, K, N = (int(x) for x in re.search(r'Logical matrix size: A=(\d+)x(\d+) B=\d+x(\d+)', s).groups())
    S = int(re.search(rf'JOB_{job}_START cycle=(\d+)', s).group(1))
    fin = [int(c) for c in re.findall(rf'FEATURE_ACCEPT job={job} .*?cycle=(\d+)', s)]
    win = [int(c) for c in re.findall(rf'WEIGHT_ACCEPT job={job} .*?cycle=(\d+)', s)]
    res = [int(c) for c in re.findall(rf'RESULT_ACCEPT job={job} .*?cycle=(\d+)', s)]
    E = max(res)
    ch = [(int(c), int(v)) for c, v in re.findall(r'FSM_STATE cycle=(\d+) state=(\d+)', s)]
    if not ch: sys.exit(f"{log}: no FSM_STATE lines")
    st = {}; cur = 0; i = 0
    for c in range(0, E + 1):
        while i < len(ch) and ch[i][0] <= c: cur = ch[i][1]; i += 1
        if c >= S: st[c] = cur
    first_in = min(fin + win); seen = False; lab = []
    last_busy = max(c for c in range(S, E + 1) if st[c] != 0)
    for c in range(S, E + 1):
        v = st[c]
        if v == 3: p = "compute"; seen = True
        elif v == 1: p = "weight_tile"; seen = True
        elif c < first_in: p = "config"
        elif not seen: p = "input_load"
        elif c < last_busy: p = "tile_reload"
        else: p = "output_drain"
        lab.append(p)
    tiles = sum(1 for k in range(1, len(lab)) if lab[k] == "weight_tile" and lab[k - 1] != "weight_tile")
    rs = set(res)
    info = dict(shape=f"{M}x{K}x{N}", job=job, start=S, end=E, cycles=E - S + 1,
                **{f"{p}_cycles": lab.count(p) for p in PH},
                weight_tiles=tiles, feature_beats=len(fin), weight_beats=len(win), result_beats=len(res),
                feature_span=max(fin) - min(fin) + 1, weight_span=max(win) - min(win) + 1,
                result_beats_during_compute=sum(1 for c in rs if lab[c - S] in ("compute", "weight_tile")),
                first_result=min(res) - S + 1)
    return S, E, lab, info

if __name__ == "__main__":
    job = int(os.environ.get("JOB", 2)); rows = []
    for log in sys.argv[2:]:
        rows.append(split(log, job)[3]); print("PHASES", rows[-1])
    with open(sys.argv[1], "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0])); w.writeheader(); w.writerows(rows)
