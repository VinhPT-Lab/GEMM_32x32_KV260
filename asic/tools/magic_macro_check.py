#!/usr/bin/env python3
"""
magic_macro_check.py prep|report ... - helper of tools/magic_macro_check.sh.

  prep   <drc.rpt> <final.def> <merged.lef> <workdir> [skip ...]
         picks the Magic DRC markers within 2 um of a macro bbox (macros =
         CLASS BLOCK masters of the LEF, placed and oriented from COMPONENTS),
         groups them into 10x10 um windows and writes workdir/windows.json
         (for the KLayout clip) and workdir/windows.tcl (for Magic).
  report <workdir> <magic.log> <out.rpt>
         counts, per marker, the Magic errors of the full layout within
         +-0.5 um of it, and writes the summary.
"""
import collections
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import def_window as dw  # noqa: E402

NEAR = 2.0      # um around a macro bbox
INSIDE = 5.0    # markers deeper than this inside a macro are never waived
# rules that mean routing ON the macro abstract (wire over an OBS), never waived
NEVER = ("Can't overlap those layers",)
WIN = 10.0      # clip window
MARGIN = 1.0    # a marker must sit this far inside its window
TOL = 0.5       # Magic errors counted within this distance of a marker
EDGE = 0.3      # Magic errors this close to the clip edge are clip artefacts


def drc_markers(path):
    """[(rule, (x0, y0, x1, y1))] from a Magic drc.rpt, in file order"""
    lines = open(path, errors="ignore").read().splitlines()
    out, rule = [], None
    for i, line in enumerate(lines):
        m = re.match(r"^\s*(-?[\d.]+)um (-?[\d.]+)um (-?[\d.]+)um (-?[\d.]+)um", line)
        if m:
            out.append((rule, tuple(float(v) for v in m.groups())))
        elif line and not line.startswith("---") and i + 1 < len(lines) and lines[i + 1].startswith("---"):
            rule = line.strip()
    return out


def rule_tag(rule):
    m = re.search(r"\(([^()]+)\)\s*$", rule or "")
    return m.group(1) if m else (rule or "?")


def block_masters(lef):
    blocks, cur = set(), None
    for line in open(lef, errors="ignore"):
        m = re.match(r"\s*MACRO\s+(\S+)", line)
        if m:
            cur = m.group(1)
        elif cur and re.match(r"\s*CLASS\s+BLOCK\b", line):
            blocks.add(cur)
    return blocks


def macro_boxes(deff, lef):
    sizes = dw.lef_macros(lef)
    blocks = block_masters(lef)
    out, dbu, sect = [], 1000.0, False
    with open(deff, errors="ignore") as f:
        for line in f:
            if line.startswith("UNITS DISTANCE MICRONS"):
                dbu = float(line.split()[3])
            elif line.startswith("COMPONENTS "):
                sect = True
            elif line.startswith("END COMPONENTS"):
                break
            elif sect:
                m = re.match(r"\s*-\s+(\S+)\s+(\S+).*?\+\s+(?:PLACED|FIXED)\s+\(\s*(-?\d+)\s+(-?\d+)\s*\)\s+(\S+)", line)
                if m and m.group(2) in blocks:
                    w, h = sizes[m.group(2)]["size"]
                    loc = (int(m.group(3)) / dbu, int(m.group(4)) / dbu)
                    out.append((m.group(1).replace("\\", ""), m.group(2), dw.place((0, 0, w, h), loc, m.group(5), (w, h))))
    return out


def gap(a, b):
    dx = max(0.0, max(a[0], b[0]) - min(a[2], b[2]))
    dy = max(0.0, max(a[1], b[1]) - min(a[3], b[3]))
    return max(dx, dy)


def depth(a, mb):
    """how far box a lies inside macro bbox mb (0 if not inside it)"""
    if a[0] < mb[0] or a[1] < mb[1] or a[2] > mb[2] or a[3] > mb[3]:
        return 0.0
    return min(a[0] - mb[0], a[1] - mb[1], mb[2] - a[2], mb[3] - a[3])


