#!/usr/bin/env python3
"""
core_channels.py <layout.def> <merged.lef>

What sits in the narrow channels between the 32 row macros of gemm_core
(and in the band above row 0), and what those cells connect to.

The row macros block met1-met4, so a standard cell placed in a channel can
only reach anything outside its own channel by crossing a row vertically,
which global route cannot do without overflow. Cells that serve the
row-to-row nets (hold buffers on the weight/psum chain between neighbouring
rows) belong there; anything else is a placement problem.
"""
import collections
import re
import sys

ROW = "ProcessingElementRow"
SKIP = re.compile(r"(tapvpwrvgnd|decap|fill|tap_|__tap|endcap|PHY_)", re.I)


def lef_sizes(lef):
    size, cur = {}, None
    for line in open(lef, errors="ignore"):
        m = re.match(r"\s*MACRO\s+(\S+)", line)
        if m:
            cur = m.group(1)
            continue
        m = re.match(r"\s*SIZE\s+([\d.]+)\s+BY\s+([\d.]+)", line)
        if m and cur:
            size[cur] = (float(m.group(1)), float(m.group(2)))
    return size


def kind(master):
    t = master.split("__")[-1]
    if t.startswith("diode"):
        return "diode"
    if t.startswith("conb"):
        return "tie"
    if re.match(r"(s?df|edf|dl[xr]|dfb)", t):
        return "flop"
    if re.match(r"(clkbuf|clkinv|clkdlybuf)", t):
        return "clock buffer"
    if re.match(r"(buf|dlygate|dlymetal|inv)", t):
        return "buffer"
    return "logic"


def origin(name):
    if re.match(r"^(ANTENNA|INSDIODE)", name):
        return "antenna diode"
    n = name.split(".")[-1]
    for pat, what in ((r"^hold\d", "hold buffer (repair_timing -hold)"),
                      (r"^(ANTENNA|INSDIODE)", "antenna diode"),
                      (r"^(clkbuf|clkload|cts|delaybuf)", "clock tree"),
                      (r"^(split|wire|rebuffer|max_length|max_cap|max_slew|repeater|load_slew)", "repair_design buffer"),
                      (r"^(input|output)\d", "port buffer"),
                      (r"^_\d+_$", "synthesised logic (_N_)")):
        if re.match(pat, n):
            return what
    return "named cell (register / other)"


