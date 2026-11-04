#!/usr/bin/env python3
"""6c: buffer size for every BUFFER net of a plan (drv_plan.tcl), from the SS liberty:
the buffer drives the whole old net (load = net capacitance at SS RC max), its
input sits next to the driver (input slew taken as IN_SLEW ns). Worst sink slew
after = sqrt(buf_out^2 + wire^2), wire = sqrt(max(worst_sink^2 - drv_out^2, 0))
measured now (PERI-style split of driver and wire slew). Smallest buffer with
load <= max_capacitance / 1.2 and sink slew after <= sink limit / 1.2.
None: NOBUF (one buffer is not enough - reported, not split).
usage: drv_pick.py plan_raw.tsv plan.tsv"""
import re, sys, math
import os
LIB = os.path.join(os.environ['PDK_ROOT'], 'sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__ss_100C_1v60.lib')
BUFS = ['sky130_fd_sc_hd__buf_%d' % n for n in (1, 2, 4, 6, 8, 12)]   # buf_16 is DONT_USE
IN_SLEW = 0.3; M = 1.2

def cell_block(text, name):
    i = text.find('cell ("%s")' % name)
    depth = 0; j = text.index('{', i)
    for k in range(j, len(text)):
        if text[k] == '{': depth += 1
        elif text[k] == '}':
            depth -= 1
            if depth == 0: return text[i:k + 1]
def table(block, kind):
    m = re.search(kind + r'\s*\("[^"]*"\)\s*\{\s*index_1\s*\("([^"]*)"\);\s*index_2\s*\("([^"]*)"\);\s*values\s*\((.*?)\);', block, re.S)
    i1 = [float(v) for v in m.group(1).split(',')]; i2 = [float(v) for v in m.group(2).split(',')]
    rows = [[float(v) for v in r.split(',')] for r in re.findall(r'"([^"]*)"', m.group(3))]
    return i1, i2, rows
def interp(t, x, y):
    i1, i2, v = t
    def seg(a, q):
        for k in range(len(a) - 1):
            if q <= a[k + 1] or k == len(a) - 2: return k
    a = seg(i1, x); b = seg(i2, y)
    fx = (x - i1[a]) / (i1[a + 1] - i1[a]); fy = (y - i2[b]) / (i2[b + 1] - i2[b])
    return (v[a][b] * (1 - fx) * (1 - fy) + v[a + 1][b] * fx * (1 - fy) + v[a][b + 1] * (1 - fx) * fy + v[a + 1][b + 1] * fx * fy)

text = open(LIB).read()
buf = {}
for b in BUFS:
    blk = cell_block(text, b)
    px = blk[blk.index('pin ("X")'):]
    maxcap = float(re.search(r'max_capacitance\s*:\s*([\d.eE+-]+)', px).group(1))
    buf[b] = (maxcap, table(px, 'rise_transition'), table(px, 'fall_transition'))
    print(f'{b}: max_capacitance {maxcap:.4f} pF')

out = open(sys.argv[2], 'w'); stats = {}
for l in open(sys.argv[1]):
    t = l.rstrip('\n').split('\t')
    net, kind, drv, ref, load, dsv, dsl, dcl, ws, wl, action, cell = t
    if action == 'BUFFER':
        load = float(load) * 1e12   # Net_capacitance is in F, liberty in pF
        dsv = float(dsv) if dsv not in ('', '-') else 0.0
        ws = float(ws); wl = float(wl)
        wire = math.sqrt(max(ws * ws - dsv * dsv, 0.0))
        pick = None
        for b in BUFS:
            maxcap, tr, tf = buf[b]
            so = max(interp(tr, IN_SLEW, load), interp(tf, IN_SLEW, load))
            after = math.sqrt(so * so + wire * wire)
            if load * M <= maxcap and after * M <= wl:
                pick = (b, so, after); break
        if pick: action, cell = 'BUFFER', pick[0]
        else: action, cell = 'NOBUF', '-'
    stats[(kind, action)] = stats.get((kind, action), 0) + 1
    out.write('\t'.join([net, kind, drv, ref, str(load), str(dsv), dsl, dcl, str(ws), str(wl), action, cell]) + '\n')
out.close()
print('plan:', ', '.join(f'{k[0]} {k[1]} {v}' for k, v in sorted(stats.items())))
