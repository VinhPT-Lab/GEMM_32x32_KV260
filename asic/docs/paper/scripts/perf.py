#!/usr/bin/env python3
"""Throughput from the IP gate-level simulations (GLS on the final netlist, unit delay,
one cycle = one S_AXI_ACLK period). Per job of each matrix shape:
  cycles (job)      = last RESULT_ACCEPT - JOB_k_START + 1  (AXI-Lite config, data in, compute, data out)
  cycles (stream)   = last RESULT_ACCEPT - first FEATURE/WEIGHT_ACCEPT + 1
  MAC = M*K*N, ops = 2*MAC; time and GOPS at F_MHZ; PE utilisation = MAC / (1024 * cycles).
usage: perf.py <out.csv> <gls.log>...   (env F_MHZ, default 50)"""
import sys, re, os, csv
F = float(os.environ.get('F_MHZ', 50))
out = sys.argv[1]; rows = []
for log in sys.argv[2:]:
    s = open(log).read()
    M, K, N = (int(x) for x in re.search(r'Logical matrix size: A=(\d+)x(\d+) B=\d+x(\d+)', s).groups())
    for j in (1, 2):
        start = int(re.search(rf'JOB_{j}_START cycle=(\d+)', s).group(1))
        ins = [int(c) for c in re.findall(rf'(?:FEATURE|WEIGHT)_ACCEPT job={j} .*?cycle=(\d+)', s)]
        res = [int(c) for c in re.findall(rf'RESULT_ACCEPT job={j} .*?cycle=(\d+)', s)]
        first_res = int(re.search(rf'RESULT_VALID_FIRST job={j} cycle=(\d+)', s).group(1))
        mac = M * K * N
        for kind, c0 in (('job', start), ('stream', min(ins))):
            cyc = max(res) - c0 + 1
            t_us = cyc / F
            rows.append(dict(shape=f'{M}x{K}x{N}', job=j, window=kind, cycles=cyc, f_mhz=F, time_us=round(t_us, 3),
                             macs=mac, gops=round(2 * mac / (t_us * 1e3), 3), pe_util_pct=round(100 * mac / (1024 * cyc), 2),
                             peak_gops=round(2 * 1024 * F / 1e3, 1), first_result_cycle=first_res - c0 + 1,
                             in_beats=len(ins), out_beats=len(res)))
with open(out, 'w', newline='') as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0])); w.writeheader(); w.writerows(rows)
for r in rows: print('PERF', r)
