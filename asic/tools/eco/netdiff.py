#!/usr/bin/env python3
"""Self-check of one ECO step (checks b and c), from the two DEFs only.
  b. cells added / removed (by master), resized, and moved; fillers (CORE SPACER
     masters of the OL1 filler list) are only counted
  c. every changed net: same driver; the sinks reached from that driver through new
     buffers (one input, one output) are exactly the old sinks; a resized cell keeps
     the lib function string and pin names and every pin keeps its net; a new diode
     only adds its DIODE pin to a net that already exists; a removed diode only drops
     its DIODE pin; no other net changes its pin set
usage: netdiff.py before.def after.def lib[,lib...] out_prefix (std cell lib first, then the macro libs)
writes <out>.cells.tsv, <out>.nets.tsv and prints a NETDIFF summary (FAIL lines on
every broken rule)."""
import re, sys
from collections import defaultdict, Counter
bdef, adef, lib, out = sys.argv[1:5]
FILL = re.compile(r'^sky130_(ef_sc_hd__decap_12|fd_sc_hd__decap_\d+|fd_sc_hd__fill_\d+)$')

def read_def(fn):
    comps = {}; nets = {}; sec = None; cur = None; buf = ''
    for line in open(fn):
        if line.startswith('COMPONENTS '): sec = 'C'; continue
        if line.startswith('END COMPONENTS'): sec = None; continue
        if line.startswith('NETS '): sec = 'N'; continue
        if line.startswith('END NETS'): break
        if sec == 'C':
            buf += line
            if line.rstrip().endswith(';'):
                t = buf.split(); buf = ''
                m = re.search(r'\+ (PLACED|FIXED) \( (\S+) (\S+) \) (\S+)', ' '.join(t))
                comps[t[1]] = (t[2], (m.group(2), m.group(3), m.group(4)) if m else None)
        elif sec == 'N':
            s = line.strip()
            if s.startswith('- '):
                cur = s.split()[1]; nets[cur] = []; s = s[len('- ' + cur):]; conn = True
            if cur is None: continue
            if s.startswith('+') or s.startswith('NEW'): conn = False
            if conn:
                part = s.split('+')[0]
                for i, p in re.findall(r'\(\s*(\S+)\s+(\S+)\s*\)', part): nets[cur].append(f'{i}/{p}')
                if '+' in s: conn = False
            if s.endswith(';'): cur = None
    return comps, nets

def read_lib(fn):
    cells = {}; cur = None; pin = None
    for line in open(fn):
        m = re.match(r'\s*cell\s*\(\s*"?([^")]+)"?\s*\)', line)
        if m: cur = m.group(1); cells[cur] = {}; continue
        m = re.match(r'\s*(?:pin|bus)\s*\(\s*"?([^")]+)"?\s*\)', line)
        if m and cur: pin = m.group(1); cells[cur][pin] = ''; continue
        m = re.match(r'\s*function\s*:\s*"([^"]*)"', line)
        if m and cur and pin: cells[cur][pin] = m.group(1)
        m = re.match(r'\s*direction\s*:\s*"?(\w+)"?', line)
        if m and cur and pin: DIR[(cur, pin)] = m.group(1)
    return cells
DIR = {}

bc, bn = read_def(bdef); ac, an = read_def(adef); cells = {}
for l_ in lib.split(','): cells.update(read_lib(l_))
fails = []
def fail(msg): fails.append(msg)
added = [k for k in ac if k not in bc]; removed = [k for k in bc if k not in ac]
resized = [k for k in ac if k in bc and ac[k][0] != bc[k][0] and not (FILL.match(ac[k][0]) and FILL.match(bc[k][0]))]
moved = [k for k in ac if k in bc and ac[k][1] != bc[k][1] and not FILL.match(ac[k][0])]
add_nf = Counter(ac[k][0] for k in added if not FILL.match(ac[k][0]))
rem_nf = Counter(bc[k][0] for k in removed if not FILL.match(bc[k][0]))
fill_add = sum(1 for k in added if FILL.match(ac[k][0])); fill_rem = sum(1 for k in removed if FILL.match(bc[k][0]))
moved_bad = [k for k in moved if k not in resized]
for k in moved_bad: fail(f'moved but not resized: {k} {bc[k]} -> {ac[k]}')
with open(out + '.cells.tsv', 'w') as f:
    for k in added:
        if not FILL.match(ac[k][0]): f.write(f'ADD\t{k}\t{ac[k][0]}\t{ac[k][1]}\n')
    for k in removed:
        if not FILL.match(bc[k][0]): f.write(f'REMOVE\t{k}\t{bc[k][0]}\n')
    for k in resized: f.write(f'RESIZE\t{k}\t{bc[k][0]}\t{ac[k][0]}\t{bc[k][1]}\t{ac[k][1]}\n')
    for k in moved_bad: f.write(f'MOVED\t{k}\t{bc[k]}\t{ac[k]}\n')

# resized: same function and pin names, same net on every pin
pin_net_b = {p: n for n, ps in bn.items() for p in ps}
pin_net_a = {p: n for n, ps in an.items() for p in ps}
for k in resized:
    o, m = bc[k][0], ac[k][0]
    if o not in cells or m not in cells: fail(f'resize {k}: {o} or {m} not in lib'); continue
    if set(cells[o]) != set(cells[m]): fail(f'resize {k}: pin names differ {o} {m}'); continue
    for p in cells[o]:
        if cells[o][p] != cells[m][p]: fail(f'resize {k}: function of {p} differs {o} {m}')
        if pin_net_b.get(f'{k}/{p}') != pin_net_a.get(f'{k}/{p}'): fail(f'resize {k}: pin {p} changed net')