def prefix(name):
    return re.sub(r"\d+", "#", name.replace("\\", ""))


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    deff, lef = sys.argv[1:]
    size = lef_sizes(lef)
    dbu, die = 1000.0, None
    rows, cells = [], {}
    sect = None
    nets = []           # (name, [(inst, pin)])
    cur, pins = None, []
    with open(deff, errors="ignore") as f:
        for line in f:
            if line.startswith("UNITS DISTANCE MICRONS"):
                dbu = float(line.split()[3])
                continue
            if line.startswith("DIEAREA"):
                n = list(map(float, re.findall(r"-?\d+", line)))
                die = (n[0] / dbu, n[1] / dbu, n[-2] / dbu, n[-1] / dbu)
                continue
            if line.startswith("COMPONENTS "):
                sect = "comp"
                continue
            if line.startswith("NETS "):
                sect = "nets"
                continue
            if line.startswith("END COMPONENTS") or line.startswith("END NETS"):
                sect = None
                continue
            if sect == "comp":
                m = re.match(r"\s*-\s+(\S+)\s+(\S+).*?\+\s+(?:PLACED|FIXED)\s+\(\s*(-?\d+)\s+(-?\d+)\s*\)", line)
                if not m:
                    continue
                name, master = m.group(1).replace("\\", ""), m.group(2)
                x, y = int(m.group(3)) / dbu, int(m.group(4)) / dbu
                w, h = size.get(master, (0.0, 0.0))
                if master == ROW:
                    r = re.search(r"g_pe_row\[(\d+)\]", name)
                    rows.append((int(r.group(1)) if r else -1, x, y, x + w, y + h))
                elif master.startswith("sky130_fd_sc") and not SKIP.search(master):
                    cells[name] = (master, x + w / 2, y + h / 2, w * h)
            elif sect == "nets":
                m = re.match(r"\s*-\s+(\S+)", line)
                if m:
                    cur, pins = m.group(1).replace("\\", ""), []
                if cur is None:
                    continue
                pins += [(a.replace("\\", ""), b.replace("\\", "")) for a, b in re.findall(r"\(\s*(\S+)\s+(\S+)\s*\)", line)]
                if ";" in line:
                    nets.append((cur, pins))
                    cur = None
    if len(rows) < 2 or not cells:
        print(f"read {len(rows)} row macros and {len(cells)} cells from {deff} - nothing to do")
        return 1
    rows.sort(key=lambda r: r[2])                       # bottom to top
    x0, x1 = min(r[1] for r in rows), max(r[3] for r in rows)
    chans = []                                          # (label, y0, y1, row below, row above)
    for lo, hi in zip(rows, rows[1:]):
        chans.append((f"rows {hi[0]:>2}/{lo[0]:<2}", lo[4], hi[2], lo[0], hi[0]))
    top = rows[-1]
    chans.append((f"above row {top[0]}", top[4], die[3], top[0], None))
    def chan_of(cx, cy):
        if not (x0 <= cx <= x1):
            return None
        for i, c in enumerate(chans):
            if c[1] <= cy <= c[2]:
                return i
        return None

    inchan = {n: chan_of(v[1], v[2]) for n, v in cells.items()}
    inchan = {n: c for n, c in inchan.items() if c is not None}
    print(f"die {die[2]:.0f} x {die[3]:.0f} um; {len(rows)} row macros x {x0:.0f}..{x1:.0f}; "
          f"{len(cells)} standard cells (taps/decaps/fill left out)")
    area = sum(cells[n][3] for n in inchan)
    print(f"\n{len(inchan)} standard cells ({area / 1e6:.3f} mm2) sit in the {len(chans) - 1} channels between "
          f"rows and the band above row {top[0]}")
    if not inchan:
        return 0

    # what their nets touch
    rowname = re.compile(r"g_pe_row\[(\d+)\]\.u_row$")
    touch = collections.defaultdict(set)     # cell -> set of tags
    for net, pl in nets:
        mine = [i for i, _ in pl if i in inchan]
        if not mine:
            continue
        tags = set()
        outside = False
        for inst, pin in pl:
            m = rowname.search(inst)
            if m:
                base = re.sub(r"\[\d+\]$", "", pin)
                tags.add((int(m.group(1)), base))
            elif inst == "PIN":
                tags.add(("port", re.sub(r"\[\d+\]$", "", pin)))
            elif inst in cells and inst not in inchan:
                outside = True
        for i in mine:
            touch[i] |= tags
            if outside:
                touch[i].add(("outside", ""))
    by_use = collections.Counter()
    examples = {}
    for n, c in inchan.items():
        t = touch.get(n, set())
        rowpins = {(r, p) for r, p in t if isinstance(r, int)}
        bases = {p for _, p in rowpins}
        idx = {r for r, _ in rowpins}
        chain = {"i_weight_shift_in", "o_weight_shift_out", "i_partial_sum_vector", "o_partial_sum_vector"}
        if rowpins and bases <= chain and ("outside", "") not in t and len(idx) <= 2:
            use = "row-to-row chain only (expected here)"
        elif any(p == "i_weight_shift_in" for p in bases) and ("outside", "") in t:
            use = "row weight-in pin + cells outside the rows (weight bus from the feeder)"
        elif bases & {"i_clk", "i_rst_n", "i_weight_shift_en", "i_weight_load"} or any(p.startswith("i_feature") for p in bases):
            use = "row west-edge pin (feature / clock / control)"
        elif rowpins:
            use = "other row pins: " + ",".join(sorted(bases))[:60]
        elif ("outside", "") in t:
            use = "no row pin, nets leave the channel (misplaced)"
        else:
            use = "no row pin, nets stay inside the channels"
        by_use[use] += 1
        examples.setdefault(use, n)
    print("\nwhat their nets connect to:")
    for u, k in by_use.most_common():
        print(f"  {k:7d}  {u}   e.g. {examples[u]}")

    print("\nby origin (instance name):")
    org = collections.Counter(origin(n) for n in inchan)
    for o, k in org.most_common():
        print(f"  {k:7d}  {o}")
    print("by kind:", ", ".join(f"{k} {v}" for k, v in collections.Counter(kind(cells[n][0]) for n in inchan).most_common()))
    pre = collections.Counter(prefix(n if n.startswith(("ANTENNA", "INSDIODE")) else n.split(".")[-1])[:40] for n in inchan)
    print("commonest instance names:", ", ".join(f"{p} {k}" for p, k in pre.most_common(10)))
    hier = collections.Counter(".".join(re.sub(r"^(ANTENNA|INSDIODE\d*)_", "", n).split(".")[:3]) for n in inchan if "." in n)
    if hier:
        print("hierarchy of named cells:", ", ".join(f"{h} {k}" for h, k in hier.most_common(6)))

    print("\nhow far into the rows (distance from their west edge):")
    bins = [(0, 300), (300, 1000), (1000, 2000), (2000, 1e9)]
    dist = collections.Counter()
    for n in inchan:
        d = cells[n][1] - x0
        for lo, hi in bins:
            if lo <= d < hi:
                dist[(lo, hi)] += 1
    print("  " + ", ".join(f"{lo:.0f}-{'end' if hi > 1e8 else f'{hi:.0f}'} um: {dist[(lo, hi)]}" for lo, hi in bins))

    print("\nper channel (cells, of which not on the row-to-row chain):")
    per = collections.Counter(inchan.values())
    bad = collections.Counter()
    for n, c in inchan.items():
        t = touch.get(n, set())
        rowpins = {(r, p) for r, p in t if isinstance(r, int)}
        chain = {"i_weight_shift_in", "o_weight_shift_out", "i_partial_sum_vector", "o_partial_sum_vector"}
        if not (rowpins and {p for _, p in rowpins} <= chain and ("outside", "") not in t):
            bad[c] += 1
    line = []
    for i, ch in enumerate(chans):
        if per[i]:
            line.append(f"{ch[0]}: {per[i]} ({bad[i]})")
    for k in range(0, len(line), 4):
        print("  " + "   ".join(line[k:k + 4]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
