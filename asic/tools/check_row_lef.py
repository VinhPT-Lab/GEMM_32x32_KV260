#!/usr/bin/env python3
"""
check_row_lef.py - sanity-check the abstract LEF of the row macro.

usage: check_row_lef.py <ProcessingElementRow.lef> [N] [DW] [RIW]

Checks that
  1. VDD and VSS exist as PINs (otherwise the parent cannot power the macro);
  2. every i_partial_sum_vector[b] sits at the same x as o_partial_sum_vector[b],
     and every o_weight_shift_out[b] at the same x as i_weight_shift_in[b]
     (that is what lets 32 rows stack with straight wires);
  3. psum-in / weight-out are on the top edge, psum-out / weight-in on the bottom.
"""
import re
import sys


def parse_pins(path):
    pins, cur, size = {}, None, None
    with open(path) as fh:
        for line in fh:
            t = line.split()
            if not t:
                continue
            if t[0] == "SIZE" and len(t) >= 4:
                size = (float(t[1]), float(t[3]))
            elif t[0] == "PIN" and len(t) >= 2:
                cur = t[1]
                pins[cur] = []
            elif t[0] == "END" and len(t) >= 2 and cur is not None and t[1] == cur:
                cur = None
            elif t[0] == "RECT" and cur is not None:
                nums = [float(x) for x in re.findall(r"-?\d+(?:\.\d+)?", line)]
                if len(nums) >= 4:
                    pins[cur].append(nums[-4:])
    return pins, size


def centre(rects):
    x1, y1, x2, y2 = rects[0]
    return (x1 + x2) / 2.0, (y1 + y2) / 2.0


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    path = sys.argv[1]
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 32
    dw = int(sys.argv[3]) if len(sys.argv) > 3 else 8
    riw = int(sys.argv[4]) if len(sys.argv) > 4 else 5
    psw = 2 * dw + riw
    pins, size = parse_pins(path)
    errors = 0

    # ORFS names the rails VDD/VSS, OpenLane (VDD_NETS/GND_NETS) vccd1/vssd1
    for kind, names in (("power", ("VDD", "vccd1")), ("ground", ("VSS", "vssd1"))):
        hit = [p for p in names if pins.get(p)]
        if hit:
            print(f"PASS {kind} pin {hit[0]} ({len(pins[hit[0]])} shapes)")
        else:
            print(f"FAIL {kind} pin ({' or '.join(names)}) missing from the LEF - the parent cannot power this macro")
            errors += 1

    h = size[1] if size else None
    pairs = [("i_partial_sum_vector", "o_partial_sum_vector", n * psw),
             ("o_weight_shift_out", "i_weight_shift_in", n * dw)]
    for top, bot, count in pairs:
        bad = 0
        for b in range(count):
            a, c = pins.get(f"{top}[{b}]"), pins.get(f"{bot}[{b}]")
            if not a or not c:
                bad += 1
                if bad <= 5:
                    print(f"FAIL {top}[{b}] or {bot}[{b}] not found in LEF")
                continue
            (xa, ya), (xc, yc) = centre(a), centre(c)
            if abs(xa - xc) > 0.005:
                bad += 1
                if bad <= 5:
                    print(f"FAIL {top}[{b}] x={xa} vs {bot}[{b}] x={xc}")
            if h is not None and not (ya > h / 2 > yc):
                bad += 1
                if bad <= 5:
                    print(f"FAIL {top}[{b}] should be on the top edge, {bot}[{b}] on the bottom")
        if bad == 0:
            print(f"PASS {count} bits of {top} / {bot} aligned top-bottom")
        errors += bad

    print("RESULT:", "PASS" if errors == 0 else f"FAIL ({errors} problems)")
    return 0 if errors == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
