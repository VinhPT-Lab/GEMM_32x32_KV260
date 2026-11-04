#!/usr/bin/env python3
"""Route guides for every routed net of a DEF, built from its own wires and vias.

usage: mkguide.py <in.def> <tech.lef> <out.guide> <stats.txt> [pins.tsv]

- GCell grid from the DEF GCELLGRID lines (ip_v3r: 6.9 um, origin 0).
- A wire segment on layer L covers every GCell its centre line passes, on L.
- A via covers the GCell of its point on both of its routing layers.
- li1 is below the signal routing range (met1-met5), so li1 shapes (L1M1_PR
  vias onto standard-cell pins) count on met1, like the GRT guides do.
- A coordinate on a GCell boundary covers the GCells on both sides.
- pins.tsv (optional, from guide_pins.tcl): net, layer, xlo, ylo, xhi, yhi of a
  pin of each net without wires; it gets the GCells under that pin, on its layer.
Output: one GCell box per line, "xlo ylo xhi yhi layer", per net in
"name ( ... )" blocks (format of read_guides). Every net with a wire or a pin
listed gets at least one box; stats.txt lists counts and nets left empty.
"""
import re, sys
from collections import defaultdict

def_path, lef_path, out_path, stats_path = sys.argv[1:5]
pins_path = sys.argv[5] if len(sys.argv) > 5 else None
ROUTING = ['li1', 'met1', 'met2', 'met3', 'met4', 'met5']
def clamp(l):
    return 'met1' if l == 'li1' else l

# via name -> (bottom routing layer, top routing layer), from the tech LEF and DEF VIAS
via_layers = {}
cur = None; lays = []
for line in open(lef_path):
    t = line.split()
    if not t: continue
    if t[0] == 'VIA' and len(t) >= 2: cur, lays = t[1], []
    elif cur and t[0] == 'LAYER': lays.append(t[1])
    elif cur and t[0] == 'END' and len(t) > 1 and t[1] == cur:
        r = [l for l in lays if l in ROUTING]
        if len(r) >= 2: via_layers[cur] = (r[0], r[-1])
        cur = None

gx = gy = None
def cells(lo, hi, origin, step, n):
    """GCell indices covered by [lo, hi] (boundary points cover both sides)."""
    if lo > hi: lo, hi = hi, lo
    a = (lo - origin) // step
    b = (hi - origin) // step
    if (lo - origin) % step == 0 and a > 0: a -= 1
    a = min(max(0, a), n - 1); b = min(max(0, b), n - 1)   # last GCell runs to the die edge
    return range(a, b + 1)

guides = {}            # net -> set((layer, ix, iy))
wire_len = defaultdict(int)
def add_seg(g, layer, x1, y1, x2, y2):
    layer = clamp(layer)
    for ix in cells(x1, x2, gx[0], gx[2], gx[1]):
        for iy in cells(y1, y2, gy[0], gy[2], gy[1]):
            g.add((layer, ix, iy))

PT = re.compile(r'\(\s*(-?\d+|\*)\s+(-?\d+|\*)(?:\s+(-?\d+))?\s*\)')
def parse_routing(name, text):
    g = guides.setdefault(name, set())
    for path in re.split(r'\bNEW\b', text):
        tok = path.replace('(', ' ( ').replace(')', ' ) ').split()
        if not tok: continue
        layer = tok[0]; i = 1
        x = y = None
        while i < len(tok):
            t = tok[i]
            if t == '(':
                j = tok.index(')', i)
                vals = tok[i + 1:j]
                nx = x if vals[0] == '*' else int(vals[0])
                ny = y if vals[1] == '*' else int(vals[1])
                if x is not None and (nx, ny) != (x, y):
                    add_seg(g, layer, x, y, nx, ny)
                    if layer in ROUTING[1:]:
                        wire_len[layer] += abs(nx - x) + abs(ny - y)
                else:
                    add_seg(g, layer, nx, ny, nx, ny)
                x, y = nx, ny
                i = j + 1
            elif t in ('RECT', 'VIRTUAL'):
                j = tok.index(')', i)
                if t == 'RECT' and x is not None:
                    v = [int(a) for a in tok[i + 2:j]]
                    add_seg(g, layer, x + v[0], y + v[1], x + v[2], y + v[3])
                elif t == 'VIRTUAL':
                    v = tok[i + 2:j]
                    x = x if v[0] == '*' else int(v[0]); y = y if v[1] == '*' else int(v[1])
                i = j + 1
            elif t in ('MASK', 'STYLE', 'TAPERRULE'):
                i += 2
            elif t in ('TAPER',) or re.fullmatch(r'[NSEW]|F[NSEW]', t):
                i += 1
            elif t in via_layers:
                lo, hi = via_layers[t]
                add_seg(g, lo, x, y, x, y); add_seg(g, hi, x, y, x, y)
                layer = hi if clamp(layer) == clamp(lo) else lo
                i += 1
            else:
                raise SystemExit(f'net {name}: unknown token {t!r} in {path[:200]!r}')

