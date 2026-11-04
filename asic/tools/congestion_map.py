#!/usr/bin/env python3
"""
congestion_map.py <congestion.rpt> <macro.cfg> <row_w> <row_h>
Summarise an OpenROAD global-route congestion report (GRT-0119) by region of
the gemm_array floorplan and by layer, and list the nets seen most often.
"""
import re, sys, collections

rpt, mcfg, row_w, row_h = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
rows = sorted((float(l.split()[1]), float(l.split()[2])) for l in open(mcfg)
              if l.strip() and not l.startswith("#"))
x0 = rows[0][0]; x1 = x0 + row_w
ys = sorted(y for _, y in rows)          # row bottoms, lowest first
lo, hi = ys[0], ys[-1] + row_h

def region(x, y):
    if x < x0:
        return "left strip (FeatureSkew)"
    if x > x1:
        return "east strip"
    if y < lo:
        return "bottom (OutputDeskew)"
    if y > hi:
        return "top band (row 0 inputs)"
    for yb in ys:
        if yb <= y <= yb + row_h:
            return "over a row macro"
    return "channel between rows"

reg = collections.Counter(); lay = collections.Counter(); ovf = collections.Counter()
nets = collections.Counter(); regl = collections.Counter()
srcs, o = [], 0
for line in open(rpt):
    s = line.strip()
    if s.startswith("srcs:"):
        srcs = s[5:].split()
    m = re.search(r"overflow:\s*(\d+)", s)
    if m:
        o = int(m.group(1))
    m = re.search(r"bbox\s*=\s*\(\s*([-\d.]+)\s*,\s*([-\d.]+)\s*\)\s*-\s*\(\s*([-\d.]+)\s*,\s*([-\d.]+)\s*\)\s*on Layer\s*(\S+)", s)
    if m:
        xa, ya, xb, yb = map(float, m.groups()[:4]); L = m.group(5)
        r = region((xa + xb) / 2, (ya + yb) / 2)
        reg[r] += 1; lay[L] += 1; ovf[r] += o; regl[(r, L)] += 1
        for n in srcs:
            nets[re.sub(r"\[\d+\]", "[*]", n)] += 1
        srcs, o = [], 0

tot = sum(reg.values())
print(f"congested gcell edges: {tot}")
print("\nby region (count, total overflow):")
for r, c in reg.most_common():
    print(f"  {r:28s} {c:7d}  {ovf[r]:7d}   " + " ".join(f"{L}:{regl[(r, L)]}" for L in sorted(lay) if regl[(r, L)]))
print("\nby layer:", dict(lay.most_common()))
print("\nnets seen most (bus bits folded to [*]):")
for n, c in nets.most_common(25):
    print(f"  {c:7d}  {n}")
