#!/usr/bin/env python3
"""
core_congestion.py <congestion.rpt> <layout.def> <merged.lef> [--cols 72] [--nets]

Where the global-route overflow of gemm_core sits, from an OpenROAD congestion
report (global_route -congestion_report_file) and the DEF the router read
(only its DIEAREA and the FIXED macros are used).

Prints
  * overflow by region: over / between the SRAMs of region A (InputBuffer +
    BufferFeeder) and region B (OutputBuffer), over the row macros, the row
    channels, the FeatureSkew strip, the OutputDeskew band, south/west bands
  * two maps of the die (horizontal and vertical overflow), one character per
    cell: '#' SRAM, '=' row macro, '.' free, 1-9 overflow (log scale)
  * the nets (bus bits folded) that sit on most overflowing edges
  * --nets: what those nets connect (SRAM pins of region A/B, row pins,
    top-level ports, or only standard cells), read from the DEF NETS section
"""
import collections
import math
import re
import sys

SRAM = "sky130_sram_2kbyte_1rw1r_32x512_8"
ROW = "ProcessingElementRow"


def macro_sizes(lef):
    size, cur = {}, None
    for line in open(lef, errors="ignore"):
        m = re.match(r"\s*MACRO\s+(\S+)", line)
        if m:
            cur = m.group(1)
            continue
        m = re.match(r"\s*SIZE\s+([\d.]+)\s+BY\s+([\d.]+)", line)
        if m and cur in (SRAM, ROW):
            size[cur] = (float(m.group(1)), float(m.group(2)))
    return size


def def_macros(path):
    """DIEAREA + FIXED/PLACED instances of the two macro masters (um)"""
    dbu, die, macros = 1000.0, None, []
    pend = None
    with open(path, errors="ignore") as f:
        for line in f:
            if line.startswith("UNITS DISTANCE MICRONS"):
                dbu = float(line.split()[3])
            elif line.startswith("DIEAREA"):
                n = list(map(float, re.findall(r"-?\d+", line)))
                die = (n[0] / dbu, n[1] / dbu, n[-2] / dbu, n[-1] / dbu)
            elif line.startswith("END COMPONENTS"):
                break
            m = re.match(r"\s*-\s+(\S+)\s+(\S+)", line)
            if m:
                pend = (m.group(1), m.group(2)) if m.group(2) in (SRAM, ROW) else None
            if pend:
                p = re.search(r"\+\s+(?:FIXED|PLACED)\s+\(\s*(-?\d+)\s+(-?\d+)\s*\)\s*(\w+)", line)
                if p:
                    macros.append((pend[0], pend[1], int(p.group(1)) / dbu, int(p.group(2)) / dbu, p.group(3)))
                    pend = None
    return die, macros


def bbox(rects):
    return (min(r[0] for r in rects), min(r[1] for r in rects), max(r[2] for r in rects), max(r[3] for r in rects))


