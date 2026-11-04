#!/usr/bin/env python3
"""antenna_breakdown.py <OpenLane run dir> [--name core_v11] [--out-dir openlane/logs] [--tsv pins.tsv]

Where the antenna violations of a run are, by RTL module. Reads only the run:
  - the signoff violator list (reports/signoff/<last>-antenna_violators.rpt:
    net, pin, layer, Partial, Required) and the matching check_antennas -verbose
    log (logs/signoff/<same index>-arc.log: net/pin/layer blocks marked
    VIOLATED, used to cross-check the list and for the ratio kind);
  - the final netlist (results/final/verilog/gl/<design>.nl.v);
  - the final DEF (results/final/def/<design>.def) and the merged LEF in tmp/.

Every violation is given a module, in this order (the method is recorded):
  name   - hierarchy prefix of the net name (flat netlist keeps u_xxx.yyy);
  trace  - anonymous net (_1234_, net5678): breadth-first through the cells of
           the final netlist to the nearest named nets (at most --max-hops cell
           hops, not through nets with more than --max-fanout pins), majority;
  region - still nothing: position of the violating gate in the DEF against
           the macro groups of the floorplan (gen_core_files.py: region A =
           input buffer + feeder SRAMs, region B = accumulator SRAMs under the
           array, the row macros, the FeatureSkew strip between A and the rows,
           the South output band, the West pin band).
Per violation also: routed wire length of the net (DEF), its layers, ratio and
limit, and whether it touches a macro pin (row, SRAM, other macro) or an I/O pin.

Writes <out-dir>/antenna_breakdown_<name>.md, and a map of the die (macros as
rectangles, violations coloured by module) as .png with matplotlib, else as
.svg (+ .png through rsvg-convert when it is installed).
"""
import argparse
import collections
import glob
import os
import re
import statistics
import sys

ANON = re.compile(r"^(?:_\d+_|net\d+|clknet_\S+|ANTENNA_\S+)$")
RPT = re.compile(r"Partial/Required:\s*([\d.]+),\s*Required:\s*([\d.]+),\s*Partial:\s*([\d.]+),"
                 r"\s*Net:\s*(\S+),\s*Pin:\s*(\S+),\s*Layer:\s*(\S+)")


def canon(name):
    """DEF / report / netlist spelling -> one form: no escapes"""
    name = name.strip()
    if name.startswith("\\"):
        name = name[1:]
    return name.replace("\\", "")


def module_of(name, depth):
    """hierarchy prefix of a net/instance name, generate indices collapsed, at most depth levels"""
    n = canon(name)
    parts = re.split(r"\.(?![^\[]*\])", n)
    if len(parts) < 2:
        return None
    mods = [re.sub(r"\[\d+\]", "[*]", p) for p in parts[:-1]]
    return ".".join(mods[:depth])


def last_index(paths, pat):
    best, bi = None, -1
    for p in paths:
        m = re.match(pat, os.path.basename(p))
        if m and int(m.group(1)) > bi:
            best, bi = p, int(m.group(1))
    return best, bi


# ---------------------------------------------------------------- inputs
def read_report(run):
    rpts = glob.glob(os.path.join(run, "reports/signoff/*-antenna_violators.rpt"))
    rpt, idx = last_index(rpts, r"(\d+)-antenna_violators\.rpt$")
    if rpt is None:
        sys.exit(f"no reports/signoff/*-antenna_violators.rpt in {run}")
    out = []
    for line in open(rpt, errors="ignore"):
        m = RPT.search(line)
        if m:
            pin = m.group(5)
            inst, _, term = pin.rpartition("/")
            out.append(dict(ratio=float(m.group(1)), required=float(m.group(2)), partial=float(m.group(3)),
                            net=canon(m.group(4)), inst=canon(inst), pin=term, layer=m.group(6)))
    return rpt, idx, out


