#!/usr/bin/env python3
"""
macro_antenna_lef.py --in <macro.lef> --lib-lef <sky130_fd_sc_hd.lef> --out <macro_antenna.lef>

The OpenRAM LEF (sky130_sram_2kbyte_1rw1r_32x512_8) has no antenna data, so the
antenna checker (ARC), repair_antennas and the antenna ECO cannot see the
gates behind its input pins. From core_v8 the heuristic diodes, which used to
cover them blindly, are off (they were the main source of global-route
congestion). This writes a copy of the LEF with, in every signal pin,
  DIRECTION INPUT  -> ANTENNAGATEAREA <G> ;
  DIRECTION OUTPUT -> ANTENNADIFFAREA <D> ;
where G is the smallest ANTENNAGATEAREA of any input pin and D the smallest
ANTENNADIFFAREA of any output pin of the standard-cell library: the smallest
gate gives the highest antenna ratio for a given wire, and the smallest
driver diffusion protects least - both conservative assumptions about what
sits behind the macro pin. Pins with USE POWER/GROUND, INOUT pins and pins
that already carry antenna data are left as they are. Macro names unchanged.
Run by run_flow.sh core_install; the result is listed in EXTRA_LEFS.
"""
import argparse
import re
import sys


def lib_minima(path):
    g, d = [], []
    dirn = use = None
    for line in open(path, errors="ignore"):
        s = line.strip()
        if s.startswith("PIN "):
            dirn = use = None
        m = re.match(r"DIRECTION\s+(\S+)", s)
        if m:
            dirn = m.group(1)
        m = re.match(r"USE\s+(\S+)", s)
        if m:
            use = m.group(1)
        if use in ("POWER", "GROUND"):
            continue
        m = re.match(r"ANTENNAGATEAREA\s+([\d.]+)", s)
        if m and dirn == "INPUT":
            g.append(float(m.group(1)))
        m = re.match(r"ANTENNADIFFAREA\s+([\d.]+)", s)
        if m and dirn == "OUTPUT":
            d.append(float(m.group(1)))
    if not g or not d:
        raise SystemExit(f"macro_antenna_lef: no antenna data in {path}")
    return min(g), min(d), len(g), len(d)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--in", dest="inp", required=True)
    ap.add_argument("--lib-lef", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    G, D, ng, nd = lib_minima(a.lib_lef)

    lines = open(a.inp, errors="ignore").read().split("\n")
    # pass 1: per PIN block, its direction / use / existing antenna data
    pins, cur = {}, None
    for i, line in enumerate(lines):
        s = line.strip()
        m = re.match(r"PIN\s+(\S+)", s)
        if m:
            cur = i
            pins[cur] = {"name": m.group(1), "dir": None, "use": None, "ant": False, "dir_line": None}
            continue
        if cur is None:
            continue
        if re.match(r"END\s+" + re.escape(pins[cur]["name"]) + r"\s*$", s):
            cur = None
            continue
        m = re.match(r"DIRECTION\s+(\S+)", s)
        if m:
            pins[cur]["dir"], pins[cur]["dir_line"] = m.group(1), i
        m = re.match(r"USE\s+(\S+)", s)
        if m:
            pins[cur]["use"] = m.group(1)
        if s.startswith("ANTENNA"):
            pins[cur]["ant"] = True
    # pass 2: insert after the DIRECTION line
    add = {}
    n_in = n_out = 0
    for p in pins.values():
        if p["use"] in ("POWER", "GROUND") or p["ant"] or p["dir_line"] is None:
            continue
        indent = re.match(r"\s*", lines[p["dir_line"]]).group(0)
        if p["dir"] == "INPUT":
            add[p["dir_line"]] = f"{indent}ANTENNAGATEAREA {G:g} ;"
            n_in += 1
        elif p["dir"] == "OUTPUT":
            add[p["dir_line"]] = f"{indent}ANTENNADIFFAREA {D:g} ;"
            n_out += 1
    out = [f"# written by macro_antenna_lef.py from {a.inp}",
           f"# antenna data added (none in the original): ANTENNAGATEAREA {G:g} on {n_in} input pins,",
           f"# ANTENNADIFFAREA {D:g} on {n_out} output pins. G / D = smallest input-pin gate area /",
           f"# output-pin diffusion area of {a.lib_lef} ({ng} / {nd} pins) - conservative",
           "# assumptions about the gates and drivers behind the macro pins."]
    for i, line in enumerate(lines):
        out.append(line)
        if i in add:
            out.append(add[i])
    open(a.out, "w").write("\n".join(out))
    print(f"  macro_antenna_lef: {a.out.split('/')[-1]}: ANTENNAGATEAREA {G:g} on {n_in} input pins, "
          f"ANTENNADIFFAREA {D:g} on {n_out} output pins")
    return 0


if __name__ == "__main__":
    sys.exit(main())
