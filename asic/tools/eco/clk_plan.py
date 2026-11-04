#!/usr/bin/env python3
"""B: clock repeaters on the real wires of the leaf-level clock nets (pure Python).

For every net: the routed wire of the DEF is turned into a graph (segments split at
every node lying on them, vias between layers, pins attached to the wire inside their
shape), rooted at the driver pin. Delay to a sink is Elmore on that tree, with R per
layer from the tech LEF and C per layer from the tech LEF times KC.

calib: on every clknet_9_* net, fit KC and A in  slew_sink^2 = slew_drv^2 + (A*Elmore)^2
       against the slews STA reports with the SPEF extracted by OL1 (SS RC max), and
       check the lib table of the driver against its STA output slew.
plan:  bottom-up on each tree in scope: a subtree whose sinks would see a slew over the
       target (SS, with 20 % margin on load) from the driver feeding it gets a clkbuf at
       the branch point that leads to it (the tree node where it leaves the rest); long
       edges are cut every STEP um so a repeater can also go on a long run. Buffer size:
       the smallest clkbuf (2/4/8/16) meeting the target with the load x 1.2. Antenna
       diodes of the nets in scope are removed (the antenna loop puts back what is needed).
       Writes a topology for s7_apply.py (INST / NET / DEL rows) and a report.
usage: clk_plan.py calib|plan DEF PINS SS_CLK_TSV SCOPE_NETS OUT [KC A]
env: TGT_SRAM, TGT_OTHER (ns at SS), KEEP_DIODES=1 (no diode removal)
"""
import sys, os, re, math, collections, heapq
mode, DEF, PINS, CLK, SCOPE, OUT = sys.argv[1:7]
KC = float(sys.argv[7]) if len(sys.argv) > 7 else 1.0
A = float(sys.argv[8]) if len(sys.argv) > 8 else 2.2
L = os.path.join(os.environ['PDK_ROOT'], 'sky130A', 'libs.ref')
TLEF = f'{L}/sky130_fd_sc_hd/techlef/sky130_fd_sc_hd__nom.tlef'
SSLIB = f'{L}/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__ss_100C_1v60.lib'
SRAMLIB = f'{L}/sky130_sram_macros/lib/sky130_sram_2kbyte_1rw1r_32x512_8_TT_1p8V_25C.lib'
LAYERS = ['li1', 'met1', 'met2', 'met3', 'met4', 'met5']
LI = {n: i for i, n in enumerate(LAYERS)}
STEP = 50.0          # um, longest tree edge (so repeaters can sit on long runs)
TGT = {'sram': float(os.environ.get('TGT_SRAM', 0.80)), 'other': float(os.environ.get('TGT_OTHER', 1.20))}   # ns at SS, 20 % under the 1.0 / 1.5 limits
KEEP_DIODES = os.environ.get('KEEP_DIODES') == '1'   # diodes stay, as sinks of their branch
SIZES = ['sky130_fd_sc_hd__clkbuf_2', 'sky130_fd_sc_hd__clkbuf_4', 'sky130_fd_sc_hd__clkbuf_8', 'sky130_fd_sc_hd__clkbuf_16']

# ---- tech LEF: per-layer R (kOhm/um), C (pF/um), via R, via layers
lay = {}; vias = {}; cur = None; kind = None
for line in open(TLEF):
    t = line.split()
    if not t: continue
    if t[0] == 'LAYER' and len(t) == 2 and kind is None: cur = t[1]; kind = 'L'; lay[cur] = {}; continue
    if t[0] == 'VIA' and len(t) in (2, 3) and t[-1] != ';' and kind is None: cur = t[1]; kind = 'V'; vias[cur] = []; continue
    if t[0] == 'END' and len(t) > 1 and t[1] == cur: kind = None; cur = None; continue
    if kind == 'L':
        if t[0] in ('WIDTH', 'RESISTANCE', 'CAPACITANCE', 'EDGECAPACITANCE') and len(t) > 2 and t[1] not in ('RPERSQ', 'CPERSQDIST'):
            try:
                if t[0] not in lay[cur]: lay[cur][t[0]] = float(t[1])
            except ValueError: pass
        if t[0] in ('RESISTANCE', 'CAPACITANCE') and len(t) > 2 and t[1] in ('RPERSQ', 'CPERSQDIST'):
            lay[cur][t[0]] = float(t[2])
    elif kind == 'V' and t[0] == 'LAYER':
        vias[cur].append(t[1])
