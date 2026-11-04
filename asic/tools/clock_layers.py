#!/usr/bin/env python3
"""
clock_layers.py <run dir>
Routed wire length per metal layer for the clock nets vs all other nets,
from the final DEF. Long clock wire on met1/met2 = high RC the CTS-time
estimate did not see (skew grows after routing) and antenna trouble.
"""
import collections, glob, os, re, sys

run = sys.argv[1]
defs = sorted(glob.glob(os.path.join(run, "results", "final", "def", "*.def")))
if not defs:
    sys.exit("no final DEF")
units, inside, cur, clk = 1000.0, False, [], False
L = {True: collections.Counter(), False: collections.Counter()}
nets = {True: 0, False: 0}
pt = re.compile(r"\(\s*(-?\d+|\*)\s+(-?\d+|\*)(?:\s+-?\d+)?\s*\)")

def flush(text, is_clk):
    for seg in re.split(r"\b(?:ROUTED|NEW|FIXED|COVER)\b", text)[1:]:
        tok = seg.split()
        if not tok:
            continue
        layer = tok[0]
        x = y = None
        for m in pt.finditer(seg):
            nx = x if m.group(1) == "*" else int(m.group(1))
            ny = y if m.group(2) == "*" else int(m.group(2))
            if x is not None and nx is not None and ny is not None:
                L[is_clk][layer] += abs(nx - x) + abs(ny - y)
            x, y = nx, ny

for line in open(defs[-1], errors="replace"):
    if line.startswith("UNITS DISTANCE MICRONS"):
        units = float(line.split()[3])
    elif line.startswith("NETS "):
        inside = True
    elif line.startswith("END NETS"):
        break
    elif inside:
        s = line.strip()
        if s.startswith("- "):
            name = s.split()[1]
            clk = name.startswith(("clknet", "i_clk")) or "_clk" in name and name.startswith("clk")
            cur = [s]
        else:
            cur.append(s)
        if s.endswith(";"):
            nets[clk] += 1
            flush(" ".join(cur), clk)
            cur = []

for k, label in ((True, "clock nets"), (False, "other nets")):
    tot = sum(L[k].values()) / units
    print(f"{label:11s} ({nets[k]:6d} nets, {tot/1000:8.1f} mm): " +
          "  ".join(f"{ly} {v/units/1000:.1f}mm ({100*v/units/max(tot,1e-9):.0f}%)"
                    for ly, v in sorted(L[k].items())))
