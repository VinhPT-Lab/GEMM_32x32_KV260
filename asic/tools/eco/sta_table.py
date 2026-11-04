#!/usr/bin/env python3
"""Table of sta6b results for some designs. usage: sta_table.py log... (sta6b run logs or the per-run logs)"""
import re, sys, glob
rows = {}
for f in sys.argv[1:]:
    for l in open(f):
        m = re.match(r'STA6B (\w+) (\w+) RC (\w+): (.*)', l)
        if m:
            d, c, rc, rest = m.groups()
            for k, a, b, cc, dd, e, ff in re.findall(r'(setup|hold) cell->cell worst (\S+) \(<0: (\d+)/\d+\), macro worst (\S+) \(<0: (\d+)/\d+\), I/O worst (\S+) \(<0: (\d+)/\d+\)', rest):
                rows.setdefault((d, c, rc), {})[k] = (a, b, cc, dd, e, ff)
        m = re.match(r'STA6B DRV (\w+) (\w+) RC (\w+) \(lib limits\): standard-cell nets (\d+) \(slew (\d+), cap (\d+)\); SRAM dout cap nets (\d+); SRAM addr/wmask slew nets (\d+).*?SRAM other (\d+); row/AXI pins (\d+); I/O (\d+)', l)
        if m: rows.setdefault(m.group(1, 2, 3), {})['drv'] = m.groups()[3:]
des = []
for k in rows:
    if k[0] not in des: des.append(k[0])
f = lambda x: f'{float(x[0]):7.3f}({x[1]}) {float(x[2]):7.3f}({x[3]}) {float(x[4]):7.3f}({x[5]})' if x else '-'
print('design corner RC | SETUP cc | macro | IO || HOLD cc | macro | IO || DRV cell(slew,cap) dout addr/wmask sram_other row/axi io')
for c in ('tt', 'ff', 'ss'):
    for rc in ('min', 'nom', 'max'):
        for d in des:
            r = rows.get((d, c, rc))
            if not r: continue
            dv = r.get('drv')
            print(f'{d:4s} {c} {rc:3s} | {f(r.get("setup"))} || {f(r.get("hold"))} || ' + (f'{dv[0]}({dv[1]},{dv[2]}) {dv[3]} {dv[4]} {dv[5]} {dv[6]} {dv[7]}' if dv else '-'))