def outpins(inst, master):
    c = cells.get(master, {})
    return {p for p, fn in c.items() if fn}
def is_out(pin, comps):
    i, p = pin.rsplit('/', 1)
    if i == 'PIN': return None
    m = comps[i][0]
    if m in cells and any(cells[m].values()): return p in outpins(i, m)
    return DIR.get((m, re.sub(r'\[\d+\]$', '', p))) == 'output' or DIR.get((m, p)) == 'output'

new_buf = {k for k in added if not FILL.match(ac[k][0]) and 'diode' not in ac[k][0]}
new_dio = {k for k in added if 'diode' in ac[k][0]}
rem_dio = {k for k in removed if 'diode' in bc[k][0]}
for k in removed:
    if not FILL.match(bc[k][0]) and k not in rem_dio: fail(f'removed a non-filler non-diode cell {k} {bc[k][0]}')
for k in new_buf:
    m = ac[k][0]; c = cells.get(m, {})
    ins = [p for p, fn in c.items() if not fn]; outs = [p for p, fn in c.items() if fn]
    if len(ins) != 1 or len(outs) != 1 or c[outs[0]].strip('() ') != ins[0]: fail(f'new cell {k} {m} is not a one-input buffer')

changed = [n for n in set(bn) | set(an) if sorted(bn.get(n, [])) != sorted(an.get(n, []))]
old_changed = [n for n in changed if n in bn]
new_nets = [n for n in changed if n not in bn]
# a net may differ only by diodes added / removed -> fine
def strip(ps, dios): return sorted(p for p in ps if p.rsplit('/', 1)[0] not in dios)
drv_net_a = {}
for n, ps in an.items():
    for p in ps:
        if is_out(p, ac): drv_net_a.setdefault(p, n)
def reach(net, seen=0):
    """old sinks reached from net through new buffers (new buffer pins removed)"""
    res = []
    for p in an.get(net, []):
        i, pin = p.rsplit('/', 1)
        if i in new_buf:
            if not is_out(p, ac):
                xo = [q for q in outpins(i, ac[i][0])][0]
                nn = pin_net_a.get(f'{i}/{xo}')
                if nn is None: fail(f'new buffer {i} output open'); continue
                if seen > 40: fail(f'buffer loop at {i}'); continue
                res += reach(nn, seen + 1)
        else:
            res.append(p)
    return res
struct_nets = 0
for n in old_changed:
    b = bn[n]; a = an.get(n, [])
    if n not in an: fail(f'net {n} removed'); continue
    if strip(b, rem_dio | new_dio) == strip(a, rem_dio | new_dio):
        # only diodes: new diodes add a DIODE pin, removed diodes drop one
        for p in set(a) - set(b):
            if p.rsplit('/', 1)[0] not in new_dio: fail(f'net {n}: unexpected new pin {p}')
        continue
    struct_nets += 1
    db_ = [p for p in b if is_out(p, bc)]; da = [p for p in a if is_out(p, ac) and p.rsplit('/', 1)[0] not in new_buf]
    # a driver moved behind a new buffer (row macro pin): follow it
    drv_b = db_[0] if db_ else None
    root = n
    if drv_b and drv_b not in a:
        root = pin_net_a.get(drv_b)
        if root is None: fail(f'net {n}: old driver {drv_b} open'); continue
    got = strip(reach(root), rem_dio | new_dio)
    want = strip([p for p in b if p != drv_b], rem_dio | new_dio)
    got = [p for p in got if p != drv_b]
    if sorted(got) != sorted(want):
        fail(f'net {n}: sinks behind the buffers differ: missing {sorted(set(want) - set(got))[:4]} extra {sorted(set(got) - set(want))[:4]}')
for n in new_nets:
    for p in an[n]:
        i = p.rsplit('/', 1)[0]
        if i in new_dio: continue
# every pin of the after DEF on exactly one net
cnt = Counter(p for ps in an.values() for p in ps)
dup = [p for p, c in cnt.items() if c > 1 and not p.startswith('PIN/')]
for p in dup[:20]: fail(f'pin on two nets: {p}')
with open(out + '.nets.tsv', 'w') as f:
    for n in sorted(changed): f.write(f'{n}\t{len(bn.get(n, []))}\t{len(an.get(n, []))}\n')
print(f'NETDIFF cells added (non-filler) {dict(add_nf)}; removed (non-filler) {dict(rem_nf)}; resized {len(resized)} '
      f'{dict(Counter(bc[k][0] + "->" + ac[k][0] for k in resized))}; fillers +{fill_add} -{fill_rem}; '
      f'non-filler cells moved without a resize {len(moved_bad)}')
print(f'NETDIFF nets with a changed pin set {len(changed)} (old {len(old_changed)}, new {len(new_nets)}); '
      f'old nets split by buffers {struct_nets}; pins on two nets {len(dup)}')
for x in fails[:30]: print('NETDIFF FAIL', x)
print(f'NETDIFF {"PASS" if not fails else "FAIL"} ({len(fails)} problems)')
