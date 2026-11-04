#!/usr/bin/env python3
"""Components of two defgeo/defsum outputs: every cell that is not a filler/decap
(CORE SPACER: *__fill_*, *__decap_*) must keep master and placement; removed ones
must be fillers; new ones fillers or diodes. usage: compcheck.py a.tsv b.tsv"""
import re, sys
from collections import Counter
SP = re.compile(r'__(fill|decap)_\d+$')
def load(p):
    return {t[1]: (t[2], t[3] if len(t) > 3 else '') for t in (l.rstrip('\n').split('\t') for l in open(p)) if t[0] == 'C'}
a, b = load(sys.argv[1]), load(sys.argv[2])
moved = [k for k in a.keys() & b.keys() if not SP.search(a[k][0]) and a[k] != b[k]]
gone = Counter('filler' if SP.search(a[k][0]) else a[k][0] for k in a.keys() - b.keys())
new = Counter('filler' if SP.search(b[k][0]) else b[k][0] for k in b.keys() - a.keys())
print(f'non-filler cells moved or changed: {len(moved)} {moved[:5]}')
print(f'removed: {dict(gone)}')
print(f'added: {dict(new)}')
bad = [k for k in gone if k != 'filler'] + [k for k in new if k not in ('filler', 'sky130_fd_sc_hd__diode_2')]
print('COMPCHECK', 'OK' if not moved and not bad else f'FAIL (moved {len(moved)}, unexpected {bad})')
