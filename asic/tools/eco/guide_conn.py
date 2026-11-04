#!/usr/bin/env python3
"""Connectivity of every net's guides (same-layer neighbours, or the same GCell
on adjacent layers). usage: guide_conn.py file.guide"""
import sys
L = {'met1': 1, 'met2': 2, 'met3': 3, 'met4': 4, 'met5': 5}
def check(name, s, bad):
    seen = set(); comps = 0
    for c in s:
        if c in seen: continue
        comps += 1; st = [c]; seen.add(c)
        while st:
            l, x, y = st.pop()
            for d in ((l, x+1, y), (l, x-1, y), (l, x, y+1), (l, x, y-1), (l+1, x, y), (l-1, x, y)):
                if d in s and d not in seen: seen.add(d); st.append(d)
    if comps > 1: bad.append((name, comps, len(s)))
bad = []; n = 0; cur = None; s = set()
for l in open(sys.argv[1]):
    l = l.strip()
    if l == '(': continue
    if l == ')': check(cur, s, bad); n += 1; continue
    t = l.split()
    if len(t) == 1: cur = t[0]; s = set()
    else: s.add((L[t[4]], int(t[0]) // 6900, int(t[1]) // 6900))
print(f'nets {n}, guides in more than one piece {len(bad)}')
for b in bad[:20]: print('  ', *b)