def prep(rpt, deff, lef, work, skip):
    os.makedirs(work, exist_ok=True)
    marks = drc_markers(rpt)
    macros = macro_boxes(deff, lef)
    rows = []
    for i, (rule, box) in enumerate(marks):
        tag = rule_tag(rule)
        if tag in skip:
            rows.append({"id": i, "rule": rule, "tag": tag, "box": box, "class": "skipped"})
            continue
        near = min(((gap(box, mb), name, master) for name, master, mb in macros), default=None)
        # deeper than INSIDE inside a macro, or a NEVER rule: routing over the macro itself (core_v7r:
        # net3191 on met2 across an SRAM, "Can't overlap those layers"). The full
        # layout cannot clear it - a wire merged into the macro metal is no DRC
        # error there, and the OpenRAM bitcells break generic rules on their own -
        # so it is never waived
        inside = max((depth(box, mb) for _, _, mb in macros), default=0.0)
        if near and (inside > INSIDE or tag in NEVER):
            rows.append({"id": i, "rule": rule, "tag": tag, "box": box, "class": "inside",
                         "macro": near[1], "master": near[2], "depth": inside})
        elif near and near[0] <= NEAR:
            rows.append({"id": i, "rule": rule, "tag": tag, "box": box, "class": "macro",
                         "macro": near[1], "master": near[2], "gap": near[0]})
        else:
            rows.append({"id": i, "rule": rule, "tag": tag, "box": box, "class": "not-macro"})
    # windows: greedy, each one around the first unplaced marker, taking every
    # other marker that fits with MARGIN to spare; a marker larger than the
    # window gets a window of its own sized to it
    todo = sorted((r for r in rows if r["class"] == "macro"), key=lambda r: (r["box"][0], r["box"][1]))
    wins = []
    for r in todo:
        if "win" in r:
            continue
        b = r["box"]
        cx, cy = (b[0] + b[2]) / 2, (b[1] + b[3]) / 2
        hw = max(WIN / 2, (b[2] - b[0]) / 2 + MARGIN + TOL, (b[3] - b[1]) / 2 + MARGIN + TOL)
        hh = max(WIN / 2, (b[3] - b[1]) / 2 + MARGIN + TOL, (b[2] - b[0]) / 2 + MARGIN + TOL)
        w = (cx - hw, cy - hh, cx + hw, cy + hh)
        n = len(wins)
        for o in todo:
            ob = o["box"]
            if "win" not in o and ob[0] >= w[0] + MARGIN and ob[1] >= w[1] + MARGIN \
                    and ob[2] <= w[2] - MARGIN and ob[3] <= w[3] - MARGIN:
                o["win"] = n
        wins.append({"n": n, "box": w})
    json.dump({"windows": wins, "markers": rows}, open(os.path.join(work, "windows.json"), "w"), indent=1)
    with open(os.path.join(work, "windows.tcl"), "w") as f:
        f.write("set gemm_windows {\n")
        for w in wins:
            f.write("  %d {%.3f %.3f %.3f %.3f}\n" % ((w["n"],) + tuple(w["box"])))
        f.write("}\n")
    print(f"  {len(marks)} markers, {sum(r['class'] == 'macro' for r in rows)} within {NEAR:g} um of a macro, "
          f"{len(wins)} clip windows, {len(macros)} macros")
    return 0