def read_arc_log(run, idx):
    """(net, inst/pin, layer) -> ratio kind for the VIOLATED lines of the -verbose log; summary counts"""
    log = os.path.join(run, f"logs/signoff/{idx}-arc.log")
    if not os.path.exists(log):
        cands = glob.glob(os.path.join(run, "logs/signoff/*-arc.log"))
        log, _ = last_index(cands, r"(\d+)-arc\.log$")
    kinds, counts = {}, {}
    if not log:
        return None, kinds, counts
    net = pin = layer = None
    for line in open(log, errors="ignore"):
        s = line.strip()
        if s.startswith("Net:"):
            net = canon(s[4:])
        elif s.startswith("Pin:"):
            pin = canon(s[4:].split()[0])
        elif s.startswith("Layer:"):
            layer = s[6:].strip()
        elif "(VIOLATED)" in s:
            m = re.search(r"\(([^)]*area)\)", s)
            kinds[(net, pin, layer)] = m.group(1) if m else "?"
        m = re.search(r"Found (\d+) (net|pin) violations", s)
        if m:
            counts[m.group(2)] = int(m.group(1))
    return log, kinds, counts


def lef_blocks(paths):
    out = {}
    for path in paths:
        cur, cls = None, None
        for raw in open(path, errors="ignore"):
            s = raw.strip()
            m = re.match(r"MACRO\s+(\S+)", s)
            if m:
                cur, cls = m.group(1), None
                continue
            if cur and re.match(r"CLASS\s+BLOCK\b", s):
                cls = "BLOCK"
            m = re.match(r"SIZE\s+([\d.]+)\s+BY\s+([\d.]+)", s)
            if cur and m and cls == "BLOCK":
                out[cur] = (float(m.group(1)), float(m.group(2)))
            if cur and re.match(r"END\s+" + re.escape(cur) + r"\s*$", s):
                cur = None
    return out


def read_def(path, blocks, want_nets, want_insts):
    """die, dbu, macros [(name, master, x0, y0, x1, y1)], positions of want_insts,
    I/O pin names, and for want_nets: connections + routed length per layer"""
    dbu, die = 1000.0, None
    macros, pos, ios = [], {}, set()
    nets = {}
    sect = None
    pend = ""
    cur = None
    last = None
    layer = None
    with open(path, errors="ignore") as f:
        for line in f:
            if sect is None:
                if line.startswith("UNITS DISTANCE MICRONS"):
                    dbu = float(line.split()[3])
                elif line.startswith("DIEAREA"):
                    v = [float(t) for t in re.findall(r"-?\d+", line)]
                    die = (v[0] / dbu, v[1] / dbu, v[2] / dbu, v[3] / dbu)
                elif line.startswith("COMPONENTS"):
                    sect = "C"
                elif line.startswith("PINS"):
                    sect = "P"
                elif line.startswith("NETS"):
                    sect = "N"
                continue
            if line.startswith("END "):
                sect = None
                continue
            if sect == "C":
                pend += line
                if ";" not in line:
                    continue
                m = re.match(r"\s*-\s+(\S+)\s+(\S+).*?\+\s+(?:FIXED|PLACED)\s+\(\s*(-?\d+)\s+(-?\d+)\s*\)\s+(\S+)",
                             pend.replace("\n", " "))
                pend = ""
                if not m:
                    continue
                name, master = canon(m.group(1)), m.group(2)
                x, y = int(m.group(3)) / dbu, int(m.group(4)) / dbu
                if master in blocks:
                    w, h = blocks[master]
                    if m.group(5) in ("E", "W", "FE", "FW"):
                        w, h = h, w
                    macros.append((name, master, x, y, x + w, y + h))
                if name in want_insts:
                    pos[name] = (x, y)
            elif sect == "P":
                m = re.match(r"\s*-\s+(\S+)", line)
                if m:
                    ios.add(canon(m.group(1)))
            elif sect == "N":
                m = re.match(r"\s*-\s+(\S+)", line)
                if m:
                    n = canon(m.group(1))
                    cur = n if n in want_nets else None
                    if cur:
                        nets[cur] = dict(conns=[], length=collections.Counter())
                    last = None
                    line = line[m.end():]
                if cur is None:
                    continue
                d = nets[cur]
                for a, b in re.findall(r"\(\s*(\S+)\s+(\S+)\s*\)", line):
                    if a == "PIN":
                        d["conns"].append(("PIN", canon(b)))
                    elif not re.match(r"^[-\d*]+$", a):
                        d["conns"].append((canon(a), b))
                # routing: [+ ROUTED|NEW] layer ( x y ) ( x y ) ... [via]
                m = re.search(r"(?:ROUTED|NEW|FIXED)\s+(\S+)", line)
                if m:
                    layer = m.group(1)
                    last = None
                    line = line[m.end():]
                for xs, ys in re.findall(r"\(\s*(-?\d+|\*)\s+(-?\d+|\*)(?:\s+-?\d+)?\s*\)", line):
                    if last is None:
                        last = (int(xs), int(ys)) if xs != "*" and ys != "*" else None
                        continue
                    x = last[0] if xs == "*" else int(xs)
                    y = last[1] if ys == "*" else int(ys)
                    d["length"][layer] += (abs(x - last[0]) + abs(y - last[1])) / dbu
                    last = (x, y)
                if line.rstrip().endswith(";"):
                    cur = None
    return die, dbu, macros, pos, ios, nets