def inside(x, y, r):
    return r[0] <= x <= r[2] and r[1] <= y <= r[3]


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    cols = 72
    if "--cols" in sys.argv:
        cols = int(sys.argv[sys.argv.index("--cols") + 1])
    if len(args) != 3:
        print(__doc__)
        return 2
    rpt, deff, lef = args
    size = macro_sizes(lef)
    die, macros = def_macros(deff)
    if not die or not macros:
        print(f"could not read the die/macros from {deff}")
        return 1
    rect = {}
    for name, master, x, y, o in macros:
        w, h = size.get(master, (0, 0))
        if o in ("E", "W", "FE", "FW"):
            w, h = h, w
        rect[name] = (x, y, x + w, y + h, master)
    a = [r for n, r in rect.items() if r[4] == SRAM and "u_output_buffer" not in n]
    b = [r for n, r in rect.items() if r[4] == SRAM and "u_output_buffer" in n]
    rows = [r for r in rect.values() if r[4] == ROW]
    A, B, R = bbox(a) if a else None, bbox(b) if b else None, bbox(rows) if rows else None
    print(f"die {die[2]:.0f} x {die[3]:.0f} um; {len(a)} SRAM in A, {len(b)} SRAM in B, {len(rows)} rows")

    def region(x, y):
        for r in a:
            if inside(x, y, r):
                return "A: over an SRAM"
        for r in b:
            if inside(x, y, r):
                return "B: over an SRAM"
        for r in rows:
            if inside(x, y, r):
                return "over a row macro"
        if A and inside(x, y, A):
            return "A: between SRAMs"
        if B and inside(x, y, B):
            return "B: between SRAMs"
        if R and inside(x, y, R):
            return "channel between rows"
        if A and R and A[2] < x < R[0] and y >= R[1]:
            return "FeatureSkew strip (A..rows)"
        if R and B and B[3] < y < R[1]:
            return "OutputDeskew band (B..rows)"
        if B and y < B[1]:
            return "south band (result pins)"
        if A and x < A[0]:
            return "west strip (input pins)"
        if R and x > R[2]:
            return "east margin"
        return "other"

    cell_w = die[2] / cols
    nrows = max(1, round(cols * die[3] / die[2] / 2))      # characters are ~2x taller than wide
    cell_h = die[3] / nrows
    grid = {"H": collections.Counter(), "V": collections.Counter()}
    reg = collections.Counter(); regcnt = collections.Counter(); nets = collections.Counter()
    rawnets = collections.Counter()
    tot = {"H": 0, "V": 0}
    kind, srcs, ovf = None, [], 0
    for line in open(rpt, errors="ignore"):
        s = line.strip()
        if s.startswith("violation type:"):
            kind = "H" if "Horizontal" in s else "V"
        elif s.startswith("srcs:"):
            srcs = [t[4:] if t.startswith("net:") else t for t in s[5:].split()]
        elif "overflow:" in s:
            ovf = int(re.search(r"overflow:\s*(-?\d+)", s).group(1))
        elif s.startswith("bbox"):
            n = list(map(float, re.findall(r"-?\d+(?:\.\d+)?", s)))
            if len(n) < 4 or kind is None:
                continue
            x, y = (n[0] + n[2]) / 2, (n[1] + n[3]) / 2
            r = region(x, y)
            reg[(r, kind)] += ovf; regcnt[r] += 1; tot[kind] += ovf
            grid[kind][(min(cols - 1, int(x / cell_w)), min(nrows - 1, int(y / cell_h)))] += ovf
            for net in srcs:
                nets[re.sub(r"\[\d+\]", "[*]", net)] += 1
                rawnets[net] += 1
            srcs, ovf = [], 0
    if not regcnt:
        print("no overflowing gcell edges in the report - global routing fits")
        return 0
    print(f"overflow total: horizontal {tot['H']}, vertical {tot['V']} (sum of usage-capacity over {sum(regcnt.values())} edges)")
    print("\nby region:            edges    H-overflow  V-overflow")
    for r in sorted(regcnt, key=lambda k: -(reg[(k, 'H')] + reg[(k, 'V')])):
        print(f"  {r:30s} {regcnt[r]:7d} {reg[(r, 'H')]:10d} {reg[(r, 'V')]:10d}")

    def base(cx, cy):
        x, y = (cx + 0.5) * cell_w, (cy + 0.5) * cell_h
        for rr in a + b:
            if inside(x, y, rr):
                return "#"
        for rr in rows:
            if inside(x, y, rr):
                return "="
        return "."
    for k, title in (("H", "horizontal"), ("V", "vertical")):
        mx = max(grid[k].values(), default=0)
        print(f"\n{title} overflow map ({cell_w:.0f} x {cell_h:.0f} um per character, 9 = {mx}):")
        for cy in range(nrows - 1, -1, -1):
            out = []
            for cx in range(cols):
                v = grid[k].get((cx, cy), 0)
                if v > 0 and mx > 0:
                    out.append(str(max(1, min(9, 1 + int(8 * math.log1p(v) / math.log1p(mx))))))
                else:
                    out.append(base(cx, cy))
            print("  " + "".join(out))
    print("\nnets on most overflowing edges (bus bits folded):")
    for n, c in nets.most_common(20):
        print(f"  {c:7d}  {n}")
    if "--nets" in sys.argv:
        attribute(deff, rawnets, rect)
    return 0


def macro_group(name):
    if "u_output_buffer" in name:
        return "B-SRAM(out)"
    if "u_input_buffer" in name:
        return "A-SRAM(in)"
    if "tile_mem" in name:
        return "A-SRAM(feeder)"
    if "g_pe_row" in name:
        return "row"
    return "macro"


