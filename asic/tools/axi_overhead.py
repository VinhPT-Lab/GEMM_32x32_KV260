#!/usr/bin/env python3
"""
axi_overhead.py - what the AXI interface adds to the GEMM core.

usage: axi_overhead.py <core run> <shell run> [<shell run> ...] [--md out.md] [--lib <hd tt .lib>]
                       [--row <row run>]

core run  : the core_v11 run (designs/gemm_core/runs/core_v11)
shell runs: gemm_axi_shell runs, one per stream variant (run_flow.sh axi-shell:
            shell_thin, shell_reg, shell_lean, shell_lean_cg, ...)

Prints one table (markdown): cell count, flops, standard-cell area, timing
per corner, vectorless power, for the core and each shell variant, and the
shell as a percentage of the core. Every number is read from the run
directories; a value that is not there prints as "-" (never guessed).

Where the numbers come from
  cells, flops                : reports/synthesis/*.stat.rpt (Yosys), sky130_fd_sc_hd
                                cells of the top module only (rows/SRAM macros not counted)
  core std cells incl. rows    : the core's own cells + (row macros in the core) x the
                                std-cell area of one row (--row, the row_v1 run). The
                                core's top-level cells alone are a small part of the
                                logic: the PEs are inside the row macros.
  std-cell area               : those cell counts x the cell areas of the
                                sky130_fd_sc_hd tt liberty (--lib, or found under
                                $PDK_ROOT, ~/.ciel, ~/.volare), so macros never enter it
                                even if their .lib was given to synthesis
  layout area                 : last "Design area" OpenROAD printed before
                                filler insertion (shell: its placed cells)
  die                         : metrics.csv DIEAREA_mm^2
  timing                      : multi-corner signoff logs (*-rcx_mcsta.{max,min}.log):
                                worst slack per corner of the paths INSIDE the block
                                and, apart, of the paths that start or end at a port
                                (core_v11 waives its I/O paths: no pad ring yet)
  power                       : reports/power/vectorless.design.rpt (OpenSTA
                                default activity, tt/25C/1.80V, 100 MHz) and
                                reports/power/vcd_<c0>_<c1>.design.rpt (activity from the
                                original testbench, cycles c0..c1): tools/power.sh for the
                                core, tools/axi_shell_power.sh for the shells. A shell VCD
                                number is compared with the core's VCD number of the SAME
                                window only (2300..3200 = compute phase of job 2).
"""
import csv
import glob
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "openlane"))
try:
    from check_openlane_run import hold_slack, sta_paths  # noqa: E402
except Exception:                                          # pragma: no cover
    hold_slack = sta_paths = None


def metrics(run):
    p = os.path.join(run, "reports", "metrics.csv")
    if not os.path.exists(p):
        return {}
    return next(csv.DictReader(open(p)), {})


def num(x):
    try:
        v = float(x)
    except (TypeError, ValueError):
        return None
    return None if v == -1 else v


def synth_stat(run, top):
    """(cell count, flop count, {cell: count}) of the sky130_fd_sc_hd cells of module `top`"""
    fs = sorted(glob.glob(os.path.join(run, "reports", "synthesis", "*.stat.rpt")))
    if not fs or not top:
        return None, None, None
    text = open(fs[-1], errors="ignore").read()
    blk = None
    for b in re.split(r"\n(?====)", "\n" + text):
        m = re.match(r"=== (\S+) ===", b.strip())
        if m and m.group(1).lstrip("\\") == top:
            blk = b
    if blk is None:
        return None, None, None
    counts = {}
    for m in re.finditer(r"^\s+(sky130_fd_sc_hd__\w+)\s+(\d+)\s*$", blk, re.M):
        counts[m.group(1)] = counts.get(m.group(1), 0) + int(m.group(2))
    rows = re.search(r"^\s+\\?ProcessingElementRow\s+(\d+)\s*$", blk, re.M)
    counts["__rows__"] = int(rows.group(1)) if rows else 0
    if len(counts) == 1:
        return None, None, None
    # flip-flops and latches: df[xrsb]*, edf*, sdf*, dlx*, dlr* (not dlygate/dlymetal)
    flops = sum(n for c, n in counts.items()
                if re.match(r"sky130_fd_sc_hd__(e?df[xrsb]|sdf|dl[xr])", c))
    return sum(n for c, n in counts.items() if c != "__rows__"), flops, counts


def find_lib(arg):
    if arg:
        return arg
    for root in (os.environ.get("PDK_ROOT"), os.path.expanduser("~/.ciel"), os.path.expanduser("~/.volare")):
        if not root:
            continue
        direct = os.path.join(root, "sky130A", "libs.ref", "sky130_fd_sc_hd", "lib",
                              "sky130_fd_sc_hd__tt_025C_1v80.lib")
        if os.path.exists(direct):
            return direct
        hits = glob.glob(os.path.join(root, "**", "sky130A", "libs.ref", "sky130_fd_sc_hd", "lib",
                                      "sky130_fd_sc_hd__tt_025C_1v80.lib"), recursive=True)
        if hits:
            return hits[0]
    return None