R = {}; C = {}
for n in LAYERS:
    w = lay[n]['WIDTH']; R[n] = lay[n]['RESISTANCE'] / w / 1000.0
    C[n] = lay[n]['CAPACITANCE'] * w + 2 * lay[n].get('EDGECAPACITANCE', 0)
VR = {'mcon': lay['mcon'].get('RESISTANCE', 9.3) / 1000.0}
for v in ('via', 'via2', 'via3', 'via4'): VR[v] = lay[v].get('RESISTANCE', 4.5) / 1000.0
CUT_OF = {('li1', 'met1'): 'mcon', ('met1', 'met2'): 'via', ('met2', 'met3'): 'via2', ('met3', 'met4'): 'via3', ('met4', 'met5'): 'via4'}

# ---- DEF: vias of the DEF, components, routing of the wanted nets
scope = [l.strip() for l in open(SCOPE) if l.strip()]
if mode == 'calib':
    want = None
else:
    want = set(scope)
def wanted(n): return n.startswith('clknet_9_') if want is None else n in want
if mode == 'graph': want = set(scope)
comps = {}; nets = {}; sec = None; cur = None; buf = []
dvia = None
for line in open(DEF):
    if line.startswith('VIAS '): sec = 'V'; continue
    if line.startswith('END VIAS'): sec = None; continue
    if line.startswith('COMPONENTS '): sec = 'C'; continue
    if line.startswith('END COMPONENTS'): sec = None; continue
    if line.startswith('NETS '): sec = 'N'; continue
    if line.startswith('END NETS'): break
    if sec == 'V':
        s = line.split()
        if s and s[0] == '-': dvia = s[1]; vias[dvia] = []
        for m in re.finditer(r'\+ (?:RECT|POLYGON) (\S+)', line): vias[dvia].append(m.group(1))
        m = re.search(r'\+ LAYERS (\S+) (\S+) (\S+)', line)
        if m: vias[dvia] += [m.group(1), m.group(2), m.group(3)]
    elif sec == 'C':
        s = line.split()
        if s and s[0] == '-':
            comps[s[1]] = s[2]
    elif sec == 'N':
        s = line.strip()
        if s.startswith('- '):
            nm = s.split()[1]; cur = nm if wanted(nm) else None
            if cur: nets[cur] = []
        if cur: nets[cur].append(s)
        if s.endswith(';'): cur = None
def via_pair(v):
    ls = sorted({x for x in vias.get(v, []) if x in LI}, key=lambda x: LI[x])
    return (ls[0], ls[-1]) if len(ls) >= 2 else None

def parse_routing(lines):
    """segments [(layer, x0, y0, x1, y1)] and vias [(x, y, lbot, ltop)] in dbu"""
    text = ' '.join(lines)
    i = text.find('+ ROUTED')
    if i < 0: return [], []
    text = text[i + len('+ ROUTED'):]
    text = re.split(r'\+ (?:USE|SOURCE|WEIGHT|PROPERTY)', text)[0]
    segs = []; vs = []
    for part in re.split(r'\bNEW\b', text):
        tk = part.replace('(', ' ( ').replace(')', ' ) ').replace(';', ' ').split()
        if not tk: continue
        layer = tk[0]; j = 1; px = py = None
        while j < len(tk):
            t = tk[j]
            if t == '(':
                k = tk.index(')', j); vals = tk[j + 1:k]
                if px is None and vals[0] == '*': j = k + 1; continue
                x = px if vals[0] == '*' else int(vals[0]); y = py if vals[1] == '*' else int(vals[1])
                if px is not None and layer in LI and (x, y) != (px, py): segs.append((layer, px, py, x, y))
                px, py = x, y; j = k + 1
            elif t == 'RECT':
                k = tk.index(')', j); j = k + 1
            elif t in ('MASK', 'TAPER', 'TAPERRULE', 'STYLE'):
                j += 2
            elif t in vias or via_pair(t):
                vp = via_pair(t)
                if vp and px is not None:
                    vs.append((px, py, vp[0], vp[1]))
                    layer = vp[1] if layer == vp[0] else vp[0]
                j += 1
            else:
                j += 1
    return segs, vs

