#!/usr/bin/env python3
"""
antenna_nets.py <antenna_violators.rpt> <routed.def> <merged.lef>

Why do these nets violate the antenna rule? For every net in the OpenROAD ARC
report: where its pins sit (FeatureSkew strip, channel between rows,
OutputDeskew band, region A / B, elsewhere), the manhattan span of the pins
(OpenLane's heuristic only protects nets spanning >= HEURISTIC_ANTENNA_THRESHOLD),
how much wire it has per layer (and the longest single segment on the
violating layer), which macros it touches, whether a diode is on it and how
far that diode sits from the violating pin. The summary at the end says which
of those explanations covers how many violations.
A macro pin is placed at the point of the macro outline nearest to the
violating cell (the DEF alone does not say where the pin is).
"""
import collections
import re
import sys

ROW = "ProcessingElementRow"
SRAM = "sky130_sram_2kbyte_1rw1r_32x512_8"


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


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        return 2
    rpt, deff, lef = sys.argv[1:]
    viol = []                                   # (net, inst, pin, layer, ratio)
    for line in open(rpt, errors="ignore"):
        m = re.search(r"Partial/Required:\s*([\d.]+).*?Required:\s*([\d.]+).*?Net: (\S+), Pin: (\S+?)/(\S+), Layer: (\S+)", line)
        if m:
            viol.append((m.group(3).replace("\\", ""), m.group(4).replace("\\", ""), m.group(5),
                         m.group(6), float(m.group(1)), float(m.group(2))))
    want = {v[0] for v in viol}
    size = lef_sizes(lef)
    dbu = 1000.0
    comp, rows, srams = {}, [], []
    netpins, netwire, netseg = {}, {}, {}
    sect, cur, pins, wl, sl, layer = None, None, [], None, None, None
    with open(deff, errors="ignore") as f:
        for line in f:
            if line.startswith("UNITS DISTANCE MICRONS"):
                dbu = float(line.split()[3])
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
                if m:
                    name, master = m.group(1).replace("\\", ""), m.group(2)
                    x, y = int(m.group(3)) / dbu, int(m.group(4)) / dbu
                    w, h = size.get(master, (0.0, 0.0))
                    comp[name] = (master, x + w / 2, y + h / 2, x, y, x + w, y + h)
                    if master == ROW:
                        rows.append((x, y, x + w, y + h))
                    elif master == SRAM:
                        srams.append((x, y, x + w, y + h, name))
            elif sect == "nets":
                m = re.match(r"\s*-\s+(\S+)", line)
                if m:
                    if cur in want:
                        netpins[cur], netwire[cur], netseg[cur] = pins, wl, sl
                    cur = m.group(1).replace("\\", "")
                    pins, wl, sl, layer = [], collections.Counter(), collections.Counter(), None
                if cur not in want:
                    continue
                pins += [(a.replace("\\", ""), b) for a, b in re.findall(r"\(\s*(\S+)\s+(\S+)\s*\)", line)
                         if not re.match(r"^-?\d+$|^\*$", a)]
                for lm in re.finditer(r"(?:ROUTED|NEW)\s+(\S+)(.*?)(?=NEW|;|$)", line):
                    layer = lm.group(1)
                    pts = re.findall(r"\(\s*(-?\d+|\*)\s+(-?\d+|\*)(?:\s+-?\d+)?\s*\)", lm.group(2))
                    if len(pts) >= 2:
                        (x1, y1), (x2, y2) = pts[0], pts[1]
                        x2 = x1 if x2 == "*" else x2
                        y2 = y1 if y2 == "*" else y2
                        d = (abs(int(x2) - int(x1)) + abs(int(y2) - int(y1))) / dbu
                        wl[layer] += d
                        sl[layer] = max(sl[layer], d)
        if cur in want:
            netpins[cur], netwire[cur], netseg[cur] = pins, wl, sl
    rows.sort(key=lambda r: r[1])
    rx0 = min((r[0] for r in rows), default=0)
    rx1 = max((r[2] for r in rows), default=0)
    ybot = rows[0][1] if rows else 0
    ytop = rows[-1][3] if rows else 0

    def where(x, y):
        for (x0, y0, x1, y1, n) in srams:
            if x0 - 300 <= x <= x1 + 300 and y0 - 220 <= y <= y1 + 220:
                return "region B" if "output_buffer" in n else "region A"
        if rows and rx0 <= x <= rx1 and ybot <= y <= ytop:
            return "channel between rows"
        if rows and x < rx0 and ybot <= y <= ytop:
            return "FeatureSkew strip / feeder side"
        if rows and rx0 - 300 <= x <= rx1 and ybot - 500 <= y < ybot:
            return "OutputDeskew band"
        return "elsewhere"

    def big(master):
        w, h = size.get(master, (0.0, 0.0))
        return master in (ROW, SRAM) or w * h > 2000

    def pin_xy(inst, ref):
        c = comp[inst]
        if not big(c[0]) or ref is None:
            return c[1], c[2]
        return min(max(ref[0], c[3]), c[5]), min(max(ref[1], c[4]), c[6])

    def macro_kind(master):
        return "row" if master == ROW else "sram" if master == SRAM else "macro"

    reasons = collections.Counter()
    places = collections.Counter()
    touch = collections.Counter()
    print(f"{len(viol)} violations on {len(want)} nets\n")
    print(f"{'ratio':>6} {'layer':5} {'span':>6} {'wire um (m1/m2/m3/m4/m5)':>26} {'lseg':>5} {'diode':>6}  "
          f"pin (cell) - where [macros on the net]")
    for net, inst, pin, lay, ratio, req in viol:
        ps = netpins.get(net, [])
        me = comp.get(inst)
        ref = (me[1], me[2]) if me else None
        locs = [pin_xy(i, ref) for i, _ in ps if i in comp]
        macros = sorted({macro_kind(comp[i][0]) for i, _ in ps if i in comp and big(comp[i][0])})
        span = (max(x for x, _ in locs) - min(x for x, _ in locs) + max(y for _, y in locs) - min(y for _, y in locs)) if locs else -1
        diodes = [comp[i][1:3] for i, _ in ps if i in comp and "diode" in comp[i][0]]
        dd = min((abs(me[1] - x) + abs(me[2] - y) for x, y in diodes), default=None) if me else None
        wl = netwire.get(net, collections.Counter())
        seg = netseg.get(net, collections.Counter()).get(lay, 0)
        wtxt = "/".join(f"{wl.get(l, 0):.0f}" for l in ("met1", "met2", "met3", "met4", "met5"))
        loc = where(me[1], me[2]) if me else "?"
        places[loc] += 1
        if req > 400.5:
            r = "has a diode but still over the limit (diode too small / too far)"
        elif not diodes and 0 <= span < 50:
            r = "no diode, pins span < 50 um (heuristic skipped it) but the route is long"
        elif not diodes:
            r = "no diode on a net spanning >= 50 um"
        elif dd is not None and dd > 20:
            r = "diode on the net but > 20 um from this pin (other metal island)"
        else:
            r = "diode next to the pin, still flagged"
        reasons[r] += 1
        print(f"{ratio:6.2f} {lay:5} {span:6.0f} {wtxt:>26} {seg:5.0f} {('-' if dd is None else f'{dd:.0f}'):>6}  "
              f"{inst}/{pin} ({me[0].split('__')[-1] if me else '?'}) - {loc}"
              + (f" [{','.join(macros)}]" if macros else ""))
        if macros:
            touch[",".join(macros)] += 1
    print("\nwhy (count of violations):")
    for r, c in reasons.most_common():
        print(f"  {c:5d}  {r}")
    print("where the violating pin sits:")
    for r, c in places.most_common():
        print(f"  {c:5d}  {r}")
    print("violations on nets that touch a macro pin:")
    for r, c in touch.most_common():
        print(f"  {c:5d}  {r}")
    print("(lseg = longest single wire segment on the violating layer, um)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