def lib_areas(path):
    """{cell name: area um^2} from a liberty file"""
    if not path or not os.path.exists(path):
        return {}
    areas, cell = {}, None
    for line in open(path, errors="ignore"):
        m = re.match(r'\s*cell\s*\(\s*"?([\w]+)"?\s*\)', line)
        if m:
            cell = m.group(1)
            continue
        m = re.match(r"\s*area\s*:\s*([\d.]+)", line)
        if m and cell and cell not in areas:
            areas[cell] = float(m.group(1))
    return areas


def layout_area(run):
    """last 'Design area' before fill insertion"""
    logs = sorted(glob.glob(os.path.join(run, "logs", "*", "*.log")),
                  key=lambda f: (int(re.match(r"(\d+)", os.path.basename(f)).group(1))
                                 if re.match(r"\d+", os.path.basename(f)) else 0))
    val = None
    for f in logs:
        b = os.path.basename(f)
        if "fill" in b or "signoff" in f:
            break                      # fillers are in every later number
        for m in re.finditer(r"Design area ([\d.]+) u\^2", open(f, errors="ignore").read()):
            val = float(m.group(1))
    return val


def corner_slacks(run, kind):
    """{corner: (worst internal slack, worst port slack)} from the multi-corner
    signoff STA, worst over RC min/max. A port path starts at an input port or
    ends at an output port."""
    out = {}
    cmd = "report_checks -path_delay max" if kind == "setup" else "report_checks -path_delay min"
    for rc in ("min", "max"):
        logs = sorted(glob.glob(os.path.join(run, "logs", "signoff", f"*-rcx_mcsta.{rc}.log")))
        if not logs:
            continue
        text = open(logs[-1], errors="ignore").read()
        i = text.find(cmd)
        if i < 0:
            continue
        j = text.find("\nreport_checks", i + len(cmd))
        sec = text[i:j if j > 0 else len(text)]
        for part in sec.split("======================= ")[1:]:
            corner = part.split()[0]
            inner, port = out.get(corner, (None, None))
            for blk in re.split(r"\n(?=Startpoint: )", "\n" + part)[1:]:
                st = re.search(r"Startpoint: \S+ \(([^)]*)\)", blk)
                en = re.search(r"Endpoint: \S+ \(([^)]*)\)", blk)
                sl = re.search(r"(-?\d+\.\d+)\s+slack \((?:VIOLATED|MET)\)", blk)
                if not (st and en and sl):
                    continue
                v = float(sl.group(1))
                if "input port" in st.group(1) or "output port" in en.group(1):
                    port = v if port is None else min(port, v)
                else:
                    inner = v if inner is None else min(inner, v)
            out[corner] = (inner, port)
    return out


def power_total(run, name="vectorless"):
    p = os.path.join(run, "reports", "power", f"{name}.design.rpt")
    if not os.path.exists(p):
        return None
    for line in open(p, errors="ignore"):
        if line.startswith("Total"):
            f = line.split()
            try:
                return float(f[4])
            except (IndexError, ValueError):
                return None
    return None


def io_paths(run):
    """(violating paths touching a port, worst slack among them) in the signoff setup report"""
    if sta_paths is None:
        return None
    P = sta_paths(run, "max")
    if P is None:
        return None
    io = [p for p in P if p[1]]
    bad = [p for p in io if p[0] < 0]
    return len(bad), min((p[0] for p in io), default=None)


def collect(run, areas, row_area=None):
    m = metrics(run)
    cells, flops, counts = synth_stat(run, m.get("design_name"))
    area = None
    if counts and areas:
        missing = [c for c in counts if c != "__rows__" and c not in areas]
        if missing:
            print(f"note: {len(missing)} cell types of {run} not in the liberty (e.g. {missing[0]}); area left out")
        else:
            area = sum(n * areas[c] for c, n in counts.items() if c != "__rows__")
    area_all = area
    if area is not None and counts and counts.get("__rows__") and row_area:
        area_all = area + counts["__rows__"] * row_area
    return {
        "run": run, "name": os.path.basename(run.rstrip("/")),
        "cells": cells, "flops": flops, "area": area, "area_all": area_all,
        "rows": counts.get("__rows__", 0) if counts else 0,
        "layout": layout_area(run),
        "die": num(m.get("DIEAREA_mm^2")),
        "wns_tt": num(m.get("spef_wns")),
        "hold_tt": hold_slack(run) if hold_slack else None,
        "setup_c": corner_slacks(run, "setup"),
        "hold_c": corner_slacks(run, "hold"),
        "pwr": power_total(run),
        "pwr_vcd": {os.path.basename(f)[len("vcd_"):-len(".design.rpt")]:
                    power_total(run, os.path.basename(f)[:-len(".design.rpt")])
                    for f in sorted(glob.glob(os.path.join(run, "reports", "power", "vcd_*.design.rpt")))
                    if "_noclk" not in f},   # left over from a dropped experiment (shell_power.tcl)
        "io": io_paths(run),
    }


