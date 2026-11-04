#!/usr/bin/env python3
"""Static numbers of a placed-and-routed DEF: die / core / row area, density, cells by
master and by group, NAND2 equivalents, flops, wire length and vias per layer (signal NETS only, no power grid).

usage: static_stats.py <def> <tag> <out dir> [lef ...]
Writes <out>/<tag>_cells_by_master.csv, <tag>_groups.csv, <tag>_wires.csv, <tag>_summary.csv.
Sizes come from the LEFs (std cells, macros). The DEF is read as text, one pass.
"""
import sys, re, collections, csv, os

DEF, TAG, OUT = sys.argv[1:4]
LEFS = sys.argv[4:]
size = {}
for f in LEFS:
    cur = None
    for line in open(f, errors='replace'):
        m = re.match(r'\s*MACRO (\S+)', line)
        if m: cur = m.group(1); continue
        m = re.match(r'\s*SIZE ([\d.]+) BY ([\d.]+)', line)
        if m and cur and cur not in size: size[cur] = (float(m.group(1)), float(m.group(2)))

def group(name, master):
    """group of one top-level instance"""
    m = master.replace('sky130_fd_sc_hd__', '').replace('sky130_ef_sc_hd__', 'ef_')
    if master.startswith('sky130_sram'): return 'SRAM macro'
    if master == 'ProcessingElementRow': return 'row macro'
    if master == 'GemmAxiShell': return 'AXI macro'
    if m.startswith('fill') or m.startswith('decap') or m.startswith('ef_decap'): return 'filler/decap'
    if m.startswith('tap'): return 'tap'
    if m.startswith('diode'): return 'diode'
    if m.startswith('conb'): return 'tie'
    if name.startswith('eco_'): return 'ECO buffer'
    if name.startswith('hold') or m.startswith('dlygate') or m.startswith('clkdlybuf') or m.startswith('dlymetal'):
        return 'hold buffer'
    if name.startswith('clkbuf_') or name.startswith('clkload') or 'clkbuf' in m and name.startswith('clk'):
        return 'clock tree'
    if re.match(r'(wire|fanout|load_slew|max_cap|rebuffer|split|input|output)\d', name): return 'buffer (resizer / I/O)'
    if re.search(r'df|dl[xr]|latch|sdf', m): return 'flop/latch'
    return 'logic'

die = None; rows = []; comps = []; sec = None; dbu = 1000
wl = collections.Counter(); vias = collections.Counter(); via_cut = {}
cur_net_special = False
for line in open(DEF):
    if sec is None:
        if line.startswith('UNITS DISTANCE MICRONS'): dbu = int(line.split()[3])
        elif line.startswith('DIEAREA'):
            v = [int(x) for x in re.findall(r'-?\d+', line)]; die = (v[0], v[1], v[2], v[3])
        elif line.startswith('ROW '):
            t = line.split(); n = int(t[7]); step = int(t[11])
            rows.append((int(t[3]), int(t[4]), n * step))
        elif line.startswith('VIAS '): sec = 'V'
        elif line.startswith('COMPONENTS '): sec = 'C'
        elif line.startswith('NETS '): sec = 'N'
        elif line.startswith('SPECIALNETS '): sec = 'S'   # power grid: not counted
        continue
    if line.startswith('END '): sec = None; continue
    if sec == 'V':
        m = re.match(r'\s*- (\S+)', line)
        if m: vname = m.group(1); via_cut[vname] = []
        for mm in re.finditer(r'\+ (?:RECT|POLYGON) (\S+)', line): via_cut[vname].append(mm.group(1))
        mm = re.search(r'\+ LAYERS (\S+) (\S+) (\S+)', line)
        if mm: via_cut[vname] = [mm.group(2)]
    elif sec == 'C':
        m = re.match(r'\s*- (\S+) (\S+)', line)
        if m: comps.append((m.group(1), m.group(2)))
    elif sec == 'N':
        # every routed segment: "[NEW] layer [width] ( x y [ext] ) ( x y ) [via]"
        for part in re.split(r'\bNEW\b|\+ ROUTED|\+ FIXED|\+ COVER|\+ SHIELD', line):
            mm = re.match(r'\s*(met\d|li1)\s+(?:\d+\s+)?\(\s*(-?\d+)\s+(-?\d+)[^)]*\)\s*(?:\(\s*(\S+)\s+(\S+)[^)]*\))?\s*(\S+)?', part)
            if not mm: continue
            lay, x0, y0 = mm.group(1), int(mm.group(2)), int(mm.group(3))
            if mm.group(4):
                x1 = x0 if mm.group(4) == '*' else int(mm.group(4)); y1 = y0 if mm.group(5) == '*' else int(mm.group(5))
                wl[lay] += abs(x1 - x0) + abs(y1 - y0)
                v = mm.group(6)
            else:
                v = mm.group(6) if mm.group(6) and not mm.group(6).startswith('(') else None
            if v and v not in (';',) and not v.startswith('+') and not v.startswith('('):
                vias[v] += 1