sec = None; buf = []
n_nets = 0
with open(def_path) as f:
    for line in f:
        s = line.strip()
        if s.startswith('GCELLGRID'):
            t = s.split()   # GCELLGRID X 0 DO 1054 STEP 6900 ;
            v = (int(t[2]), int(t[4]) - 1, int(t[6]))
            if t[1] == 'X': gx = v
            else: gy = v
            continue
        if sec is None:
            if s.startswith('NETS '): sec = 'N'
            continue
        if s.startswith('END NETS'): break
        if s.startswith('- '): buf = [s]
        else: buf.append(s)
        if s.endswith(';'):
            st = ' '.join(buf); buf = []
            name = st.split()[1]; n_nets += 1
            m = re.search(r'\+ (ROUTED|FIXED|COVER) ', st)
            if m:
                r = st[m.end():]
                r = re.split(r' \+ (?:USE|SOURCE|WEIGHT|PROPERTY|NONDEFAULTRULE|SHIELDNET)\b', r)[0].rstrip(' ;')
                parse_routing(name, r)
            else:
                guides.setdefault(name, set())

n_pin = 0
if pins_path:
    for line in open(pins_path):
        net, layer, *b = line.split('\t')
        b = [int(v) for v in b]
        g = guides.setdefault(net, set())
        if not g:
            add_seg(g, layer, b[0], b[1], b[2], b[3]); n_pin += 1

# Pieces joined only through a pin shape (li1 of one standard-cell pin, two L1M1
# vias in diagonal GCells) look apart in the wires: join every extra piece to the
# rest by the shortest Manhattan path of met1 GCells between their nearest GCells.
ORDER = {'met1': 1, 'met2': 2, 'met3': 3, 'met4': 4, 'met5': 5}
def pieces(g):
    seen = set(); out = []
    for c in g:
        if c in seen: continue
        comp = {c}; st = [c]; seen.add(c)
        while st:
            l, x, y = st.pop()
            z = ORDER[l]
            nb = [(l, x + 1, y), (l, x - 1, y), (l, x, y + 1), (l, x, y - 1)]
            nb += [(k, x, y) for k, v in ORDER.items() if abs(v - z) == 1]
            for d in nb:
                if d in g and d not in seen: seen.add(d); st.append(d); comp.add(d)
        out.append(comp)
    return out
n_joined = 0
for name, g in guides.items():
    if not g: continue
    ps = pieces(g)
    while len(ps) > 1:
        a = ps[0]; best = None
        for b in ps[1:]:
            for (la, xa, ya) in a:
                for (lb, xb, yb) in b:
                    d = abs(xa - xb) + abs(ya - yb)
                    if best is None or d < best[0]: best = (d, xa, ya, xb, yb)
        _, xa, ya, xb, yb = best
        for x in range(min(xa, xb), max(xa, xb) + 1): g.add(('met1', x, ya))
        for y in range(min(ya, yb), max(ya, yb) + 1): g.add(('met1', xb, y))
        for (l, x, y) in ((None, xa, ya), (None, xb, yb)):
            for k in ORDER:
                if (k, x, y) in g:
                    for k2 in ORDER:   # stack up to the layer present at both ends
                        if ORDER[k2] <= ORDER[k]: g.add((k2, x, y))
        n_joined += 1
        ps = pieces(g)
empty = [n for n, g in guides.items() if not g]
nbox = 0
with open(out_path, 'w') as fo:
    for name, g in guides.items():
        if not g: continue
        fo.write(f'{name}\n(\n')
        for (l, ix, iy) in sorted(g):
            x0 = gx[0] + ix * gx[2]; y0 = gy[0] + iy * gy[2]
            fo.write(f'{x0} {y0} {x0 + gx[2]} {y0 + gy[2]} {l}\n'); nbox += 1
        fo.write(')\n')
with open(stats_path, 'w') as fo:
    fo.write(f'gcell grid x {gx} y {gy}\n')
    fo.write(f'nets in DEF {n_nets}; with guides {n_nets - len(empty)}; from pins only {n_pin}; boxes {nbox}\n')
    fo.write(f'wire length by layer (um): ' + ', '.join(f'{l} {v/1000:.0f}' for l, v in sorted(wire_len.items())) + '\n')
    fo.write(f'nets without any guide: {len(empty)}\n')
    fo.write(f'pieces joined through pin shapes: {n_joined}\n')
    for n in empty[:50]: fo.write(f'  {n}\n')
print(open(stats_path).read())
