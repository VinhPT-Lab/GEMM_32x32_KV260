#!/usr/bin/env python3
"""
core_placement.py <layout.def> <merged.lef> [--cols 72]

Where the standard cells of gemm_core were placed: local utilisation of the
free (non-macro) area, as a map and per floorplan region, split into flops,
buffers/inverters and logic. A routing hot spot that sits on a dense
cluster of cells is a placement-density problem; one that sits on an empty
area is through-traffic.

Map characters: '#' macro, '.' free and empty, 0-9 = utilisation of the free
area in that character (1 = 10 %, 9 = 90 % or more).
"""
import collections
import re
import sys

SRAM = "sky130_sram_2kbyte_1rw1r_32x512_8"
ROW = "ProcessingElementRow"
SKIP = re.compile(r"(tapvpwrvgnd|decap|fill|diode)")


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
    if re.match(r"(s?df|edf|dl[xr]|dfb)", t):
        return "flop"
    if re.match(r"(buf|clkbuf|dlygate|clkdlybuf|dlymetal|inv|clkinv)", t):
        return "buffer"
    return "logic"


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    cols = int(sys.argv[sys.argv.index("--cols") + 1]) if "--cols" in sys.argv else 72
    if len(args) != 2:
        print(__doc__)
        return 2
    deff, lef = args
    size = lef_sizes(lef)
    dbu, die = 1000.0, None
    macros, cells = [], []
    in_comp = False
    with open(deff, errors="ignore") as f:
        for line in f:
            if line.startswith("UNITS DISTANCE MICRONS"):
                dbu = float(line.split()[3])
            elif line.startswith("DIEAREA"):
                n = list(map(float, re.findall(r"-?\d+", line)))
                die = (n[0] / dbu, n[1] / dbu, n[-2] / dbu, n[-1] / dbu)
            elif line.startswith("COMPONENTS "):
                in_comp = True
                continue
            elif line.startswith("END COMPONENTS"):
                break
            if not in_comp:
                continue
            m = re.match(r"\s*-\s+(\S+)\s+(\S+).*?\+\s+(?:PLACED|FIXED)\s+\(\s*(-?\d+)\s+(-?\d+)\s*\)\s*(\w+)", line)
            if not m:
                continue
            name, master, x, y, o = m.group(1), m.group(2), int(m.group(3)) / dbu, int(m.group(4)) / dbu, m.group(5)
            w, h = size.get(master, (0.0, 0.0))
            if master in (SRAM, ROW):
                macros.append((name, master, x, y, x + w, y + h))
            elif master.startswith("sky130_fd_sc") and not SKIP.search(master):
                cells.append((master, x + w / 2, y + h / 2, w * h))
    if not die or not cells:
        print(f"no die/cells read from {deff}")
        return 1
    W, H = die[2], die[3]
    nrows = max(1, round(cols * H / W / 2))
    cw, ch = W / cols, H / nrows
    area = collections.Counter(); kinds = collections.defaultdict(collections.Counter)
    for master, cx, cy, a in cells:
        b = (min(cols - 1, int(cx / cw)), min(nrows - 1, int(cy / ch)))
        area[b] += a
        kinds[b][kind(master)] += a
    blocked = collections.Counter()
    for name, master, x0, y0, x1, y1 in macros:
        for bx in range(max(0, int(x0 / cw)), min(cols, int(x1 / cw) + 1)):
            for by in range(max(0, int(y0 / ch)), min(nrows, int(y1 / ch) + 1)):
                ox = max(0.0, min(x1, (bx + 1) * cw) - max(x0, bx * cw))
                oy = max(0.0, min(y1, (by + 1) * ch) - max(y0, by * ch))
                blocked[(bx, by)] += ox * oy
    print(f"{len(cells)} standard cells (taps/decaps/fill left out), {sum(area.values()) / 1e6:.2f} mm2; "
          f"die {W:.0f} x {H:.0f} um, {len(macros)} macros")

    def util(b):
        free = cw * ch - blocked[b]
        return None if free < 0.1 * cw * ch else area[b] / free

    print(f"\nlocal utilisation of the free area ({cw:.0f} x {ch:.0f} um per character):")
    for by in range(nrows - 1, -1, -1):
        out = []
        for bx in range(cols):
            u = util((bx, by))
            out.append("#" if u is None else "." if area[(bx, by)] == 0 else str(min(9, int(u * 10))))
        print("  " + "".join(out))
    hot = sorted((b for b in area if util(b) is not None), key=lambda b: -util(b))[:8]
    print("\ndensest spots (x, y um: utilisation, flop/buffer/logic share):")
    for b in hot:
        k = kinds[b]; t = sum(k.values()) or 1
        print(f"  ({(b[0] + 0.5) * cw:6.0f}, {(b[1] + 0.5) * ch:6.0f}): {100 * util(b):4.0f}%   "
              f"flop {100 * k['flop'] / t:3.0f}%  buffer {100 * k['buffer'] / t:3.0f}%  logic {100 * k['logic'] / t:3.0f}%")
    # totals by kind and by part of the die
    tk = collections.Counter()
    for k in kinds.values():
        tk.update(k)
    t = sum(tk.values()) or 1
    print("\nall cells by kind (area):", ", ".join(f"{k} {100 * v / t:.0f}%" for k, v in tk.most_common()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