def attribute(deff, rawnets, rect):
    """what the congested nets connect: macro pins (by group), top-level ports, plain cells"""
    want = dict(rawnets)
    macros = {n.replace("\\", ""): macro_group(n) for n in rect}
    sig_edges = collections.Counter(); sig_nets = collections.Counter(); example = {}
    hier = collections.Counter()
    master = {}                                   # instance -> cell master (std cells)
    cls_edges = collections.Counter(); cls_nets = collections.Counter()
    logic_cells = collections.Counter(); degree = collections.Counter()
    cur, pins, in_nets, in_comp = None, [], False, False
    with open(deff, errors="ignore") as f:
        for line in f:
            if not in_nets:
                if line.startswith("COMPONENTS "):
                    in_comp = True
                elif line.startswith("END COMPONENTS"):
                    in_comp = False
                elif in_comp:
                    m = re.match(r"\s*-\s+(\S+)\s+(\S+)", line)
                    if m and m.group(2).startswith("sky130_fd_sc"):
                        master[m.group(1).replace("\\", "")] = m.group(2).split("__")[-1]
                if line.startswith("NETS "):
                    in_nets = True
                continue
            if line.startswith("END NETS"):
                break
            m = re.match(r"\s*-\s+(\S+)", line)
            if m:
                cur = m.group(1).replace("\\", "")
                pins = []
            if cur is None:
                continue
            pins += re.findall(r"\(\s*(\S+)\s+(\S+)\s*\)", line)
            if ";" in line:
                if cur in want:
                    kinds = set()
                    for inst, pin in pins:
                        inst = inst.replace("\\", "")
                        if inst == "PIN":
                            kinds.add("port:" + re.sub(r"\[\d+\]$", "", pin.replace("\\", "")))
                        elif inst in macros:
                            kinds.add(macros[inst] + ":" + re.sub(r"\[\d+\]$", "", pin))
                        elif "." in inst:
                            hier[inst.split(".")[0]] += want[cur]
                    sig = " + ".join(sorted(kinds)) if kinds else "standard cells only"
                    sig_edges[sig] += want[cur]; sig_nets[sig] += 1
                    example.setdefault(sig, cur)
                    if not kinds:
                        types = set()
                        for inst, pin in pins:
                            mm = master.get(inst.replace("\\", ""), "")
                            if re.match(r"(s?df|edf|dl[xr]|dfb)", mm):
                                types.add("flop")
                            elif re.match(r"(buf|clkbuf|dlygate|clkdlybuf|dlymetal|inv|clkinv)", mm):
                                types.add("buffer")
                            elif mm.startswith("conb"):
                                types.add("tie")
                            elif mm:
                                types.add("logic")
                                logic_cells[re.sub(r"_\d+$", "", mm)] += want[cur]
                        cls = ("logic" if "logic" in types else
                               "flop -> flop (shift registers)" if types == {"flop"} else
                               "flops through buffers" if types == {"flop", "buffer"} else
                               "buffers only (repeater chains/trees)" if types == {"buffer"} else
                               "+".join(sorted(types)) or "unknown")
                        if cls == "logic":
                            cls = "logic with flops" if "flop" in types else "logic only"
                        cls_edges[cls] += want[cur]; cls_nets[cls] += 1
                        degree["2 pins" if len(pins) == 2 else "3-5 pins" if len(pins) <= 5 else "6+ pins"] += want[cur]
                cur = None
    tot = sum(sig_edges.values())
    if not tot:
        print("\n(no congested net found in the DEF NETS section)")
        return
    print("\nwhat the congested nets connect (share of overflowing net-edges):")
    for sig, c in sig_edges.most_common(15):
        print(f"  {100.0 * c / tot:5.1f}%  {sig_nets[sig]:6d} nets  {sig}   e.g. {example[sig]}")
    if hier:
        print("hierarchical cell names on those nets:", ", ".join(f"{k} {v}" for k, v in hier.most_common(8)))
    ct = sum(cls_edges.values())
    if ct:
        print("\nthe standard-cell-only nets, by what they join (share of their overflowing net-edges):")
        for c, v in cls_edges.most_common():
            print(f"  {100.0 * v / ct:5.1f}%  {cls_nets[c]:6d} nets  {c}")
        print("  by size:", ", ".join(f"{k} {100.0 * v / ct:.0f}%" for k, v in degree.most_common()))
        if logic_cells:
            print("  logic cell types on them:", ", ".join(f"{k} {v}" for k, v in logic_cells.most_common(12)))


if __name__ == "__main__":
    sys.exit(main())
