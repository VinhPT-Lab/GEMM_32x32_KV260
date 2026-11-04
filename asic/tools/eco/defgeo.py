#!/usr/bin/env python3
"""Per-net routing geometry of a DEF, normalised so that two writers of the same
wires give the same signature: per layer, horizontal segments merged into
x-interval unions per y, vertical into y-interval unions per x (endpoint
extensions kept as written), vias as (name, x, y), RECT patches as absolute
boxes. Also components (master, placement) and pin sets.
usage: defgeo.py in.def out.tsv"""
import re, sys, hashlib
from collections import defaultdict
src, out = sys.argv[1], sys.argv[2]
fo = open(out, 'w')
ROUTING = ['li1', 'met1', 'met2', 'met3', 'met4', 'met5']
via_layers = {}
cur = None; lays = []
import os
for line in open(os.path.join(os.environ['PDK_ROOT'], 'sky130A/libs.ref/sky130_fd_sc_hd/techlef/sky130_fd_sc_hd__nom.tlef')):
    t = line.split()
    if not t: continue
    if t[0] == 'VIA' and len(t) >= 2: cur, lays = t[1], []
    elif cur and t[0] == 'LAYER': lays.append(t[1])
    elif cur and t[0] == 'END' and len(t) > 1 and t[1] == cur:
        r = [l for l in lays if l in ROUTING]
        if len(r) >= 2: via_layers[cur] = (r[0], r[-1])
        cur = None
def merge(iv):
    iv.sort(); r = []
    for a, b in iv:
        if r and a <= r[-1][1]: r[-1][1] = max(r[-1][1], b)
        else: r.append([a, b])
    return tuple(map(tuple, r))
def geo(text):
    H = defaultdict(list); V = defaultdict(list); vias = []; rects = []; ext = []
    for path in re.split(r'\bNEW\b', text):
        tok = path.replace('(', ' ( ').replace(')', ' ) ').split()
        if not tok: continue
        layer = tok[0]; i = 1; x = y = None
        while i < len(tok):
            t = tok[i]
            if t == '(':
                j = tok.index(')', i); v = tok[i+1:j]
                nx = x if v[0] == '*' else int(v[0]); ny = y if v[1] == '*' else int(v[1])
                if len(v) > 2: ext.append((layer, nx, ny, int(v[2])))
                if x is not None and (nx, ny) != (x, y):
                    if ny == y: H[(layer, y)].append((min(x, nx), max(x, nx)))
                    else: V[(layer, x)].append((min(y, ny), max(y, ny)))
                x, y = nx, ny; i = j + 1
            elif t == 'RECT':
                j = tok.index(')', i); v = [int(a) for a in tok[i+2:j]]
                rects.append((layer, x+v[0], y+v[1], x+v[2], y+v[3])); i = j + 1
            elif t == 'VIRTUAL':
                j = tok.index(')', i); v = tok[i+2:j]
                x = x if v[0] == '*' else int(v[0]); y = y if v[1] == '*' else int(v[1]); i = j + 1
            elif t in ('MASK', 'STYLE', 'TAPERRULE'): i += 2
            elif t == 'TAPER' or re.fullmatch(r'F?[NSEW]', t): i += 1
            else:
                vias.append((t, x, y)); i += 1
                lo, hi = via_layers[t]      # the path goes on on the via's other layer
                layer = hi if layer == lo else lo
    g = (sorted((k, merge(v)) for k, v in H.items()), sorted((k, merge(v)) for k, v in V.items()),
         sorted(set(vias)), sorted(set(rects)), sorted(set(ext)))
    return hashlib.sha1(repr(g).encode()).hexdigest()[:16]
sec = None; buf = []
with open(src) as f:
    for line in f:
        s = line.strip()
        if sec is None:
            if s.startswith('VIAS '): sec = 'V'
            if s.startswith('COMPONENTS '): sec = 'C'
            elif s.startswith('NETS '): sec = 'N'
            continue
        if s.startswith('END COMPONENTS') or s.startswith('END NETS'): sec = None; continue
        if sec == 'V':
            if s.startswith('END VIAS'): sec = None; continue
            m = re.search(r'^- (\S+) .*\+ LAYERS (\S+) \S+ (\S+)', s)
            if m: via_layers[m.group(1)] = (m.group(2), m.group(3))
            continue
        if s.startswith('- '): buf = [s]
        else: buf.append(s)
        if not s.endswith(';'): continue
        st = ' '.join(buf)[:-1]; buf = []
        if sec == 'C':
            t = st.split(); m = re.search(r'\+ (PLACED|FIXED|COVER|UNPLACED)\s*(?:\(\s*(-?\d+)\s+(-?\d+)\s*\)\s*(\S+))?', st)
            fo.write('C\t%s\t%s\t%s\n' % (t[1], t[2], ' '.join(x for x in (m.groups() if m else ()) if x)))
            continue
        name = st.split()[1]; i = st.find(' + ')
        pins = sorted(re.findall(r'\(\s*(\S+)\s+(\S+)\s*\)', st[:i] if i >= 0 else st))
        m = re.search(r'\+ (ROUTED|FIXED|COVER|NOSHIELD) ', st)
        h = '-'; npath = 0
        if m:
            r = re.split(r' \+ (?:USE|SOURCE|WEIGHT|PROPERTY|NONDEFAULTRULE|SHIELDNET)\b', st[m.end():])[0]
            npath = r.count(' NEW ') + 1; h = geo(r)
        fo.write('N\t%s\t%d\t%s\t%d\t%s\n' % (name, len(pins), hashlib.sha1(repr(pins).encode()).hexdigest()[:12], npath, h))
fo.close()