def read_netlist(path):
    """net -> [instance], instance -> [net] (canonical names), from a flat gate netlist"""
    net_insts = collections.defaultdict(list)
    inst_nets = {}
    cell = re.compile(r"^\s*(\S+)\s+(\\\S+|\S+)\s*\(\s*$|^\s*(\S+)\s+(\\\S+|\S+)\s*\((\..*)$")
    cur, buf = None, ""
    with open(path, errors="ignore") as f:
        for line in f:
            if cur is None:
                m = cell.match(line)
                if not m or line.lstrip().startswith(("module", "input", "output", "wire", "inout", "assign", "//")):
                    continue
                cur = canon(m.group(2) or m.group(4))
                buf = m.group(5) or ""
            else:
                buf += line
            if ");" in buf or (cur and line.rstrip().endswith(");")):
                nets = [canon(n) for n in re.findall(r"\.\w+\s*\(\s*(\\\S+\s|[^()\s]+)\s*\)", buf)]
                nets = [n for n in nets if n and not n.startswith("1'b")]
                inst_nets[cur] = nets
                for n in nets:
                    net_insts[n].append(cur)
                cur, buf = None, ""
    return net_insts, inst_nets


# ---------------------------------------------------------------- attribution
def trace_module(net, net_insts, inst_nets, depth, max_hops, max_fanout, skip, ports):
    """nearest named net(s) through the cells: (module, hops, via) or None"""
    seen_n, seen_i = {net}, set()
    front = [net]
    for hop in range(1, max_hops + 1):
        found = collections.Counter()
        via = {}
        nxt = []
        for n in front:
            insts = net_insts.get(n, [])
            if n != net and len(insts) > max_fanout:
                continue
            for i in insts:
                if i in seen_i:
                    continue
                seen_i.add(i)
                mi = module_of(i, depth)
                if mi:
                    found[mi] += 1
                    via.setdefault(mi, i)
                for m in inst_nets.get(i, []):
                    if m in seen_n or m in skip:
                        continue
                    seen_n.add(m)
                    if not ANON.match(m):
                        mod = module_of(m, depth) or ("(I/O port)" if m in ports else "(top)")
                        found[mod] += 1
                        via.setdefault(mod, m)
                    else:
                        nxt.append(m)
        if found:
            top = found.most_common()
            mod = top[0][0]
            return mod, hop, via[mod], top
        front = nxt
    return None


def regions(macros):
    """floorplan regions from the placed macro groups (gen_core_files.py names)"""
    groups = collections.defaultdict(list)
    for name, master, x0, y0, x1, y1 in macros:
        if "u_row" in name:
            g = "rows"
        elif "u_accum_mem" in name:
            g = "B"
        elif "u_tile_mem" in name or "_tile_mem" in name or "u_input_buffer" in name:
            g = "A"
        else:
            g = "macro:" + master
        groups[g].append((name, master, x0, y0, x1, y1))
    box = {g: (min(m[2] for m in v), min(m[3] for m in v), max(m[4] for m in v), max(m[5] for m in v))
           for g, v in groups.items()}
    return groups, box


