#!/usr/bin/env python3
"""Every pin must touch a guide GCell of its net on the pin's layer or the next
layer up (li1 pins: met1). usage: guide_pincheck.py file.guide pins_all.tsv [miss.tsv]"""
import sys
from collections import defaultdict
L = {'li1': 0, 'met1': 1, 'met2': 2, 'met3': 3, 'met4': 4, 'met5': 5}
NX, NY, S = 1053, 1519, 6900
def cells(lo, hi, n):
    a, b = lo // S, hi // S
    if lo % S == 0 and a > 0: a -= 1
    return range(min(max(a, 0), n - 1), min(max(b, 0), n - 1) + 1)
need = defaultdict(list)
for l in open(sys.argv[2]):
    net, k, pin, lays, *b = l.rstrip('\n').split('\t')
    need[net].append((pin, [L[x] for x in lays.split(',') if x], [int(v) for v in b]))
g = {}; cur = None; ok = miss = 0; out = []
def check(net, s):
    global ok, miss
    for pin, lays, b in need.get(net, []):
        want = set()
        for lay in lays:
            for z in (lay, lay + 1):
                if 1 <= z <= 5: want.add(z)
        hit = any((z, x, y) in s for z in want for x in cells(b[0], b[2], NX) for y in cells(b[1], b[3], NY))
        if hit: ok += 1
        else: miss += 1; out.append((net, pin, lays, b))
seen = set()
for l in open(sys.argv[1]):
    l = l.strip()
    if l == '(': continue
    if l == ')': check(cur, s); seen.add(cur); continue
    t = l.split()
    if len(t) == 1: cur = t[0]; s = set()
    else: s.add((L[t[4]], int(t[0]) // S, int(t[1]) // S))
nog = [n for n in need if n not in seen]
for n in nog: check(n, set())
print(f'pins checked {ok + miss}: covered {ok}, not covered {miss}; nets with pins but no guide {len(nog)}')
from collections import Counter
print('not covered by pin layer:', Counter(tuple(m[2]) for m in out).most_common(8))
for m in out[:10]: print('  ', *m)
if len(sys.argv) > 3:
    with open(sys.argv[3], 'w') as f:
        for m in out: f.write('\t'.join([m[0], m[1], ','.join(map(str, m[2]))] + [str(v) for v in m[3]]) + '\n')
