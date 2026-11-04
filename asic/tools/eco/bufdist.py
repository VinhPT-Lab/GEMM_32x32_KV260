#!/usr/bin/env python3
"""A: where the new buffers sit relative to the real wire of the net they split.
Each new buffer is traced back (through new nets) to the listed net it came from;
the distance is from the buffer origin to the nearest wire segment of that net in
the input DEF (all layers).
usage: bufdist.py in.def topo.tsv newbufs.tsv out.tsv"""
import re, sys, math
from collections import defaultdict
dfn, topo, newb, out = sys.argv[1:5]
nets = {}; insts = {}
for l in open(topo):
    t = l.rstrip('\n').split('\t')
    if t[0] == 'INST': insts[t[1]] = (t[2], int(t[3]), int(t[4]))
    else: nets[t[1]] = t[2].split() if len(t) > 2 else []
buf = {}
for l in open(newb):
    t = l.rstrip('\n').split('\t'); buf[t[0]] = (t[1], int(t[2]), int(t[3]), t[4], t[5])
new_names = set(insts)
drv_of = {}   # net -> new instance driving it
for n, pins in nets.items():
    for p in pins:
        i, pin = p.rsplit('/', 1)
        if i in new_names and pin == 'X': drv_of[n] = i
inp = {}
for n, pins in nets.items():
    for p in pins:
        i, pin = p.rsplit('/', 1)
        if i in new_names and pin == 'A': inp[i] = n
def root(i):
    n = inp[i]; seen = 0
    while n in drv_of and seen < 50:
        j = drv_of[n]
        if j not in inp: break
        n = inp[j]; seen += 1
    return n
fam = {i: root(i) for i in buf}
# a row buffer's own net lies between the macro pin and the buffer: use the net it drives
want = set(fam.values())
segs = defaultdict(list)
cur = None; insec = False
pt = re.compile(r'\(\s*(\S+)\s+(\S+)(?:\s+\S+)?\s*\)')
for line in open(dfn):
    if line.startswith('NETS '): insec = True; continue
    if not insec: continue
    if line.startswith('END NETS'): break
    s = line.strip()
    if s.startswith('- '):
        cur = s.split()[1]; cur = cur if cur in want else None; continue
    if cur is None: continue
    if 'ROUTED' in s or s.startswith('NEW'):
        px = py = None
        for x, y in pt.findall(s):
            x = px if x == '*' else int(x); y = py if y == '*' else int(y)
            if px is not None: segs[cur].append((px, py, x, y))
            else: segs[cur].append((x, y, x, y))
            px, py = x, y
def dist(x, y, s):
    x0, y0, x1, y1 = s
    dx, dy = x1 - x0, y1 - y0
    if dx == dy == 0: return math.hypot(x - x0, y - y0)
    t = max(0, min(1, ((x - x0) * dx + (y - y0) * dy) / (dx * dx + dy * dy)))
    return math.hypot(x - x0 - t * dx, y - y0 - t * dy)
with open(out, 'w') as f:
    for i, (m, x, y, a, o) in sorted(buf.items()):
        n = fam[i]; ss = segs.get(n, [])
        d = min((dist(x, y, s) for s in ss), default=float('nan')) / 1000.0
        f.write(f'{i}\t{m}\t{x/1000:.2f}\t{y/1000:.2f}\t{n}\t{d:.2f}\n')
ds = sorted(float(l.split('\t')[5]) for l in open(out) if l.split('\t')[5].strip() != 'nan')
print(f'BUFDIST {len(buf)} buffers, {len(ds)} with a wire to compare: distance to the wire min {ds[0]:.2f} median {ds[len(ds)//2]:.2f} p90 {ds[int(len(ds)*0.9)]:.2f} max {ds[-1]:.2f} um')
