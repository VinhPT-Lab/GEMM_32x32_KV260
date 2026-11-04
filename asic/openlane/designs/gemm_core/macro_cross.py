#!/usr/bin/env python3
"""
macro_cross.py - nets whose global-route guide runs THROUGH a macro.

  macro_cross.py --guide <global.guide> --def <placed/routed.def> --lef <merged.lef>
                 [--grt-obs "<GRT_OBS>"] [--depth 5] [--report <macro_cross.rpt>]

core_v7r: the SRAMs block met1-met4 and GRT_OBS blocks met5 over them, so a
vertical net has no layer across an SRAM; FastRoute (18 congestion rounds,
GRT_ALLOW_CONGESTION 1) still left net3191 with a guide straight through
u_accum_mem g_bank[0] g_lane[11], and the detailed router then shorted it on
met2 with every seed. This check runs between global and detailed routing.

A layer counts as blocked inside a macro when the macro's LEF OBS covers at
least half of its area on that layer, or a GRT_OBS rectangle on that layer
covers the macro. A net is listed when one of its guide rectangles on a
blocked layer reaches more than --depth um inside the macro bbox, and FAILS the
check beyond --stop-depth (default 50 um). Guides are whole 6.9 um gcells not
aligned to the macro edge, so cells next to a macro reach up to ~7 um in;
pin access of a net that has a pin on that macro is left out up to
--pin-depth; met5 over a row macro is not blocked and never counts.
Plain Python (no odb), so it runs in the OpenLane container and on the host.
Exit status: 0 no crossing, 3 crossings found, 2 bad input.
"""
import argparse
import collections
import re
import sys


def lef_blocks(path):
    """{macro: (w, h, {layer: covered fraction})} for CLASS BLOCK macros"""
    out, cur, cls, size, obs, in_obs, layer = {}, None, None, None, None, False, None
    for raw in open(path, errors="ignore"):
        line = raw.strip()
        m = re.match(r"MACRO\s+(\S+)", line)
        if m:
            cur, cls, size, obs, in_obs = m.group(1), None, None, collections.defaultdict(float), False
            continue
        if cur is None:
            continue
        if re.match(r"CLASS\s+BLOCK\b", line):
            cls = "BLOCK"
        m = re.match(r"SIZE\s+([\d.]+)\s+BY\s+([\d.]+)", line)
        if m:
            size = (float(m.group(1)), float(m.group(2)))
        if line.startswith("OBS"):
            in_obs = True
        elif in_obs and line.startswith("END") and not re.match(r"END\s+" + re.escape(cur) + r"\s*$", line):
            in_obs = False
        elif in_obs:
            m = re.match(r"LAYER\s+(\S+)", line)
            if m:
                layer = m.group(1)
            m = re.match(r"RECT\s+(?:MASK\s+\d+\s+)?(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)", line)
            if m and layer:
                x0, y0, x1, y1 = map(float, m.groups())
                obs[layer] += abs(x1 - x0) * abs(y1 - y0)
        if re.match(r"END\s+" + re.escape(cur) + r"\s*$", line):
            if cls == "BLOCK" and size:
                a = size[0] * size[1]
                out[cur] = (size[0], size[1], {l: v / a for l, v in obs.items()})
            cur = None
    return out


def place(w, h, x, y, orient):
    if orient in ("E", "W", "FE", "FW"):
        w, h = h, w
    return (x, y, x + w, y + h)


def def_macros(path, blocks):
    """[(name, master, bbox_um)] of the CLASS BLOCK instances in COMPONENTS, and
    {net: {macro instance}} for the nets that have a pin on one of them"""
    out, dbu, sect, names = [], 1000.0, None, set()
    pins, net = collections.defaultdict(set), None
    with open(path, errors="ignore") as f:
        for line in f:
            if line.startswith("UNITS DISTANCE MICRONS"):
                dbu = float(line.split()[3])
            elif line.startswith("COMPONENTS "):
                sect = "C"
            elif line.startswith("NETS "):
                sect = "N"
            elif line.startswith("END COMPONENTS"):
                names = {o[0] for o in out}
                sect = None
            elif line.startswith("END NETS"):
                break
            elif sect == "N":
                m = re.match(r"\s*-\s+(\S+)", line)
                if m:
                    net = m.group(1).replace("\\", "")
                for inst, _ in re.findall(r"\(\s*(\S+)\s+(\S+)\s*\)", line):
                    inst = inst.replace("\\", "")
                    if inst in names:
                        pins[net].add(inst)
            elif sect == "C":
                m = re.match(r"\s*-\s+(\S+)\s+(\S+).*?\+\s+(?:PLACED|FIXED)\s+\(\s*(-?\d+)\s+(-?\d+)\s*\)\s+(\S+)", line)
                if m and m.group(2) in blocks:
                    w, h, _ = blocks[m.group(2)]
                    out.append((m.group(1).replace("\\", ""), m.group(2),
                                place(w, h, int(m.group(3)) / dbu, int(m.group(4)) / dbu, m.group(5))))
    return out, dbu, pins


def grt_obs(text):
    """[(layer, (x0, y0, x1, y1))] from a GRT_OBS string "met5 x0 y0 x1 y1, ..." """
    out = []
    for part in (text or "").split(","):
        p = part.split()
        if len(p) == 5:
            out.append((p[0], tuple(float(v) for v in p[1:])))
    return out