def report(work, mlog, out):
    data = json.load(open(os.path.join(work, "windows.json")))
    wins = {w["n"]: w["box"] for w in data["windows"]}
    errs = collections.defaultdict(list)
    for line in open(mlog, errors="ignore"):
        m = re.match(r"^GEMM_ERR (\d+) \{(.*)\} (-?[\d.]+) (-?[\d.]+) (-?[\d.]+) (-?[\d.]+)\s*$", line)
        if m:
            errs[int(m.group(1))].append((m.group(2), tuple(float(m.group(i)) for i in range(3, 7))))
    done = {int(m.group(1)) for m in re.finditer(r"^GEMM_DONE (\d+)", open(mlog, errors="ignore").read(), re.M)}
    rows = data["markers"]
    L = []
    per_rule = collections.Counter(r["tag"] for r in rows)
    L.append("magic_macro_check: Magic DRC markers next to macros, rechecked on the full layout (GDS)")
    L.append("")
    L.append("markers per rule (drc.rpt):")
    for t, c in per_rule.most_common():
        sk = "  [skipped]" if any(r["tag"] == t and r["class"] == "skipped" for r in rows) else ""
        L.append(f"  {c:7d}  {t}{sk}")
    mac = [r for r in rows if r["class"] == "macro"]
    real, unchecked = [], []
    for r in mac:
        n = r.get("win")
        if n is None or n not in done:
            unchecked.append(r)
            continue
        b, wb = r["box"], wins[n]
        hit = []
        for why, e in errs[n]:
            if e[0] <= wb[0] + EDGE or e[1] <= wb[1] + EDGE or e[2] >= wb[2] - EDGE or e[3] >= wb[3] - EDGE:
                continue  # touches the clip edge
            if e[2] >= b[0] - TOL and e[0] <= b[2] + TOL and e[3] >= b[1] - TOL and e[1] <= b[3] + TOL:
                hit.append((why, e))
        if hit:
            real.append((r, hit))
    nm = [r for r in rows if r["class"] == "not-macro"]
    L.append("")
    L.append(f"markers within {NEAR:g} um of a macro: {len(mac)} (by rule: "
             + ", ".join(f"{t} {c}" for t, c in collections.Counter(r['tag'] for r in mac).most_common()) + ")")
    L.append(f"  still an error on the full layout: {len(real)}")
    for r, hit in real:
        b = r["box"]
        L.append(f"    {r['tag']:10s} ({b[0]:.3f},{b[1]:.3f})-({b[2]:.3f},{b[3]:.3f})  {r['macro']} ({r['master']})")
        for why, e in hit[:5]:
            L.append(f"        full layout: {why}  ({e[0]:.3f},{e[1]:.3f})-({e[2]:.3f},{e[3]:.3f})")
        if len(hit) > 5:
            L.append(f"        ... {len(hit) - 5} more")
    L.append(f"  not checked (no window / Magic did not finish the window): {len(unchecked)}")
    for r in unchecked:
        b = r["box"]
        L.append(f"    {r['tag']:10s} ({b[0]:.3f},{b[1]:.3f})-({b[2]:.3f},{b[3]:.3f})  {r['macro']}")
    L.append(f"markers NOT next to a macro (not waived): {len(nm)}")
    for r in nm:
        b = r["box"]
        L.append(f"    {r['tag']:10s} ({b[0]:.3f},{b[1]:.3f})-({b[2]:.3f},{b[3]:.3f})")
    ins = [r for r in rows if r["class"] == "inside"]
    L.append(f"markers of routing over a macro ({', '.join(NEVER)}, or deeper than {INSIDE:g} um inside; "
             f"not waived): {len(ins)}")
    for r in ins:
        b = r["box"]
        L.append(f"    {r['tag']:10s} ({b[0]:.3f},{b[1]:.3f})-({b[2]:.3f},{b[3]:.3f})  depth {r['depth']:.1f} um  {r['macro']}")
    ok = not real and not unchecked and not nm and not ins
    L.append("")
    L.append("RESULT: " + ("PASS - every non-skipped marker is a macro-abstract artefact" if ok else "FAIL"))
    text = "\n".join(L) + "\n"
    open(out, "w").write(text)
    print(text, end="")
    return 0 if ok else 1


def main():
    a = sys.argv[1:]
    if len(a) >= 5 and a[0] == "prep":
        return prep(a[1], a[2], a[3], a[4], set(a[5:]))
    if len(a) == 4 and a[0] == "report":
        return report(a[1], a[2], a[3])
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
