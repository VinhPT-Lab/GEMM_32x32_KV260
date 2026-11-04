#!/usr/bin/env python3
"""spot_check.rpt: per window, error boxes within 0.5 um of the clip edge (clip artefacts,
as magic_macro_check counts them) and boxes inside; inside boxes are listed by rule."""
import sys, re, collections
win = None; res = collections.OrderedDict()
for l in open(sys.argv[1]):
    m = re.match(r'window (\S+) \[([-\d.]+), ([-\d.]+), ([-\d.]+), ([-\d.]+)\]', l)
    if m: win = m.group(1); box = [float(m.group(i)) for i in range(2, 6)]; res[win] = [box, 0, collections.Counter(), []]; continue
    m = re.match(r'\s+(.*?)\s+\(([-\d.]+), ([-\d.]+)\) - \(([-\d.]+), ([-\d.]+)\)', l)
    if m and win:
        x0, y0, x1, y1 = (float(m.group(i)) for i in range(2, 6)); b = res[win][0]
        if x0 <= b[0] + 0.5 or y0 <= b[1] + 0.5 or x1 >= b[2] - 0.5 or y1 >= b[3] - 0.5: res[win][1] += 1
        else: res[win][2][m.group(1)] += 1; res[win][3].append((x0, y0, x1, y1))
tot = 0
for w, (b, edge, inside, boxes) in res.items():
    n = sum(inside.values()); tot += n
    print(f'SPOT {w}: edge {edge}, inside {n}' + (f' {dict(inside)} first {boxes[:2]}' if n else ''))
print(f'SPOT windows {len(res)}, boxes inside (real) {tot}')