# ---- pins of the wanted nets
pins = collections.defaultdict(list)
for line in open(PINS):
    t = line.rstrip('\n').split('\t')
    if wanted(t[0]): pins[t[0]].append((t[2], t[3], int(t[4]), int(t[5]), int(t[6]), int(t[7])))

# ---- lib: pin caps and clkbuf tables (SS)
def read_lib(fn, cells_wanted=None):
    """pin caps of every cell; for cells_wanted the X-pin tables into tbl_lines"""
    out = {}; cur = None; pin = None; tbl = None; idx = {}; vals = None
    for line in open(fn):
        m = re.match(r'\s*cell\s*\(\s*"?([^")]+)"?\s*\)', line)
        if m: cur = m.group(1); out[cur] = {'cap': {}}; pin = None; tbl = None; continue
        if cur is None: continue
        m = re.match(r'\s*(?:pin|bus)\s*\(\s*"?([^")]+)"?\s*\)', line)
        if m: pin = m.group(1); continue
        m = re.match(r'\s*capacitance\s*:\s*([\d.eE+-]+)', line)
        if m and pin and pin not in out[cur]['cap']: out[cur]['cap'][pin] = float(m.group(1))
        if not cells_wanted or cur not in cells_wanted: continue
        m = re.match(r'\s*(rise_transition|fall_transition|cell_rise|cell_fall)\s*\(', line)
        if m: tbl = m.group(1); idx = {}; vals = None; continue
        if tbl is None: continue
        m = re.match(r'\s*index_(\d)\s*\("([^"]*)"\)', line)
        if m: idx[m.group(1)] = [float(x) for x in m.group(2).split(',')]; continue
        if vals is None and 'values' in line: vals = []
        if vals is not None:
            for v in re.findall(r'"([^"]*)"', line): vals.append([float(x) for x in v.split(',')])
            if ');' in line:
                tbl_lines[(cur, pin, tbl)] = [idx['1'], idx['2'], vals]; tbl = None; vals = None
    return out
tbl_lines = {}
std = read_lib(SSLIB, set(SIZES))
sram = read_lib(SRAMLIB)
# input caps of the hierarchical macros (the AXI shell clock pin alone is 0.31 pF)
macro_cap = collections.defaultdict(dict)
for mf in ('GemmAxiShell', 'ProcessingElementRow'):
    cur_pin = None
    for line in open(f"{os.environ['ECO_DIR']}/lib/{mf}.lib"):
        mm = re.match(r'\s*pin\s*\(\s*"?([^")]+)"?\s*\)', line)
        if mm: cur_pin = mm.group(1); continue
        mm = re.match(r'\s*capacitance\s*:\s*([\d.eE+-]+)', line)
        if mm and cur_pin: macro_cap[mf][cur_pin] = float(mm.group(1)); cur_pin = None
def pin_cap(inst, pin):
    m = comps.get(inst)
    if m is None: return 0.002
    if m in macro_cap: return macro_cap[m].get(pin, 0.002)
    lib = std if m in std else sram
    c = lib.get(m, {}).get('cap', {})
    return c.get(pin, c.get(re.sub(r'\[\d+\]$', '', pin), 0.002))
def interp(ax, v):
    if v <= ax[0]: i = 0
    elif v >= ax[-1]: i = len(ax) - 2
    else: i = max(k for k in range(len(ax) - 1) if ax[k] <= v)
    return i, (v - ax[i]) / (ax[i + 1] - ax[i])
def lookup(cell, kind, sin, load):
    vals = []
    for t in (kind[0], kind[1]):
        i1, i2, rows = tbl_lines[(cell, 'X', t)]
        a, fa = interp(i1, sin); b, fb = interp(i2, load)
        v = (rows[a][b] * (1 - fa) * (1 - fb) + rows[a + 1][b] * fa * (1 - fb) + rows[a][b + 1] * (1 - fa) * fb + rows[a + 1][b + 1] * fa * fb)
        vals.append(v)
    return max(vals)