def fmt(v, spec):
    return "-" if v is None else format(v, spec)


def pct(a, b):
    return "-" if a is None or b in (None, 0) else f"{100.0 * a / b:.3f} %"


def main():
    args = sys.argv[1:]
    md = None
    if "--md" in args:
        k = args.index("--md")
        md = args[k + 1]
        del args[k:k + 2]
    lib = None
    if "--lib" in args:
        k = args.index("--lib")
        lib = args[k + 1]
        del args[k:k + 2]
    row_run = None
    if "--row" in args:
        k = args.index("--row")
        row_run = args[k + 1].rstrip("/")
        del args[k:k + 2]
    if len(args) < 2:
        print(__doc__)
        return 2
    lib = find_lib(lib)
    areas = lib_areas(lib)
    if not areas:
        print("note: sky130_fd_sc_hd tt liberty not found (give --lib): no std-cell area")
    row_area = rr = None
    if row_run:
        rr = collect(row_run, areas)
        row_area = rr["area"]
        if row_area is None:
            print(f"note: no std-cell area for the row run {row_run}")
    runs = [collect(a.rstrip("/"), areas, row_area) for a in args]
    core, shells = runs[0], runs[1:]
    # the core's cells and flops including the ones inside its row macros
    for k in ("cells", "flops"):
        core[k + "_all"] = (core[k] + core["rows"] * rr[k]
                            if rr and core[k] is not None and rr[k] is not None and core["rows"] else None)
    core["area_ref"] = core["area_all"] if core["rows"] and row_area else None

    rows = []

    def line(label, core_val, vals, spec, ref=None):
        """one table row: core value, then each shell value with its share of `ref`"""
        cells = [label, fmt(core_val, spec)]
        for v in vals:
            c = fmt(v, spec)
            if ref is not None and v is not None and c != "-":
                c += f" ({pct(v, ref)})"
            cells.append(c)
        rows.append(cells)

    def get(d, key):
        return d.get(key)

    line(f"standard cells, core incl. {core['rows']} row macros (synthesis)", core["cells_all"],
         [d["cells"] for d in shells], "d", core["cells_all"])
    line(f"flops, core incl. {core['rows']} row macros (synthesis)", core["flops_all"],
         [d["flops"] for d in shells], "d", core["flops_all"])
    line(f"std-cell area after synthesis (um^2), core incl. rows", core["area_ref"],
         [d["area"] for d in shells], ".0f", core["area_ref"])
    line("std-cell area after synthesis (um^2), core top level only", core["area"],
         [d["area"] for d in shells], ".0f")
    die_um2 = core["die"] * 1e6 if core["die"] else None
    line("placed area before fill (um^2), share of the core die", die_um2,
         [d["layout"] for d in shells], ".0f", die_um2)
    for kind, key in (("setup", "setup_c"), ("hold", "hold_c")):
        for corner in ("Slowest", "Typical", "Fastest"):
            line(f"{kind} worst slack inside the block, {corner} (ns)",
                 core[key].get(corner, (None, None))[0],
                 [d[key].get(corner, (None, None))[0] for d in shells], ".2f")
        for corner in ("Slowest", "Typical", "Fastest"):
            line(f"{kind} worst slack at a port, {corner} (ns)",
                 core[key].get(corner, (None, None))[1],
                 [d[key].get(corner, (None, None))[1] for d in shells], ".2f")
    rows.append(["violating setup paths at a port, Typical (signoff STA report)", "-"] +
                ["-" if d["io"] is None else str(d["io"][0]) for d in shells])
    line("power, vectorless tt 100 MHz (W)", core["pwr"], [d["pwr"] for d in shells], ".4g", core["pwr"])
    windows = sorted({w for d in runs for w in d["pwr_vcd"]})
    for w in windows:
        cw = core["pwr_vcd"].get(w)
        line(f"power from VCD, cycles {w.replace('_', '..')} (W)", cw,
             [d["pwr_vcd"].get(w) for d in shells], ".4g", cw)

    head = ["", f"core ({core['name']})"] + [d["name"] for d in shells]
    out = ["| " + " | ".join(head) + " |", "|" + "---|" * len(head)]
    out += ["| " + " | ".join(r) + " |" for r in rows]
    out += ["", "(x %) = the shell as a share of the core in that row. Slack rows: '-' = no such path",
            "listed (a block whose worst listed paths all touch a port has its internal paths at least as",
            "good). core_v11 has no pad ring and waives its port paths (README): its 'at a port' rows",
            "are not signoff numbers. A VCD row compares the same testbench window only.",
            "", f"core : {core['run']}"] + [f"shell: {d['run']}" for d in shells] + [
            f"row  : {row_run or '(not given: core area = top-level cells only)'}",
            f"cell areas: {lib or 'liberty not found'}"]
    text = "\n".join(out)
    print(text)
    if md:
        with open(md, "w") as f:
            f.write(text + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
