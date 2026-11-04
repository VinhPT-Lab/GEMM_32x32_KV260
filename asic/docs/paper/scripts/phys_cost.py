#!/usr/bin/env python3
"""Physical cost of the final IP: antenna diodes by block and by origin, hold buffers by
block, NAND2 equivalents with / without diodes, hold buffers and clock tree.
Diode origin, from the instance names of OpenLane 1.0.2 / OpenROAD and of the flow scripts:
  ANTENNA_<inst>_<pin>   pre-route diodes of the flow: DIODE_ON_PORTS (macro inputs) and the
                         heuristic insertion (RUN_HEURISTIC_DIODE_INSERTION, nets > threshold)
  ANTENNA_<n>            OpenROAD repair_antennas during global route (GRT_REPAIR_ANTENNAS);
                         in the top level also the repair_antennas of the ECO rounds
                         (s4c_round.py renumbers them the same way), so these are split by
                         presence in the round-1 DEF of ip_v3r (the ECO start point)
  ANTFIX<k>_<inst>_<pin>_<n>  ant_eco.py of the flow (targeted diodes from the ARC report
                         between global-route rounds), present in the round-1 DEF
  anything not in the round-1 DEF (top level only): added by the ECO
usage: phys_cost.py <paper dir> <final top DEF> <round-1 DEF> <row DEF> <axi DEF>"""
import sys, re, csv, collections
P, TOP, R1, ROW, AXI = sys.argv[1:6]
def comps(path):
    out = {}; on = False
    for line in open(path):
        if not on:
            if line.startswith("COMPONENTS"): on = True
            continue
        if line.startswith("END COMPONENTS"): break
        m = re.match(r"\s*-\s+(\S+)\s+(\S+)", line)
        if m: out[m.group(1)] = m.group(2)
    return out
def origin(name):
    if re.match(r"ANTENNA_\d+$", name): return "grt_repair_antennas"
    if name.startswith("ANTFIX"): return "ant_eco_flow"
    if name.startswith("ANTENNA_"): return "preroute_ports_heuristic"
    return "other"
top, r1, row, axi = comps(TOP), comps(R1), comps(ROW), comps(AXI)
isd = lambda m: "__diode" in m
rows = []
for blk, cs, mult in (("top", top, 1), ("row (one)", row, 1), ("row x32", row, 32), ("AXI shell", axi, 1)):
    c = collections.Counter()
    for n, m in cs.items():
        if not isd(m): continue
        o = origin(n)
        if blk == "top" and n not in r1: o = "eco"
        c[o] += mult
    rows.append(dict(block=blk, diodes=sum(c.values()), **{k: c.get(k, 0) for k in
                ("preroute_ports_heuristic", "grt_repair_antennas", "ant_eco_flow", "eco", "other")}))
# diodes of the round-1 DEF that the ECO removed (clock nets, step 7B)
rm = sum(1 for n, m in r1.items() if isd(m) and n not in top)
print("PHYS diodes", rows, "removed by ECO", rm)
with open(f"{P}/data/diodes_by_block_origin.csv", "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0]) + ["note"]); w.writeheader()
    for r in rows: w.writerow(dict(r, note=f"round-1 diodes removed by the ECO: {rm}" if r["block"] == "top" else ""))
# hold buffers and NAND2 equivalents from the group areas (static_stats.py)
NAND2 = 3.7536
def groups(tag):
    return {r["group"]: (int(r["cells"]), float(r["area_um2"])) for r in csv.DictReader(open(f"{P}/data/{tag}_groups.csv"))}
blocks = [("top", groups("ip"), 1), ("row x32", groups("row"), 32), ("AXI shell", groups("axi"), 1)]
BASE = ["logic", "flop/latch", "tie", "buffer (resizer / I/O)", "ECO buffer"]
out = []
for name, g, k in blocks:
    a = lambda gg: k * g.get(gg, (0, 0.0))[1]
    n = lambda gg: k * g.get(gg, (0, 0.0))[0]
    base = sum(a(x) for x in BASE)
    out.append(dict(block=name, hold_buffers=n("hold buffer"), hold_area_um2=round(a("hold buffer"), 1),
                    clock_tree_cells=n("clock tree"), clock_tree_area_um2=round(a("clock tree"), 1),
                    diodes=n("diode"), diode_area_um2=round(a("diode"), 1),
                    nand2_logic_only=round(base / NAND2),
                    nand2_plus_hold=round((base + a("hold buffer")) / NAND2),
                    nand2_plus_hold_clock=round((base + a("hold buffer") + a("clock tree")) / NAND2),
                    nand2_plus_hold_clock_diode=round((base + a("hold buffer") + a("clock tree") + a("diode")) / NAND2)))
tot = {k: (sum(r[k] for r in out) if k != "block" else "IP total") for k in out[0]}
out.append(tot)
for r in out: print("PHYS nand2", r)
with open(f"{P}/data/nand2_hold_by_block.csv", "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(out[0]) + ["note"]); w.writeheader()
    for r in out: w.writerow(dict(r, note=f"NAND2 eq = area / nand2_1 ({NAND2} um2); logic only = logic, flop/latch, tie, "
                                          "resizer / I/O buffers, ECO buffers (static_stats.py groups); no fill/decap/tap"))