def drv_slew(cell, sin, load): return lookup(cell, ('rise_transition', 'fall_transition'), sin, load)
def drv_delay(cell, sin, load): return lookup(cell, ('cell_rise', 'cell_fall'), sin, load)
BUF_A = {c: std[c]['cap']['A'] for c in SIZES}

# ---- graph of one net
def build(net):
    segs, vs = parse_routing(nets[net])
    nodes_on = collections.defaultdict(set)   # layer -> {(x, y)}
    for l, x0, y0, x1, y1 in segs: nodes_on[l].add((x0, y0)); nodes_on[l].add((x1, y1))
    for x, y, a, b in vs: nodes_on[a].add((x, y)); nodes_on[b].add((x, y))
    pl = pins[net]
    adj = collections.defaultdict(dict)
    def add(u, v, r, c, ln):
        if u == v: return
        if v in adj[u] and adj[u][v][0] <= r: return
        adj[u][v] = (r, c, ln); adj[v][u] = (r, c, ln)
    for l, x0, y0, x1, y1 in segs:
        pts = [(x0, y0), (x1, y1)]
        lo_x, hi_x = min(x0, x1), max(x0, x1); lo_y, hi_y = min(y0, y1), max(y0, y1)
        for (x, y) in nodes_on[l]:
            if lo_x <= x <= hi_x and lo_y <= y <= hi_y and (x0 == x1 == x or y0 == y1 == y): pts.append((x, y))
        pts = sorted(set(pts), key=lambda p: (p[0] - x0) ** 2 + (p[1] - y0) ** 2)
        for p, q in zip(pts, pts[1:]):
            ln = (abs(p[0] - q[0]) + abs(p[1] - q[1])) / 1000.0
            # cut long pieces so a repeater can sit on a long run
            k = max(1, int(math.ceil(ln / STEP)))
            prev = (p[0], p[1], l)
            for s in range(1, k + 1):
                nx = p[0] + (q[0] - p[0]) * s // k; ny = p[1] + (q[1] - p[1]) * s // k
                nxt = (nx, ny, l) if s < k else (q[0], q[1], l)
                add(prev, nxt, R[l] * ln / k, C[l] * ln / k, ln / k); prev = nxt
    for x, y, a, b in vs:
        cut = CUT_OF.get((a, b))
        # a stacked via written once (e.g. met1 -> met3) is split per cut
        ia, ib = LI[a], LI[b]
        for i in range(ia, ib):
            add((x, y, LAYERS[i]), (x, y, LAYERS[i + 1]), VR[CUT_OF[(LAYERS[i], LAYERS[i + 1])]], 0.0, 0.0)
    # attach pins: a node inside the pin shape on its layer or the next one
    attach = {}; far = []
    allnodes = list(adj)
    for name, layer, x0, y0, x1, y1 in pl:
        # the pin shape itself conducts: the router may land two vias on one pin
        # (e.g. li1 of a diode or cell pin) and use the pin as the wire between them
        inside = sorted(n for n in allnodes if n[2] == layer
                        and x0 - 200 <= n[0] <= x1 + 200 and y0 - 200 <= n[1] <= y1 + 200)
        for p, q in (zip(inside, inside[1:]) if os.environ.get("PINWIRE", "1") == "1" else ()):
            ln = (abs(p[0] - q[0]) + abs(p[1] - q[1])) / 1000.0
            add(p, q, R[layer] * ln, C[layer] * ln, ln)
        best = None
        cand = [n for n in allnodes if n[2] in (layer, LAYERS[min(LI.get(layer, 0) + 1, 5)])
                and x0 - 200 <= n[0] <= x1 + 200 and y0 - 200 <= n[1] <= y1 + 200]
        if cand: best = cand[0]; d = 0.0
        else:
            cx, cy = (x0 + x1) // 2, (y0 + y1) // 2
            if allnodes:
                best = min(allnodes, key=lambda n: abs(n[0] - cx) + abs(n[1] - cy))
                d = (abs(best[0] - cx) + abs(best[1] - cy)) / 1000.0
        if best is None: far.append((name, None)); continue
        if d > 2.0: far.append((name, d))
        attach[name] = best
    return adj, attach, far

