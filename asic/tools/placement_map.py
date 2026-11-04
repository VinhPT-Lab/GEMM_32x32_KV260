#!/usr/bin/env python3
"""
placement_map.py <run dir> <macro.cfg> <row_w> <row_h>
Where did the standard cells of a gemm_array run end up? Counts flops, clock
buffers, hold buffers and everything else per floorplan region, read from the
final DEF. Tells whether the clock sinks stayed in the west strip / bottom
band or spread into the channels between the rows.
"""
import collections, glob, os, re, sys

run, mcfg, row_w, row_h = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
rows = sorted((float(l.split()[1]), float(l.split()[2])) for l in open(mcfg)
              if l.strip() and not l.startswith("#"))
x0 = rows[0][0]; x1 = x0 + row_w
ys = sorted(y for _, y in rows); lo, hi = ys[0], ys[-1] + row_h

def region(x, y):
    if x < x0: return "west strip"
    if x > x1: return "east strip"
    if y < lo: return "bottom band"
    if y > hi: return "top band"
    for yb in ys:
        if yb <= y <= yb + row_h: return "over a row (?)"
    return "channels"

defs = sorted(glob.glob(os.path.join(run, "results", "final", "def", "*.def")))
if not defs:
    sys.exit(f"no final DEF under {run}/results/final/def")
units, inside = 1000.0, False
cnt = collections.Counter(); kinds = set(); regs = set()
xs = collections.defaultdict(list)
pat = re.compile(r"^\s*-\s+(\S+)\s+(\S+).*?\+\s+(?:PLACED|FIXED)\s+\(\s*(-?\d+)\s+(-?\d+)\s*\)")
for line in open(defs[-1], errors="replace"):
    if line.startswith("UNITS DISTANCE MICRONS"):
        units = float(line.split()[3])
    elif line.startswith("COMPONENTS"):
        inside = True
    elif line.startswith("END COMPONENTS"):
        break
    elif inside:
        m = pat.match(line)
        if not m:
            continue
        inst, cell = m.group(1), m.group(2)
        if any(t in cell for t in ("tap", "fill", "decap", "ProcessingElementRow", "diode")):
            continue
        if re.search(r"__df|__sdf|__edf", cell): k = "flops"
        elif "clkbuf" in cell or inst.startswith(("clkbuf", "clkload", "wire")) and "clk" in cell: k = "clock buffers"
        elif inst.startswith("hold"): k = "hold buffers"
        else: k = "other logic"
        x, y = int(m.group(3)) / units, int(m.group(4)) / units
        r = region(x, y)
        cnt[(k, r)] += 1; kinds.add(k); regs.add(r)
        if k == "flops":
            xs[r].append((x, y))

order = ["west strip", "bottom band", "channels", "top band", "east strip", "over a row (?)"]
regs = [r for r in order if r in regs]
print(f"{'':16s}" + "".join(f"{r:>14s}" for r in regs))
for k in ["flops", "clock buffers", "hold buffers", "other logic"]:
    if k in kinds:
        print(f"{k:16s}" + "".join(f"{cnt[(k, r)]:14d}" for r in regs))
for r, pts in xs.items():
    if pts:
        X = [p[0] for p in pts]; Y = [p[1] for p in pts]
        print(f"flops in {r:12s}: x {min(X):7.0f}..{max(X):7.0f}  y {min(Y):7.0f}..{max(Y):7.0f} um")
