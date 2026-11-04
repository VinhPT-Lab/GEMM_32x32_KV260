#!/usr/bin/env python3
"""
def_window.py <routed.def> <merged.lef> <x> <y> [radius_um=12] [net ...]

What is around one point of a routed layout - for a DRC marker the router
could not clear (core_v6/v6r: the same met5 short at (3122, 2140) with every
seed). Lists, inside the square x+-r, y+-r:
  - instances (macros with their orientation; standard cells by name only),
  - macro pins and obstructions from the LEF, placed and oriented,
  - special-net shapes (power stripes, PDN vias),
  - signal wires and vias, per net,
and for the nets named on the command line (or the two nets of the marker
when given) which instance pins they connect and how their wire splits over
the layers. Coordinates in um.
"""
import collections
import re
import sys


def lef_macros(path):
    """{macro: {"size": (w, h), "pins": [(pin, layer, x0, y0, x1, y1)], "obs": [(layer, rect)]}}"""
    macros, cur, pin, layer, in_obs = {}, None, None, None, False
    for raw in open(path, errors="ignore"):
        line = raw.strip()
        m = re.match(r"MACRO\s+(\S+)", line)
        if m:
            cur = macros.setdefault(m.group(1), {"size": (0.0, 0.0), "pins": [], "obs": []})
            pin, in_obs, layer = None, False, None
            continue
        if cur is None:
            continue
        m = re.match(r"SIZE\s+([\d.]+)\s+BY\s+([\d.]+)", line)
        if m:
            cur["size"] = (float(m.group(1)), float(m.group(2)))
            continue
        m = re.match(r"PIN\s+(\S+)", line)
        if m:
            pin, in_obs = m.group(1), False
            continue
        if line.startswith("OBS"):
            in_obs, pin = True, None
            continue
        m = re.match(r"LAYER\s+(\S+)", line)
        if m:
            layer = m.group(1)
            continue
        m = re.match(r"RECT\s+(?:MASK\s+\d+\s+)?(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)", line)
        if m and layer:
            r = tuple(float(v) for v in m.groups())
            if in_obs:
                cur["obs"].append((layer, r))
            elif pin:
                cur["pins"].append((pin, layer) + r)
            continue
        if re.match(r"END\s+(\S+)", line) and cur is not None:
            name = line.split()[1] if len(line.split()) > 1 else ""
            if pin and name == pin:
                pin = None
            elif in_obs and name == "":
                in_obs = False
    return macros


def place(rect, loc, orient, size):
    """LEF rect (macro coords) -> die coords for DEF orientation N/S/FN/FS/E/W/FE/FW"""
    x0, y0, x1, y1 = rect
    w, h = size
    pts = []
    for x, y in ((x0, y0), (x1, y1)):
        if orient == "N":
            p = (x, y)
        elif orient == "S":
            p = (w - x, h - y)
        elif orient == "FN":
            p = (w - x, y)
        elif orient == "FS":
            p = (x, h - y)
        elif orient == "E":
            p = (y, w - x)
        elif orient == "W":
            p = (h - y, x)
        elif orient == "FE":
            p = (y, x)
        elif orient == "FW":
            p = (h - y, w - x)
        else:
            p = (x, y)
        pts.append(p)
    (a, b), (c, d) = pts
    return (loc[0] + min(a, c), loc[1] + min(b, d), loc[0] + max(a, c), loc[1] + max(b, d))


def hits(r, win):
    return not (r[2] < win[0] or r[0] > win[2] or r[3] < win[1] or r[1] > win[3])


def fmt(r):
    return f"({r[0]:.2f}, {r[1]:.2f})-({r[2]:.2f}, {r[3]:.2f})"