def tree(adj, root):
    """shortest-resistance tree from root: parent map and children lists"""
    dist = {root: 0.0}; par = {root: None}; pq = [(0.0, root)]
    while pq:
        d, u = heapq.heappop(pq)
        if d > dist[u]: continue
        for v, (r, c, ln) in adj[u].items():
            nd = d + r + 1e-9
            if nd < dist.get(v, 1e18): dist[v] = nd; par[v] = u; heapq.heappush(pq, (nd, v))
    ch = collections.defaultdict(list)
    for v, u in par.items():
        if u is not None: ch[u].append(v)
    return par, ch

def kind_of(pin):
    i, p = pin.rsplit('/', 1)
    m = comps.get(i, '')
    if m.startswith('sky130_sram'): return 'sram'
    if m == 'GemmAxiShell' and p == 'S_AXI_ACLK': return 'sram'   # same 1.0 ns SS target as SRAM clocks
    if 'diode' in m: return 'diode'
    return 'other'

# ---- STA data
sta = collections.defaultdict(dict); drv_of = {}
for line in open(CLK):
    t = line.rstrip('\n').split('\t')
    if not wanted(t[0]) or t[11] == 'nan': continue
    sta[t[0]][t[4]] = float(t[11])
    if t[6] == 'output': drv_of[t[0]] = t[4]

def elmore(adj, attach, par, ch, root, kc, sinkcaps):
    """Elmore delay from root to every node; downstream cap per node"""
    order = []; st = [root]
    while st:
        u = st.pop(); order.append(u); st.extend(ch[u])
    cdown = collections.defaultdict(float)
    for pn, n in attach.items():
        cdown[n] += sinkcaps.get(pn, 0.0)
    for u in reversed(order):
        for v in ch[u]:
            r, c, ln = adj[u][v]; cdown[u] += cdown[v] + c * kc
    D = {root: 0.0}
    for u in order:
        for v in ch[u]:
            r, c, ln = adj[u][v]; D[v] = D[u] + r * (c * kc / 2 + cdown[v])
    return D, cdown

if mode == 'graph':
    # connectivity check: every pin of the net must reach the driver on the wire graph
    bad = 0; fo = open(OUT + '.graph.tsv', 'w')
    for net in [n for n in scope if n in nets]:
        adj, attach, far = build(net)
        drvp = [p for p, *_ in pins[net] if p in drv_of.values()] or [drv_of.get(net)]
        d = drv_of.get(net) or next(iter(attach))
        root = attach.get(d)
        seen = set([root]); st = [root]
        while st:
            u = st.pop()
            for v in adj[u]:
                if v not in seen: seen.add(v); st.append(v)
        npins = len(pins[net]); onp = sum(1 for p in attach if attach[p] in seen)
        lost = [p for p in attach if attach[p] not in seen] + [p for p, *_ in pins[net] if p not in attach]
        if lost: bad += 1
        fo.write(f'{net}\t{npins}\t{onp}\t{" ".join(lost)}\n')
        if lost and os.environ.get('VERBOSE'):
            for p in lost:
                n_ = attach.get(p)
                sh = [x for x in pins[net] if x[0] == p][0]
                near = min(seen, key=lambda q: abs(q[0] - n_[0]) + abs(q[1] - n_[1])) if n_ else None
                print(f'GRAPH {net} {p}: shape {sh[1:]}, attached {n_}, comp size {sum(1 for q in adj if q == n_)}, nearest driver-side node {near}')
    print(f'GRAPH {len(scope)} nets checked, {bad} with pins off the driver graph')
    sys.exit(0)
