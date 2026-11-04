#!/usr/bin/env python3
"""macro_place_check.py <def> <merged lef> [--cfg macro.cfg] [--expect MASTER=N ...]
Hard macros (CLASS BLOCK in the LEF) as placed in a DEF: how many of each
master, whether any two overlap, and whether each sits where macro.cfg put it.
Exit 0 only if the counts match --expect, nothing overlaps and every macro.cfg
entry is found at its position (0.01 um)."""
import argparse
import re
import sys


def lef_blocks(path):
    out, cur, cls = {}, None, None
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


def def_macros(path, blocks):
    out, dbu, inside = [], 1000.0, False
    pend = ""
    for line in open(path, errors="ignore"):
        if line.startswith("UNITS DISTANCE MICRONS"):
            dbu = float(line.split()[3])
        elif line.startswith("COMPONENTS"):
            inside = True
        elif line.startswith("END COMPONENTS"):
            break
        elif inside:
            pend += " " + line.strip()
            if not pend.rstrip().endswith(";"):
                continue
            m = re.match(r"\s*-\s+(\S+)\s+(\S+).*?\+\s+(?:FIXED|PLACED)\s+\(\s*(-?\d+)\s+(-?\d+)\s*\)\s+(\S+)", pend)
            pend = ""
            if m and m.group(2) in blocks:
                w, h = blocks[m.group(2)]
                if m.group(5) in ("E", "W", "FE", "FW"):
                    w, h = h, w
                x, y = int(m.group(3)) / dbu, int(m.group(4)) / dbu
                out.append((m.group(1).replace("\\", ""), m.group(2), x, y, w, h))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("defp")
    ap.add_argument("lef")
    ap.add_argument("--cfg")
    ap.add_argument("--expect", nargs="*", default=[])
    a = ap.parse_args()
    blocks = lef_blocks(a.lef)
    ms = def_macros(a.defp, blocks)
    ok = True
    count = {}
    for _, master, *_ in ms:
        count[master] = count.get(master, 0) + 1
    print("hard macros: " + ", ".join(f"{m} {n}" for m, n in sorted(count.items())) + f" (total {len(ms)})")
    for e in a.expect:
        m, n = e.split("=")
        if count.get(m, 0) != int(n):
            print(f"  FAIL {m}: {count.get(m, 0)}, expected {n}")
            ok = False
    over = []
    srt = sorted(ms, key=lambda t: t[2])
    for i, (n1, _, x1, y1, w1, h1) in enumerate(srt):
        for n2, _, x2, y2, w2, h2 in srt[i + 1:]:
            if x2 >= x1 + w1 - 1e-6:
                break
            if y1 < y2 + h2 - 1e-6 and y2 < y1 + h1 - 1e-6:
                over.append((n1, n2))
    print(f"overlapping pairs: {len(over)}" + (f", e.g. {over[:3]}" if over else ""))
    ok &= not over
    if a.cfg:
        pos = {n: (x, y) for n, _, x, y, _, _ in ms}
        bad, n_cfg = [], 0
        for line in open(a.cfg):
            if line.startswith("#") or not line.strip():
                continue
            n, x, y, _ = line.split()
            n = n.replace("\\", "")
            n_cfg += 1
            p = pos.get(n)
            if p is None or abs(p[0] - float(x)) > 0.01 or abs(p[1] - float(y)) > 0.01:
                bad.append((n, p, (float(x), float(y))))
        print(f"macro.cfg: {n_cfg - len(bad)}/{n_cfg} macros at their position"
              + (f"; first off: {bad[0]}" if bad else ""))
        ok &= not bad
    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
