#!/usr/bin/env python3
"""B: clock insertion delay (arrival max rise at every flop CLK and SRAM clk pin), its
spread (global skew bound) and the latency shift of every SRAM clock pin between two
clk_scope.tcl dumps of the same corner. usage: clk_compare.py before.tsv after.tsv"""
import sys
def load(fn):
    a = {}
    for l in open(fn):
        t = l.rstrip('\n').split('\t')
        if t[6] != 'input' or t[9] == 'nan': continue
        if t[4].endswith('/CLK') or t[5].startswith('sky130_sram'): a[t[4]] = (float(t[9]), t[5].startswith('sky130_sram'))
    return a
b, a = load(sys.argv[1]), load(sys.argv[2])
for tag, d in (('before', b), ('after', a)):
    v = sorted(x for x, s in d.values()); sr = sorted(x for x, s in d.values() if s)
    print(f'CLKCMP {tag}: sinks {len(v)}: insertion min {v[0]:.3f} median {v[len(v)//2]:.3f} max {v[-1]:.3f}, spread {v[-1]-v[0]:.3f} ns; SRAM pins {len(sr)}: {sr[0]:.3f}..{sr[-1]:.3f}')
sh = sorted((a[p][0] - b[p][0], p) for p in a if p in b and a[p][1])
moved = [x for x in sh if abs(x[0]) > 0.005]
print(f'CLKCMP SRAM pins whose latency moved > 5 ps: {len(moved)}; shift min {sh[0][0]:+.3f} max {sh[-1][0]:+.3f} ns')
fl = sorted((a[p][0] - b[p][0]) for p in a if p in b and not a[p][1])
print(f'CLKCMP flop CLK latency shift: min {fl[0]:+.3f} max {fl[-1]:+.3f} ns; over 5 ps: {sum(abs(x) > 0.005 for x in fl)}')