if mode == 'calib':
    rows = []; skipped = 0; far_all = 0; drvchk = []
    for net in sorted(nets):
        if net not in drv_of or net not in sta: skipped += 1; continue
        adj, attach, far = build(net); far_all += len(far)
        d = drv_of[net]
        if d not in attach: skipped += 1; continue
        root = attach[d]; par, ch = tree(adj, root)
        sinks = [p for p in attach if p != d and p in sta[net] and attach[p] in par]
        caps = {p: pin_cap(*p.rsplit('/', 1)) for p in attach if p != d}
        rows.append((net, d, sinks, adj, attach, par, ch, root, caps))
    print(f'CALIB nets {len(rows)}, skipped {skipped}, pins attached further than 2 um or not at all: {far_all}')
    best = None
    for kc in [1 + 0.1 * i for i in range(0, 41)]:
        xs = []; ys = []
        for net, d, sinks, adj, attach, par, ch, root, caps in rows:
            D, cd = elmore(adj, attach, par, ch, root, kc, caps)
            sd = sta[net][d]
            for p in sinks:
                y2 = sta[net][p] ** 2 - sd ** 2
                xs.append(D[attach[p]]); ys.append(math.sqrt(max(y2, 0.0)))
        sxy = sum(x * y for x, y in zip(xs, ys)); sxx = sum(x * x for x in xs)
        a = sxy / sxx if sxx else 0
        res = [y - a * x for x, y in zip(xs, ys)]
        err = math.sqrt(sum(r * r for r in res) / len(res))
        if best is None or err < best[2]: best = (kc, a, err, xs, ys)
    kc, a, err, xs, ys = best
    # error in slew itself on the sinks whose STA slew > 0.5 ns
    big = []
    for net, d, sinks, adj, attach, par, ch, root, caps in rows:
        D, cd = elmore(adj, attach, par, ch, root, kc, caps); sd = sta[net][d]
        for p in sinks:
            pred = math.sqrt(sd ** 2 + (a * D[attach[p]]) ** 2); m = sta[net][p]
            if m > 0.5: big.append(pred / m)
        # driver: lib table at the modelled load against the STA output slew
        drv_cell = comps[d.rsplit('/', 1)[0]]
        if drv_cell in SIZES: drvchk.append(drv_slew(drv_cell, 0.15, cd[root]) / sd)
    big.sort(); drvchk.sort()
    print(f'CALIB best KC {kc:.2f}, A {a:.3f}, rms error of the wire term {err:.3f} ns over {len(xs)} sinks')
    if big: print(f'CALIB predicted/STA slew on {len(big)} sinks over 0.5 ns: min {big[0]:.2f} median {big[len(big)//2]:.2f} p95 {big[int(len(big)*0.95)]:.2f} max {big[-1]:.2f}')
    if drvchk: print(f'CALIB driver slew lib(load model)/STA on {len(drvchk)} nets: min {drvchk[0]:.2f} median {drvchk[len(drvchk)//2]:.2f} max {drvchk[-1]:.2f}')
    sys.exit(0)

# ---- plan
topo_i = []; topo_n = {}; dels = []; rep = open(OUT + '.plan.tsv', 'w'); k = 0
existing = set(comps)
def newname():
    global k
    while f'eco_clk_{k}' in existing: k += 1
    n = f'eco_clk_{k}'; existing.add(n); k += 1; return n