def covers(o, b):
    return o[0] <= b[0] + 1e-3 and o[1] <= b[1] + 1e-3 and o[2] >= b[2] - 1e-3 and o[3] >= b[3] - 1e-3


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--guide", required=True)
    ap.add_argument("--def", dest="deff", required=True)
    ap.add_argument("--lef", required=True)
    ap.add_argument("--grt-obs", default="")
    ap.add_argument("--depth", type=float, default=5.0, help="list guides deeper than this (um)")
    ap.add_argument("--stop-depth", type=float, default=50.0,
                    help="FAIL (exit 3) only for guides deeper than this (um). core_v7r: guides up to 31 um"
                         " deep (gcells across a macro edge, short detours) routed clean; net3191, 208 um"
                         " deep = straight through an SRAM, shorted with every seed")
    ap.add_argument("--min-cover", type=float, default=0.5)
    ap.add_argument("--pin-depth", type=float, default=15.0,
                    help="a net with a pin on the macro may reach this deep (pin access: guides are"
                         " whole 6.9 um gcells, not aligned to the macro edge)")
    ap.add_argument("--report", default="")
    a = ap.parse_args()

    blocks = lef_blocks(a.lef)
    if not blocks:
        print(f"macro_cross: no CLASS BLOCK macro in {a.lef}")
        return 2
    macros, dbu, pins = def_macros(a.deff, blocks)
    obs = grt_obs(a.grt_obs)
    # per macro: the inner box (bbox shrunk by depth) and its blocked layers
    inner = []
    for name, master, b in macros:
        lay = {l for l, f in blocks[master][2].items() if f >= a.min_cover}
        lay |= {l for l, o in obs if covers(o, b)}
        ib = (b[0] + a.depth, b[1] + a.depth, b[2] - a.depth, b[3] - a.depth)
        if ib[0] < ib[2] and ib[1] < ib[3] and lay:
            inner.append((name, master, ib, lay, b))
    # coarse bucket grid over the inner boxes
    G = 500.0
    grid = collections.defaultdict(list)
    for k, (_, _, ib, _, _) in enumerate(inner):
        for gx in range(int(ib[0] // G), int(ib[2] // G) + 1):
            for gy in range(int(ib[1] // G), int(ib[3] // G) + 1):
                grid[(gx, gy)].append(k)

    hits = collections.defaultdict(lambda: collections.defaultdict(lambda: [0, 0.0]))  # net -> (macro, layer) -> [rects, depth]
    net, nets = None, 0
    rect = re.compile(r"^(-?\d+)\s+(-?\d+)\s+(-?\d+)\s+(-?\d+)\s+(\S+)\s*$")
    with open(a.guide, errors="ignore") as f:
        for line in f:
            m = rect.match(line)
            if not m:
                s = line.strip()
                if s and s not in ("(", ")"):
                    net, nets = s.replace("\\", ""), nets + 1
                continue
            x0, y0, x1, y1 = (int(m.group(i)) / dbu for i in range(1, 5))
            layer = m.group(5)
            seen = set()
            for gx in range(int(x0 // G), int(x1 // G) + 1):
                for gy in range(int(y0 // G), int(y1 // G) + 1):
                    for k in grid.get((gx, gy), ()):
                        if k in seen:
                            continue
                        seen.add(k)
                        name, master, ib, lay, b = inner[k]
                        if layer in lay and x0 < ib[2] and x1 > ib[0] and y0 < ib[3] and y1 > ib[1]:
                            # depth of the guide point closest to the macro centre
                            px = min(max((b[0] + b[2]) / 2, x0), x1)
                            py = min(max((b[1] + b[3]) / 2, y0), y1)
                            d = min(px - b[0], b[2] - px, py - b[1], b[3] - py)
                            h = hits[net][(name, layer)]
                            h[0] += 1
                            h[1] = max(h[1], d)

    exempt = collections.Counter()
    for n in list(hits):
        for (name, layer), (cnt, d) in list(hits[n].items()):
            if name in pins.get(n, ()) and d <= a.pin_depth:
                exempt[layer] += 1
                del hits[n][(name, layer)]
        if not hits[n]:
            del hits[n]
    deep = {n for n, v in hits.items() if any(d > a.stop_depth for _, d in v.values())}
    L = [f"macro_cross: global-route guides more than {a.depth:g} um inside a macro, on a layer the macro blocks",
         f"  guide {a.guide}", f"  {nets} nets, {len(macros)} macros, GRT_OBS rectangles: {len(obs)}",
         f"  pin access left out (net has a pin on that macro, guide <= {a.pin_depth:g} um deep): "
         + (", ".join(f"{l} {c}" for l, c in sorted(exempt.items())) or "none"),
         f"  nets THROUGH a macro (guide > {a.stop_depth:g} um deep - detailed routing cannot fix): {len(deep)}"]
    for n in sorted(deep):
        for (name, layer), (cnt, d) in sorted(hits[n].items()):
            master = next(m for nm, m, _ in macros if nm == name)
            L.append(f"    {n:30s} {layer:5s} {cnt:4d} guide rect(s), up to {d:.1f} um deep in {name} ({master})")
    L.append(f"  nets with a guide {a.depth:g}-{a.stop_depth:g} um inside a macro (listed only): {len(hits) - len(deep)}")
    for n in sorted(set(hits) - deep):
        for (name, layer), (cnt, d) in sorted(hits[n].items()):
            master = next(m for nm, m, _ in macros if nm == name)
            L.append(f"    {n:30s} {layer:5s} {cnt:4d} guide rect(s), up to {d:.1f} um deep in {name} ({master})")
    L.append("RESULT: " + ("PASS - no net routed through a macro" if not deep else
                           f"FAIL - {len(deep)} net(s) routed through a macro; detailed routing cannot fix that"))
    text = "\n".join(L) + "\n"
    print(text, end="")
    if a.report:
        open(a.report, "w").write(text)
    return 3 if deep else 0


if __name__ == "__main__":
    sys.exit(main())