def region_of(x, y, macros, groups, box, depth):
    """(region label, module) of a point"""
    def dist(m):
        dx = max(m[2] - x, 0, x - m[4])
        dy = max(m[3] - y, 0, y - m[5])
        return (dx * dx + dy * dy) ** 0.5
    near = min(macros, key=dist) if macros else None
    d = dist(near) if near else 1e9
    lab = {"A": "region A (input buffer + feeder SRAM)", "B": "region B (accumulator SRAM)",
           "rows": "row macros"}
    if near and d <= 60.0:
        g = next(k for k, v in groups.items() if near in v)
        return f"{lab.get(g, g)}, {d:.0f} um from {near[0]}", module_of(near[0], depth) or "(top)"
    if "A" in box and "rows" in box and box["A"][2] <= x <= box["rows"][0]:
        return "FeatureSkew strip (between A and the rows)", None
    allm = (min(b[0] for b in box.values()), min(b[1] for b in box.values())) if box else (0, 0)
    if box and y < allm[1]:
        return "South output band", None
    if box and x < allm[0]:
        return "West pin band", None
    return (f"standard cells, {d:.0f} um from {near[0]}" if near else "standard cells"), \
        (module_of(near[0], depth) if near and d <= 200 else None)


# ---------------------------------------------------------------- output
COLORS = ["#1f77b4", "#ff7f0e", "#2ca02c", "#d62728", "#9467bd", "#8c564b", "#e377c2", "#7f7f7f",
          "#bcbd22", "#17becf", "#393b79", "#ad494a", "#637939", "#7b4173"]


def draw(path_base, die, macros, viols, mods):
    col = {m: COLORS[i % len(COLORS)] for i, m in enumerate(mods)}
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        from matplotlib.patches import Rectangle
        w, h = die[2] - die[0], die[3] - die[1]
        fig, ax = plt.subplots(figsize=(8, 8 * h / w if w else 8))
        ax.add_patch(Rectangle((die[0], die[1]), w, h, fill=False, lw=1))
        for _, _, x0, y0, x1, y1 in macros:
            ax.add_patch(Rectangle((x0, y0), x1 - x0, y1 - y0, fc="#dddddd", ec="#888888", lw=0.3))
        for m in mods:
            pts = [v for v in viols if v["module"] == m and v.get("xy")]
            ax.scatter([p["xy"][0] for p in pts], [p["xy"][1] for p in pts], s=10, c=col[m], label=m)
        ax.set_xlim(die[0], die[2])
        ax.set_ylim(die[1], die[3])
        ax.set_aspect("equal")
        ax.legend(fontsize=6, loc="upper right")
        fig.savefig(path_base + ".png", dpi=150, bbox_inches="tight")
        return path_base + ".png"
    except ImportError:
        pass
    w, h = die[2] - die[0], die[3] - die[1]
    sc = 900.0 / max(w, h)
    W, H = w * sc, h * sc
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W + 330:.0f}" height="{H + 20:.0f}" '
           f'font-family="sans-serif" font-size="11">',
           f'<rect x="10" y="10" width="{W:.1f}" height="{H:.1f}" fill="white" stroke="black"/>']

    def tx(x):
        return 10 + (x - die[0]) * sc

    def ty(y):
        return 10 + H - (y - die[1]) * sc
    for _, _, x0, y0, x1, y1 in macros:
        out.append(f'<rect x="{tx(x0):.1f}" y="{ty(y1):.1f}" width="{(x1 - x0) * sc:.1f}" '
                   f'height="{(y1 - y0) * sc:.1f}" fill="#dddddd" stroke="#888888" stroke-width="0.3"/>')
    for v in viols:
        if v.get("xy"):
            out.append(f'<circle cx="{tx(v["xy"][0]):.1f}" cy="{ty(v["xy"][1]):.1f}" r="2.5" '
                       f'fill="{col[v["module"]]}" fill-opacity="0.8"/>')
    for i, m in enumerate(mods):
        y = 24 + 16 * i
        out.append(f'<circle cx="{W + 30:.0f}" cy="{y - 4}" r="4" fill="{col[m]}"/>'
                   f'<text x="{W + 40:.0f}" y="{y}">{m}</text>')
    out.append("</svg>")
    open(path_base + ".svg", "w").write("\n".join(out))
    # no matplotlib: a PNG from the SVG if rsvg-convert is installed
    import shutil
    import subprocess
    if shutil.which("rsvg-convert") and subprocess.run(
            ["rsvg-convert", "-b", "white", "-o", path_base + ".png", path_base + ".svg"]).returncode == 0:
        return path_base + ".png"
    return path_base + ".svg"