tot = collections.Counter()
for net in scope:
    adj, attach, far = build(net)
    d = drv_of[net]; root = attach[d]
    par, ch = tree(adj, root)
    dio = [] if KEEP_DIODES else [p for p in attach if kind_of(p) == 'diode']
    for p in dio: dels.append(p.rsplit('/', 1)[0])
    sinks = [p for p in attach if p != d and (KEEP_DIODES or kind_of(p) != 'diode')]
    lost = [p for p in sinks if attach[p] not in par]
    if lost or far: print(f'PLAN {net}: pins not on the tree {lost[:3]}, far {far[:3]}')
    caps = {p: pin_cap(*p.rsplit('/', 1)) for p in sinks}
    at = collections.defaultdict(list)
    for p in sinks: at[attach[p]].append(p)
    # bottom-up: region[u] = (list of (sink pin, elmore from u), cap below u)
    order = []; st = [root]
    while st:
        u = st.pop(); order.append(u); st.extend(ch[u])
    region = {}
    bufs = []   # (node, cell, sinks driven)
    def worst(reg_sinks, load, cell, sin):
        """predicted SS slew at each sink of a region driven at its root"""
        s0 = drv_slew(cell, sin, load * 1.2)
        return [(p, math.sqrt(s0 ** 2 + (A * dl) ** 2)) for p, dl in reg_sinks]
    def ok(reg_sinks, load, cell, sin=0.3):
        return all(s <= TGT['sram' if kind_of(p) == 'sram' else 'other'] for p, s in worst(reg_sinks, load, cell, sin))
    def pick(reg_sinks, load, sin=0.3):
        for c in SIZES:
            if ok(reg_sinks, load, c, sin): return c
        return None
    for u in reversed(order):
        items = []   # per child: (sinks with elmore from u, cap seen at u)
        own = [(p, 0.0) for p in at.get(u, [])]
        cap_own = sum(caps[p] for p in at.get(u, []))
        for v in ch[u]:
            r, c, ln = adj[u][v]; sv, cv = region[v]
            cin = c * KC + cv
            items.append([v, [(p, dl + r * (c * KC / 2 + cv)) for p, dl in sv], cin])
        while True:
            reg = own + [x for it in items for x in it[1]]
            load = cap_own + sum(it[2] for it in items)
            if not reg or ok(reg, load, 'sky130_fd_sc_hd__clkbuf_16', 0.3):
                break
            # split off the child with the latest sink: a clkbuf at u drives it
            cand = [it for it in items if it[1]]
            if not cand: break
            it = max(cand, key=lambda z: max(dl for p, dl in z[1]))
            sv_child = [(p, dl) for p, dl in it[1]]
            c_load = it[2]
            # the buffer input sits at u; its sinks keep their elmore measured from u
            cell = pick(sv_child, c_load) or 'sky130_fd_sc_hd__clkbuf_16'
            bname = newname()
            bufs.append((u, cell, [p for p, dl in sv_child], bname))
            items.remove(it)
            own.append((bname + '/A', 0.0)); caps[bname + '/A'] = BUF_A[cell]; cap_own += BUF_A[cell]
            at[u].append(bname + '/A')
            if len(bufs) > 60: break
        region[u] = (own + [x for it in items for x in it[1]], cap_own + sum(it[2] for it in items))
    # topology: driver net keeps the sinks not behind a buffer; each buffer gets a new net
    behind = {}
    for u, cell, sv, bname in bufs:
        for p in sv: behind.setdefault(p, bname)
    # a sink behind nested buffers belongs to the innermost one (the first made, bottom-up)
    nets_new = collections.defaultdict(list)
    drv_net = [d]
    for p in sinks + [b[3] + '/A' for b in bufs]:
        b = behind.get(p)
        if b is None: drv_net.append(p)
        else: nets_new[b].append(p)
    topo_n[net] = drv_net
    for u, cell, sv, bname in bufs:
        topo_i.append((bname, cell, u[0], u[1]))
        topo_n[bname + '_net'] = [bname + '/X'] + nets_new[bname]
        tot[cell] += 1
    reg_root, load_root = region[root]
    dcell = comps[d.rsplit('/', 1)[0]]
    w = worst(reg_root, load_root, dcell, 0.3)
    rep.write(f'{net}\tdriver {dcell}\tsinks {len(sinks)}\tdiodes removed {len(dio)}\tbuffers {len(bufs)} '
              + ' '.join(f'{b[3]}:{b[1].split("__")[1]}@({b[0][0]/1000:.1f},{b[0][1]/1000:.1f}),{len(nets_new[b[3]])}' for b in bufs)
              + f'\tdriver region worst slew {max(s for p, s in w):.2f}\n')
rep.close()
with open(OUT + '.topo.tsv', 'w') as f:
    for b in topo_i: f.write(f'INST\t{b[0]}\t{b[1]}\t{b[2]}\t{b[3]}\n')
    for n, ps in topo_n.items(): f.write(f'NET\t{n}\t' + ' '.join(sorted(ps)) + '\n')
    for i in sorted(set(dels)): f.write(f'DEL\t{i}\n')
print(f'PLAN {len(scope)} nets: buffers {sum(tot.values())} {dict(tot)}; diodes removed {len(set(dels))}')