os.makedirs(OUT, exist_ok=True)
um2 = lambda m: size[m][0] * size[m][1] if m in size else 0.0
bym = collections.Counter(m for n, m in comps)
miss = sorted(m for m in bym if m not in size)
with open(f'{OUT}/{TAG}_cells_by_master.csv', 'w', newline='') as f:
    w = csv.writer(f); w.writerow(['master', 'count', 'area_um2_each', 'area_um2_total', 'group'])
    gm = {}
    for n, m in comps: gm.setdefault(m, group(n, m))
    for m, c in bym.most_common():
        w.writerow([m, c, f'{um2(m):.4f}', f'{um2(m) * c:.2f}', gm[m] if m not in ('',) else ''])
gc = collections.Counter(); ga = collections.Counter()
for n, m in comps:
    g = group(n, m); gc[g] += 1; ga[g] += um2(m)
nand2 = um2('sky130_fd_sc_hd__nand2_1')
logic_groups = ['logic', 'flop/latch', 'tie', 'clock tree', 'hold buffer', 'ECO buffer', 'buffer (resizer / I/O)']
logic_area = sum(ga[g] for g in logic_groups)
flops = sum(1 for n, m in comps if group(n, m) == 'flop/latch' and re.search(r'df', m))
with open(f'{OUT}/{TAG}_groups.csv', 'w', newline='') as f:
    w = csv.writer(f); w.writerow(['group', 'cells', 'area_um2'])
    for g, c in gc.most_common(): w.writerow([g, c, f'{ga[g]:.2f}'])
# vias by cut layer
cut_of = {}
for v, lays in via_cut.items():
    cuts = [l for l in lays if l in ('mcon', 'via', 'via2', 'via3', 'via4')]
    cut_of[v] = cuts[0] if cuts else '?'
def cut_name(v):
    if v in cut_of: return cut_of[v]
    m = re.match(r'(L1M1|M1M2|M2M3|M3M4|M4M5)_', v)
    return {'L1M1': 'mcon', 'M1M2': 'via', 'M2M3': 'via2', 'M3M4': 'via3', 'M4M5': 'via4'}.get(m.group(1)) if m else v
vc = collections.Counter()
for v, c in vias.items(): vc[cut_name(v)] += c
with open(f'{OUT}/{TAG}_wires.csv', 'w', newline='') as f:
    w = csv.writer(f); w.writerow(['layer', 'wire_length_um', 'cut_above', 'vias'])
    for l, c in zip(['li1', 'met1', 'met2', 'met3', 'met4', 'met5'], ['mcon', 'via', 'via2', 'via3', 'via4', '']):
        w.writerow([l, f'{wl[l] / dbu:.1f}', c, vc.get(c, '') if c else ''])
die_um2 = (die[2] - die[0]) * (die[3] - die[1]) / dbu / dbu
row_h = 2.72
row_um2 = sum(L / dbu * row_h for x, y, L in rows)
xs = [x for x, y, L in rows] + [x + L for x, y, L in rows]; ys = [y for x, y, L in rows]
core_bbox = (min(xs), min(ys), max(xs), max(ys) + int(row_h * dbu))
core_um2 = (core_bbox[2] - core_bbox[0]) * (core_bbox[3] - core_bbox[1]) / dbu / dbu
macro_um2 = sum(ga[g] for g in ('SRAM macro', 'row macro', 'AXI macro'))
std_um2 = sum(a for g, a in ga.items() if g not in ('SRAM macro', 'row macro', 'AXI macro', 'filler/decap', 'tap'))
summ = [
    ('die_w_um', (die[2] - die[0]) / dbu), ('die_h_um', (die[3] - die[1]) / dbu), ('die_area_mm2', die_um2 / 1e6),
    ('core_bbox_area_mm2', core_um2 / 1e6), ('std_row_area_mm2', row_um2 / 1e6),
    ('macro_area_mm2', macro_um2 / 1e6),
    ('std_cell_area_no_fill_tap_mm2', std_um2 / 1e6),
    ('std_cell_density_in_rows', std_um2 / row_um2 if row_um2 else 0),
    ('logic_area_um2', logic_area), ('nand2_1_area_um2', nand2),
    ('nand2_equivalents', logic_area / nand2 if nand2 else 0), ('flops', flops),
    ('instances', len(comps)), ('masters_missing_size', ' '.join(miss)),
]
with open(f'{OUT}/{TAG}_summary.csv', 'w', newline='') as f:
    w = csv.writer(f); w.writerow(['metric', 'value'])
    for k, v in summ: w.writerow([k, f'{v:.4f}' if isinstance(v, float) else v])
for k, v in summ: print(f'STATIC {TAG} {k} {v:.4f}' if isinstance(v, float) else f'STATIC {TAG} {k} {v}')