def med(v):
    return statistics.median(v) if v else 0.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run")
    ap.add_argument("--name", help="name in the output files (default: the run tag)")
    ap.add_argument("--out-dir", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                                                      "openlane", "logs"))
    ap.add_argument("--depth", type=int, default=2, help="hierarchy levels kept in a module name")
    ap.add_argument("--tsv", help="also write one line per violating pin to this file")
    ap.add_argument("--max-hops", type=int, default=3)
    ap.add_argument("--max-fanout", type=int, default=32)
    a = ap.parse_args()
    run = os.path.abspath(a.run)
    name = a.name or os.path.basename(run.rstrip("/"))

    rpt, idx, viols = read_report(run)
    log, kinds, counts = read_arc_log(run, idx)
    defs = glob.glob(os.path.join(run, "results/final/def/*.def"))
    nls = glob.glob(os.path.join(run, "results/final/verilog/gl/*.nl.v"))
    lefs = glob.glob(os.path.join(run, "tmp/merged.nom.lef")) or glob.glob(os.path.join(run, "tmp/merged*.lef"))
    if not defs or not nls:
        sys.exit("final DEF / netlist missing")
    blocks = lef_blocks(lefs[:1])
    print(f"{len(viols)} violations in {rpt}; reading DEF ...", file=sys.stderr)
    want_nets = {v["net"] for v in viols}
    want_insts = {v["inst"] for v in viols}
    die, dbu, macros, pos, ios, nets = read_def(defs[0], blocks, want_nets, want_insts)
    macro_kind = {}
    for n, master, *_ in macros:
        macro_kind[n] = "row" if "u_row" in n or "Row" in master else \
            "SRAM" if "sram" in master.lower() else master
    groups, box = regions(macros)

    anon = [v for v in viols if ANON.match(v["net"]) and not module_of(v["net"], a.depth)]
    net_insts = inst_nets = None
    if anon:
        print(f"reading netlist for {len(anon)} anonymous nets ...", file=sys.stderr)
        net_insts, inst_nets = read_netlist(nls[0])
    # clock / power / reset-like nets are not followed
    skip = {n for n in (net_insts or {}) if n.startswith("clknet") or n in ("VPWR", "VGND", "vccd1", "vssd1")}

    for v in viols:
        d = nets.get(v["net"], {"conns": [], "length": collections.Counter()})
        v["length"] = sum(d["length"].values())
        v["layers_len"] = d["length"]
        touch = set()
        for i, p in d["conns"]:
            if i == "PIN" or i in ios and i not in pos:
                touch.add("I/O")
            elif i in macro_kind:
                touch.add(macro_kind[i])
        v["touch"] = ",".join(sorted(touch)) or "-"
        v["xy"] = pos.get(v["inst"])
        v["kind"] = kinds.get((v["net"], f'{v["inst"]}/{v["pin"]}', v["layer"]), "")
        mod = module_of(v["net"], a.depth)
        if mod:
            v["module"], v["how"] = mod, "name"
        elif not ANON.match(v["net"]):
            v["module"], v["how"] = ("(I/O port)" if v["net"] in ios else "(top)"), "name"
        else:
            t = trace_module(v["net"], net_insts, inst_nets, a.depth, a.max_hops, a.max_fanout, skip, ios)
            if t:
                v["module"], v["how"] = t[0], f"trace {t[1]} hop(s) via {t[2]}"
            else:
                lab, mod = region_of(v["xy"][0], v["xy"][1], macros, groups, box, a.depth) if v["xy"] \
                    else ("no position", None)
                v["module"], v["how"] = (mod or f"? ({lab})"), f"region: {lab}"
        v["region"] = region_of(v["xy"][0], v["xy"][1], macros, groups, box, a.depth)[0] if v["xy"] else "-"

    if a.tsv:
        with open(a.tsv, "w") as f:
            f.write("pin\tnet\tlayer\tratio\trequired\tpartial\twire_um\ttouch\tregion\tmodule\tx\ty\n")
            for v in viols:
                xy = v["xy"] or ("", "")
                f.write(f"{v['inst']}/{v['pin']}\t{v['net']}\t{v['layer']}\t{v['partial'] / v['required']:.3f}\t"
                        f"{v['required']:.1f}\t{v['partial']:.1f}\t{v['length']:.0f}\t{v['touch']}\t"
                        f"{v['region']}\t{v['module']}\t{xy[0]}\t{xy[1]}\n")

    # ---------------- report
    by = collections.defaultdict(list)
    for v in viols:
        by[v["module"]].append(v)
    mods = sorted(by, key=lambda m: -len(by[m]))
    os.makedirs(a.out_dir, exist_ok=True)
    base = os.path.join(a.out_dir, f"antenna_breakdown_{name}")
    pic = draw(base, die, macros, viols, mods)

    L = [f"# Vi phạm antenna của {name} theo module RTL", "",
         f"Run: `{os.path.basename(os.path.dirname(os.path.dirname(run)))}/runs/{os.path.basename(run)}`  ",
         f"Danh sách vi phạm: `{os.path.relpath(rpt, run)}` ({len(viols)} chân, {len(want_nets)} net)"
         + (f"; log check_antennas `{os.path.relpath(log, run)}`: {counts.get('pin', '?')} chân / "
            f"{counts.get('net', '?')} net" if log else ""), "",
         f"Die {die[2] - die[0]:.2f} x {die[3] - die[1]:.2f} um, {len(macros)} macro. "
         f"Hình: `{os.path.relpath(pic, os.path.join(a.out_dir, '..', '..'))}`", ""]
    hows = collections.Counter(v["how"].split()[0].rstrip(":") for v in viols)
    L += ["Cách gán module: " + ", ".join(f"{k} {n}" for k, n in hows.most_common())
          + " (name = tiền tố phân cấp trong tên net; trace = các net có tên gần nhất, dò qua cell của "
            f"netlist cuối, tối đa {a.max_hops} bước; region = vị trí cổng so với các vùng floorplan). "
            "Cột \"gán theo\" của bảng 20 net ghi cách gán từng vi phạm.", ""]

    L += ["## Theo module", "",
          "`(top)` = thanh ghi/net của chính module top; `(I/O port)` = dò về cổng vào/ra của design. "
          "ratio = Partial / Required (1,0 = đúng giới hạn).", "",
          "| module | số net | số chân | ratio trung vị | ratio max | lớp (số chân) | dây trung vị um | chạm |",
          "|---|---:|---:|---:|---:|---|---:|---|"]
    for m in mods:
        vs = by[m]
        r = [v["partial"] / v["required"] for v in vs]
        lay = collections.Counter(v["layer"] for v in vs)
        tch = collections.Counter(v["touch"] for v in vs)
        L.append(f"| `{m}` | {len({v['net'] for v in vs})} | {len(vs)} | {med(r):.2f} | {max(r):.2f} | "
                 + ", ".join(f"{k} {n}" for k, n in lay.most_common()) + f" | {med([v['length'] for v in vs]):.0f} | "
                 + ", ".join(f"{k} {n}" for k, n in tch.most_common(3)) + " |")
    L += ["", "Cột \"chạm\": net có nối vào chân macro (row, SRAM) hay chân I/O không (`-` = không).", ""]

    L += ["## 20 net tệ nhất", "",
          "| # | net | chân | module | ratio | Partial / Required | lớp | dây um | chạm | toạ độ cổng x, y um | gán theo |",
          "|---:|---|---|---|---:|---|---|---:|---|---|---|"]
    for k, v in enumerate(sorted(viols, key=lambda v: -v["partial"] / v["required"])[:20], 1):
        xy = f"{v['xy'][0]:.1f}, {v['xy'][1]:.1f}" if v["xy"] else "-"
        L.append(f"| {k} | `{v['net']}` | `{v['inst']}/{v['pin']}` | `{v['module']}` | "
                 f"{v['partial'] / v['required']:.2f} | {v['partial']:.0f} / {v['required']:.0f} | {v['layer']} | "
                 f"{v['length']:.0f} | {v['touch']} | {xy} | {v['how']} |")
    L.append("")

    # ---------------- where they gather (computed)
    n = len(viols) or 1
    L += ["## Lỗi dồn ở đâu", ""]
    tch = collections.Counter(v["touch"] for v in viols)
    L.append("- net theo chỗ nối: " + ", ".join(f"{k} {c}" for k, c in tch.most_common()))
    reg = collections.Counter(re.sub(r",.*", "", v["region"]) for v in viols)
    L.append("- cổng vi phạm theo vùng floorplan: " + ", ".join(f"{k} {c}" for k, c in reg.most_common()))
    lay = collections.Counter(v["layer"] for v in viols)
    L.append("- lớp vi phạm: " + ", ".join(f"{k} {c}" for k, c in lay.most_common()))
    r400 = sum(1 for v in viols if v["required"] <= 400.5)
    L.append(f"- Required 400 (đảo kim loại không có diode): {r400}; Required > 400 (có diode, dây quá dài): "
             f"{len(viols) - r400}")
    lens = sorted(v["length"] for v in viols)
    if lens:
        q = lambda f: lens[min(len(lens) - 1, int(f * len(lens)))]
        L.append(f"- chiều dài dây của net: trung vị {med(lens):.0f} um, 90 % dưới {q(0.9):.0f} um, "
                 f"max {lens[-1]:.0f} um")
    gate = collections.Counter("_N_ (logic)" if re.match(r"^_\d+_$", v["inst"]) else
                               re.sub(r"\d+$", "", v["inst"].split(".")[-1]) or v["inst"] for v in viols)
    L.append("- cổng vi phạm theo tên instance: " + ", ".join(f"{k} {c}" for k, c in gate.most_common(6)))
    buf = sum(c for k, c in gate.items() if k in ("hold", "wire", "fanout", "load_slew", "output", "input",
                                                  "rebuffer", "split"))
    top_mod = mods[0] if mods else "-"
    top_reg = reg.most_common(1)[0] if reg else ("-", 0)
    touch_m = sum(c for k, c in tch.items() if k != "-")
    L += ["", "Nhận xét (tính từ số liệu trên): "
          f"{r400}/{len(viols)} vi phạm ({100 * r400 / n:.0f} %) là đảo không có diode, "
          f"{100 * lay.most_common(1)[0][1] / n:.0f} % trên {lay.most_common(1)[0][0]}; "
          f"chỉ {touch_m} net chạm chân macro hoặc I/O, còn lại là net giữa các cell chuẩn; "
          f"{buf} chân ({100 * buf / n:.0f} %) là đầu vào buffer do resizer chèn (hold/wire/fanout/...). "
          f"Vùng nhiều nhất: {top_reg[0]} ({top_reg[1]}); module nhiều nhất: `{top_mod}` ({len(by[top_mod]) if mods else 0}).",
          ""]
    open(base + ".md", "w").write("\n".join(L))
    print(f"wrote {base}.md and {pic}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