def main():
    if len(sys.argv) < 5:
        print(__doc__)
        return 2
    deff, lef = sys.argv[1], sys.argv[2]
    x, y = float(sys.argv[3]), float(sys.argv[4])
    rad = float(sys.argv[5]) if len(sys.argv) > 5 and re.match(r"^[\d.]+$", sys.argv[5]) else 12.0
    want = set(a.replace("\\", "") for a in sys.argv[5:] if not re.match(r"^[\d.]+$", a))
    win = (x - rad, y - rad, x + rad, y + rad)
    macros = lef_macros(lef)
    dbu = 1000.0
    comps = {}
    sect = None
    widths = {"li1": 0.17, "met1": 0.14, "met2": 0.14, "met3": 0.3, "met4": 0.3, "met5": 1.6}
    spec, sig = [], collections.defaultdict(list)
    netpins = collections.defaultdict(list)
    netlen = collections.defaultdict(collections.Counter)
    cur, cur_w = None, 0.0

    def seg_rect(layer, p1, p2, wid):
        hw = wid / 2
        return (min(p1[0], p2[0]) - hw, min(p1[1], p2[1]) - hw, max(p1[0], p2[0]) + hw, max(p1[1], p2[1]) + hw)

    def routing(line, special):
        nonlocal cur_w
        out = []
        for m in re.finditer(r"(?:ROUTED|NEW|FIXED|COVER)\s+(\S+)\s*(\d+)?(.*?)(?=\bNEW\b|;|$)", line):
            layer = m.group(1)
            wid = int(m.group(2)) / dbu if (special and m.group(2)) else widths.get(layer, 0.2)
            body = m.group(3)
            pts, last = [], None
            for pm in re.finditer(r"\(\s*(-?\d+|\*)\s+(-?\d+|\*)(?:\s+-?\d+)?\s*\)", body):
                px = last[0] if pm.group(1) == "*" else int(pm.group(1)) / dbu
                py = last[1] if pm.group(2) == "*" else int(pm.group(2)) / dbu
                last = (px, py)
                pts.append(last)
            via = re.search(r"\)\s*([A-Za-z_][\w\[\]]*)\s*(?:$|\bNEW\b|;|\+)", body)
            for a, b in zip(pts, pts[1:]):
                out.append((layer, seg_rect(layer, a, b, wid), "wire", (abs(a[0] - b[0]) + abs(a[1] - b[1]))))
            if via and pts:
                p = pts[-1]
                out.append((layer, (p[0] - 0.8, p[1] - 0.8, p[0] + 0.8, p[1] + 0.8), "via " + via.group(1), 0.0))
        return out

    with open(deff, errors="ignore") as f:
        for line in f:
            if line.startswith("UNITS DISTANCE MICRONS"):
                dbu = float(line.split()[3])
                continue
            for k in ("COMPONENTS", "SPECIALNETS", "NETS"):
                if line.startswith(k + " "):
                    sect = k
                    break
            if line.startswith("END COMPONENTS") or line.startswith("END SPECIALNETS") or line.startswith("END NETS"):
                sect = None
                continue
            if sect == "COMPONENTS":
                m = re.match(r"\s*-\s+(\S+)\s+(\S+).*?\+\s+(?:PLACED|FIXED)\s+\(\s*(-?\d+)\s+(-?\d+)\s*\)\s+(\S+)", line)
                if m:
                    comps[m.group(1).replace("\\", "")] = (m.group(2), (int(m.group(3)) / dbu, int(m.group(4)) / dbu),
                                                         m.group(5))
            elif sect in ("SPECIALNETS", "NETS"):
                m = re.match(r"\s*-\s+(\S+)", line)
                if m:
                    cur = m.group(1).replace("\\", "")
                if cur is None:
                    continue
                if sect == "NETS":
                    for a, b in re.findall(r"\(\s*(\S+)\s+(\S+)\s*\)", line):
                        if not re.match(r"^-?\d+$|^\*$", a):
                            netpins[cur].append((a.replace("\\", ""), b))
                for layer, r, kind, ln in routing(line, sect == "SPECIALNETS"):
                    if sect == "NETS":
                        netlen[cur][layer] += ln
                    if hits(r, win):
                        (spec if sect == "SPECIALNETS" else sig[cur]).append((layer, r, kind, cur))

    print(f"window {fmt(win)} (+-{rad:g} um around ({x:g}, {y:g}))\n")
    print("instances:")
    cells = []
    for name, (master, loc, orient) in comps.items():
        w, h = macros.get(master, {"size": (0, 0)})["size"]
        bb = place((0, 0, w, h), loc, orient, (w, h))
        if not hits(bb, win):
            continue
        if w * h > 2000:
            print(f"  MACRO {name} ({master}, {orient}) {fmt(bb)}")
            for pin, layer, *r in macros[master]["pins"]:
                pr = place(tuple(r), loc, orient, (w, h))
                if hits(pr, win):
                    print(f"      pin {pin:14s} {layer:5s} {fmt(pr)}")
            obs = collections.Counter()
            for layer, r in macros[master]["obs"]:
                if hits(place(r, loc, orient, (w, h)), win):
                    obs[layer] += 1
            if obs:
                print("      obstruction shapes in the window: " + ", ".join(f"{l} {n}" for l, n in sorted(obs.items())))
        else:
            cells.append(f"{name}({master.split('__')[-1]})")
    if cells:
        print("  cells: " + ", ".join(sorted(cells)[:60]) + (" ..." if len(cells) > 60 else ""))
    print("\nspecial nets (power) in the window:")
    agg = collections.Counter((s[3], s[0], s[2].split()[0]) for s in spec)
    for (net, layer, kind), n in sorted(agg.items()):
        ex = next(s[1] for s in spec if (s[3], s[0], s[2].split()[0]) == (net, layer, kind))
        print(f"  {net:8s} {layer:5s} {kind:4s} x{n:<3d} e.g. {fmt(ex)}")
    print("\nsignal wires and vias in the window:")
    for net in sorted(sig, key=lambda n: (n not in want, n)):
        items = sig[net]
        print(f"  {net}{'  <==' if net in want else ''}")
        for layer, r, kind, _ in sorted(items, key=lambda i: (i[0], i[1])):
            print(f"      {layer:5s} {kind:22s} {fmt(r)}")
    for net in sorted(want):
        print(f"\nnet {net}: pins " + ", ".join(f"{i}/{p}" for i, p in netpins.get(net, [])[:20]))
        print("   wire um: " + ", ".join(f"{l} {v:.0f}" for l, v in sorted(netlen.get(net, {}).items())))
        for i, p in netpins.get(net, [])[:20]:
            if i in comps:
                master, loc, orient = comps[i]
                print(f"   {i} ({master.split('__')[-1]}, {orient}) at ({loc[0]:.2f}, {loc[1]:.2f})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
