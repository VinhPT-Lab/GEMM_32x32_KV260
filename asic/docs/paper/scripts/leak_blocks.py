#!/usr/bin/env python3
"""Leakage per block and corner from leak_blocks.tcl reports: top-level standard cells,
32 rows (one row x 32), AXI shell, SRAM (80 macros, TT lib). Standard cells are split into
logic and fill/decap/tap (decap cells leak too; the earlier leakage_3corners.csv listed both).
usage: leak_blocks.py <dir> <out.csv>"""
import sys, csv, re, os
D, OUT = sys.argv[1:3]
def load(b, c):
    ref = dict(l.rsplit(" ", 1) for l in open(f"{D}/{b}_{c}.refs.txt").read().split("\n") if l)
    s = {"logic": 0.0, "fill_decap_tap": 0.0, "sram": 0.0}; n = 0
    for l in open(f"{D}/{b}_{c}.inst.rpt"):
        f = l.split()
        if len(f) != 5: continue
        try: lk = float(f[2])
        except ValueError: continue
        r = ref.get(f[4])
        if r is None: continue
        n += 1
        k = "sram" if r.startswith("sky130_sram") else "fill_decap_tap" if re.search(r"__(fill|decap|tapvpwrvgnd)", r) else "logic"
        s[k] += lk * 1e3                                   # W -> mW
    return s, n
rows = []
for c in ("tt", "ff", "ss"):
    t, nt = load("top", c); r, nr = load("row", c); a, na = load("axi", c)
    rec = dict(corner=c, top_std_logic_mW=t["logic"], top_fill_decap_tap_mW=t["fill_decap_tap"],
               row_x32_logic_mW=32 * r["logic"], row_x32_fill_decap_tap_mW=32 * r["fill_decap_tap"],
               axi_logic_mW=a["logic"], axi_fill_decap_tap_mW=a["fill_decap_tap"], sram_mW=t["sram"])
    rec["total_mW"] = sum(v for k, v in rec.items() if k.endswith("_mW"))
    rec["one_row_mW"] = r["logic"] + r["fill_decap_tap"]
    rec = {k: (round(v, 5) if isinstance(v, float) else v) for k, v in rec.items()}
    rec.update(cells_top=nt, cells_row=nr, cells_axi=na,
               sram_lib="OpenRAM TT 1.8V 25C (only corner shipped)",
               std_lib={"tt": "tt_025C_1v80", "ff": "ff_n40C_1v95", "ss": "ss_100C_1v60"}[c])
    rows.append(rec); print("LEAKBLOCKS", rec)
with open(OUT, "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0])); w.writeheader(); w.writerows(rows)
