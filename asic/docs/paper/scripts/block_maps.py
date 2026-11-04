#!/usr/bin/env python3
"""Cell maps of the final layout drawn from the DEFs (cell outlines only, no wires).
1. row_pe_map: one ProcessingElementRow (row_v1), every cell coloured by the index of the PE
   it belongs to. The row is flat and its instance names are generic (_12345_, holdN...), so
   the PE index comes from the NET names that keep the hierarchy
   (g_pe_column[k].u_processing_element.*): a cell on such a net gets k (majority), the other
   cells take the majority PE of the cells they share a net with (nets of fanout <= 16,
   repeated until nothing changes). Cells left without a PE (clock tree, shared control,
   fill / tap / diode) are grey.
2. chip_blocks: the whole IP, each instance coloured by block / kind: SRAM, row macro, AXI
   macro, top-level logic, hold buffers, antenna diodes, clock tree (top level; fill, decap
   and tap not drawn).
usage: block_maps.py <paper dir> <row DEF> <row netlist> <top DEF> <lef>...  (PNG + PDF)"""
import sys, re, collections
import numpy as np
import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
from matplotlib.collections import PolyCollection
from matplotlib.patches import Patch
P, RDEF, RNET, TDEF = sys.argv[1:5]; LEFS = sys.argv[5:]
size = {}
for f in LEFS:
    cur = None
    for line in open(f, errors="replace"):
        m = re.match(r"\s*MACRO (\S+)", line)
        if m: cur = m.group(1); continue
        m = re.match(r"\s*SIZE ([\d.]+) BY ([\d.]+)", line)
        if m and cur and cur not in size: size[cur] = (float(m.group(1)), float(m.group(2)))
def comps(path):
    out = []; on = False; dbu = 1000; die = None
    for line in open(path):
        if not on:
            if line.startswith("UNITS DISTANCE MICRONS"): dbu = int(line.split()[3])
            elif line.startswith("DIEAREA"):
                v = [int(x) for x in re.findall(r"-?\d+", line)]; die = (v[0] / dbu, v[1] / dbu, v[2] / dbu, v[3] / dbu)
            elif line.startswith("COMPONENTS"): on = True
            continue
        if line.startswith("END COMPONENTS"): break
        m = re.match(r"\s*-\s+(\S+)\s+(\S+).*?\+\s+(?:PLACED|FIXED)\s+\(\s*(-?\d+)\s+(-?\d+)\s*\)\s+(\S+)", line)
        if m:
            n, ms, x, y, o = m.groups(); w, h = size.get(ms, (0, 0))
            if o in ("E", "W", "FE", "FW"): w, h = h, w
            out.append((n, ms, int(x) / dbu, int(y) / dbu, w, h))
    return out, die
def boxes(items):
    return [[(x, y), (x + w, y), (x + w, y + h), (x, y + h)] for x, y, w, h in items]

# ---------------- row coloured by PE
rc, rdie = comps(RDEF)
s = open(RNET).read()
cellnets = {}
for m in re.finditer(r"^\s*(sky130_\w+)\s+(\\\S+|\S+)\s*\((.*?)\);", s, re.M | re.S):
    cellnets[m.group(2).lstrip("\\")] = [e.strip().lstrip("\\").strip() for e in re.findall(r"\.\w+\(\s*([^()]*?)\s*\)", m.group(3), re.S) if e.strip()]
del s
PEN = re.compile(r"g_pe_column\[(\d+)\]\.u_processing_element\.")
netcells = collections.defaultdict(list)
for c, ns in cellnets.items():
    for n in ns: netcells[n].append(c)
lab = {}
for c, ns in cellnets.items():
    k = collections.Counter(int(m.group(1)) for n in ns for m in [PEN.match(n)] if m)
    if k: lab[c] = k.most_common(1)[0][0]
seeded = len(lab)
for it in range(30):
    new = {}
    for c, ns in cellnets.items():
        if c in lab: continue
        k = collections.Counter(lab[o] for n in ns if len(netcells[n]) <= 16 for o in netcells[n] if o in lab and o != c)
        if k: new[c] = k.most_common(1)[0][0]
    if not new: break
    lab.update(new)
logic = [r for r in rc if not re.search(r"__(fill|decap|tapvpwrvgnd|diode)", r[1])]
print(f"ROWMAP cells {len(rc)}, logic {len(logic)}, PE from net names {seeded}, after propagation {sum(1 for r in logic if r[0] in lab)}, rounds {it}")
cmap = plt.get_cmap("tab20")
def pecol(k): return cmap((k % 20) / 20 + 0.025) if k % 2 == 0 else cmap(((k + 10) % 20) / 20 + 0.025)
for tag, xr in (("row_pe_map", None), ("row_pe_map_zoom_pe0_3", (rdie[0], rdie[0] + 4 * (rdie[2] - rdie[0]) / 32 + 20))):
    fig, ax = plt.subplots(figsize=(16, 2.6) if xr is None else (9, 4.2))
    sel = [r for r in rc if xr is None or (r[2] <= xr[1] and r[2] + r[4] >= xr[0])]
    grey = [r for r in sel if r[0] not in lab]; col = [r for r in sel if r[0] in lab]
    ax.add_collection(PolyCollection(boxes([(r[2], r[3], r[4], r[5]) for r in grey]), facecolors="#d9d9d9", edgecolors="none"))
    ax.add_collection(PolyCollection(boxes([(r[2], r[3], r[4], r[5]) for r in col]),
                                     facecolors=[pecol(lab[r[0]]) for r in col], edgecolors="none"))
    ax.set_xlim(*(xr or (rdie[0], rdie[2]))); ax.set_ylim(rdie[1], rdie[3]); ax.set_aspect("equal")
    ax.set_xlabel("x (um)"); ax.set_ylabel("y (um)")
    if xr is None:
        for k in range(0, 32, 4):
            xs = [r[2] for r in col if lab[r[0]] == k]
            if xs: ax.text(np.median(xs), rdie[3] + 4, f"PE {k}", ha="center", fontsize=7)
        ax.set_title("ProcessingElementRow (row_v1): cells coloured by PE index (32 PEs), grey = no PE (clock tree, shared, fill/tap/diode)", fontsize=9, pad=14)
    else:
        hs = [Patch(color=pecol(k), label=f"PE {k}") for k in range(4)] + [Patch(color="#d9d9d9", label="no PE / fill")]
        ax.legend(handles=hs, fontsize=7, loc="upper center", ncol=5, bbox_to_anchor=(0.5, -0.22))
        ax.set_title("Row, first 4 PEs (zoom)", fontsize=9)
    fig.tight_layout()
    for ext in ("png", "pdf"): fig.savefig(f"{P}/figures/layout/{tag}.{ext}", dpi=250)
    plt.close(fig)

# ---------------- chip coloured by block / kind
tc, tdie = comps(TDEF)
def kind(n, m):
    if m.startswith("sky130_sram"): return "SRAM"
    if m == "ProcessingElementRow": return "row macro"
    if m == "GemmAxiShell": return "AXI macro"
    if re.search(r"__(fill|decap|tapvpwrvgnd)", m): return None
    if "__diode" in m: return "antenna diode"
    if n.startswith("clkbuf_") or n.startswith("clkload") or n.startswith("eco_clk"): return "clock tree"
    if n.startswith("hold") or re.search(r"__(dlygate|dlymetal|clkdlybuf)", m): return "hold buffer"
    return "top-level logic"
COL = {"SRAM": "#4c72b0", "row macro": "#dd8452", "AXI macro": "#55a868", "top-level logic": "#8c8c8c",
       "hold buffer": "#c44e52", "antenna diode": "#8172b3", "clock tree": "#e5ae38"}
grp = collections.defaultdict(list)
for n, m, x, y, w, h in tc:
    k = kind(n, m)
    if k: grp[k].append((x, y, w, h))
fig, ax = plt.subplots(figsize=(7.5, 10.5))
ax.add_patch(plt.Rectangle((tdie[0], tdie[1]), tdie[2] - tdie[0], tdie[3] - tdie[1], fill=False, lw=0.6))
for k in ("SRAM", "row macro", "AXI macro"):
    ax.add_collection(PolyCollection(boxes(grp[k]), facecolors=COL[k], edgecolors="black", linewidths=0.2, alpha=0.85))
for k in ("top-level logic", "hold buffer", "antenna diode", "clock tree"):
    b = [(x - 1.5, y - 1.5, w + 3, h + 3) for x, y, w, h in grp[k]]     # 3 um halo so single cells show at page scale
    ax.add_collection(PolyCollection(boxes(b), facecolors=COL[k], edgecolors="none"))
ax.set_xlim(tdie[0], tdie[2]); ax.set_ylim(tdie[1], tdie[3]); ax.set_aspect("equal")
ax.set_xlabel("x (um)"); ax.set_ylabel("y (um)")
ax.legend(handles=[Patch(color=COL[k], label=f"{k} ({len(grp[k])})") for k in COL], fontsize=7, loc="upper center",
          bbox_to_anchor=(0.5, -0.06), ncol=3)
ax.set_title("GEMM IP final layout by block (std cells drawn 3 um larger; fill/decap/tap omitted)", fontsize=9)
fig.tight_layout()
for ext in ("png", "pdf"): fig.savefig(f"{P}/figures/layout/chip_blocks.{ext}", dpi=250)
print("CHIPMAP", {k: len(v) for k, v in grp.items()})
