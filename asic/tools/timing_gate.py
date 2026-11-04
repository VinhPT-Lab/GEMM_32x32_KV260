#!/usr/bin/env python3
"""timing_gate.py <run dir> [--ref <reference run dir>] [--period <ns>]

Timing verdict of a finished run, from its signoff STA reports, by path kind:
every start / end point is a port, a standard cell ("cell") or a macro pin
("sram", "row", "axi", other macros by their cell name), read from the pin
lines of each path; "I/O" = a path through a port.
  period    the clock period of the run (create_clock in results/final/sdc)
            must be --period [env GEMM_GATE_PERIOD, default 10] -> else FAIL
  macros    the signoff STA must have read the macro libs (no macro black
            box in logs/signoff/*-rcx_sta.log, STA_MULTICORNER_READ_LIBS 1)
            -> else FAIL: paths to and from macro pins were not timed
  setup, Typical (reports/signoff/*-rcx_sta.max.rpt):
      internal paths, every kind      worst slack >= 0          -> else FAIL
      I/O paths                       worst slack >= 0, or not worse than the
                                      same paths of --ref       -> else FAIL
  hold, Typical (*-rcx_sta.min.rpt and the Typical corner of
      logs/signoff/*-rcx_mcsta.{min,max}.log): every kind >= 0  -> else FAIL
  hold, Slowest / Fastest (RC min and max): paths without a macro pin >= 0
      -> else FAIL. The SRAM, row and AXI macros have one (typical) lib each,
      so a path through a macro is only meaningful at Typical: printed, not judged.
  setup, Slowest / Fastest: printed, never judged (the clock of the slow corner
      is a separate decision).
  max slew / cap / fanout counts (*-rcx_sta.checks.rpt): printed next to --ref.
A report lists at most 1000 paths (OpenLane's report_checks -group_count 1000):
when a list is full and violating to its end, the per-kind counts are lower
bounds and a kind not listed may still violate (said in the output).
Exit 0 = PASS, 1 = FAIL, 2 = reports missing.
"""
import argparse
import glob
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sta_summary import blocks  # noqa: E402

MACRO_KIND = {"ProcessingElementRow": "row", "GemmAxiShell": "axi"}
FULL = 1000   # report_checks -group_count of OpenLane's STA scripts


def kind(name, desc, block):
    if "port" in desc:
        return "port"
    m = re.search(r"\s" + re.escape(name) + r"/\S+ \(([^)\s]+)\)", block)
    if not m:
        return "cell"           # a flop shown by its instance only
    t = m.group(1)
    if t.startswith(("sky130_fd_sc", "sky130_ef_sc")):
        return "cell"
    if t.startswith("sky130_sram"):
        return "sram"
    return MACRO_KIND.get(t, t)


def paths(text):
    """[(slack, kind 'a->b', I/O?, startpoint, endpoint)] of a report"""
    out = []
    for b in blocks(text):
        st = re.search(r"Startpoint: (\S+)\s+\(([^)]*)\)", b)
        en = re.search(r"Endpoint: (\S+)\s+\(([^)]*)\)", b)
        sl = re.search(r"(-?\d+\.\d+)\s+slack \((VIOLATED|MET)\)", b)
        if st and en and sl:
            ks, ke = kind(st.group(1), st.group(2), b), kind(en.group(1), en.group(2), b)
            out.append((float(sl.group(1)), f"{ks}->{ke}", "port" in (ks, ke), st.group(1), en.group(1)))
    return out


def has_macro(p):
    return any(k not in ("cell", "port") for k in p[1].split("->"))


def by_kind(ps):
    """{kind: (worst path, violating count)}"""
    d = {}
    for p in ps:
        w, n = d.get(p[1], (None, 0))
        d[p[1]] = (p if w is None or p[0] < w[0] else w, n + (p[0] < 0))
    return d


def last(run, pattern):
    f = sorted(glob.glob(os.path.join(run, pattern)))
    return f[-1] if f else None


def corners(log, cmd):
    """{corner name: report text} of one report_checks block of a multi-corner log"""
    text = open(log, errors="ignore").read()
    i = text.find(cmd)
    if i < 0:
        return {}
    j = text.find("\nreport_checks", i + len(cmd))
    sec = text[i:j if j > 0 else len(text)]
    return {c.split()[0]: c for c in sec.split("======================= ")[1:]}


def checks(run):
    f = last(run, "reports/signoff/*-rcx_sta.checks.rpt")
    if not f:
        return {}
    return {m.group(1): int(m.group(2)) for m in
            re.finditer(r"max (slew|fanout|cap) violation count (\d+)", open(f, errors="ignore").read())}


def fmt(w, n):
    return "no paths listed" if w is None else f"worst {w[0]:+.2f} ns ({n} violating), {w[3]} -> {w[4]}"


def full(ps):
    """the list is full and still violating at its end: more paths may violate"""
    return (" (list full: counts are lower bounds)"
            if len(ps) >= FULL and max(p[0] for p in ps) < 0 else "")


def period(run):
    f = last(run, "results/final/sdc/*.sdc")
    m = re.search(r"create_clock\b.*-period\s+([\d.]+)", open(f, errors="ignore").read()) if f else None
    return float(m.group(1)) if m else None


def macro_blackboxes(run):
    log = last(run, "logs/signoff/*-rcx_sta.log")
    if not log:
        return None
    bb = set(re.findall(r"module (\S+) not found\. Creating black box", open(log, errors="ignore").read()))
    return sorted(m for m in bb if not re.match(r"sky130_(fd|ef)_sc_\w+__(fill|decap|tapvpwrvgnd|diode)", m))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run")
    ap.add_argument("--ref", help="reference run (I/O waiver and max slew/cap counts)")
    ap.add_argument("--period", type=float, default=float(os.environ.get("GEMM_GATE_PERIOD", 10)),
                    help="clock period (ns) the run must be signed off at [GEMM_GATE_PERIOD or 10]")
    a = ap.parse_args()
    fails = []
    print(f"timing gate: {a.run}" + (f"  (reference {a.ref})" if a.ref else ""))

    smax = last(a.run, "reports/signoff/*-rcx_sta.max.rpt")
    smin = last(a.run, "reports/signoff/*-rcx_sta.min.rpt")
    if not smax or not smin:
        print("  MISSING  reports/signoff/*-rcx_sta.{max,min}.rpt")
        return 2

    T = period(a.run)
    ok = T is not None and abs(T - a.period) < 1e-6
    print(f"  {'PASS' if ok else 'FAIL'}     clock period {T} ns (gate: {a.period:g} ns)")
    if not ok:
        fails.append("clock period")
    bb = macro_blackboxes(a.run)
    if bb:
        print(f"  FAIL     macros not timed at signoff (black boxes: {', '.join(bb)}) - "
              "paths to and from their pins unchecked (STA_MULTICORNER_READ_LIBS 1)")
        fails.append("macros not timed")

    ps = paths(open(smax, errors="ignore").read())
    internal = [p for p in ps if not p[2]]
    for k, (w, n) in sorted(by_kind(internal).items()):
        ok = w[0] >= 0
        print(f"  {'PASS' if ok else 'FAIL'}     setup Typical, {k}: {fmt(w, n)}")
    bad = sorted(k for k, (w, n) in by_kind(internal).items() if w[0] < 0)
    if bad:
        fails.append("setup Typical " + ", ".join(bad))
    elif not internal:
        print("  PASS     setup Typical, internal: no paths listed")
    if full(ps):
        print(f"  note     setup Typical:{full(ps)}")

    io = [p for p in ps if p[2]]
    wo = min(io, key=lambda p: p[0]) if io else None
    no = sum(1 for p in io if p[0] < 0)
    ref_io = None
    if a.ref:
        r = last(a.ref, "reports/signoff/*-rcx_sta.max.rpt")
        if r:
            rio = [p for p in paths(open(r, errors="ignore").read()) if p[2]]
            ref_io = min(rio, key=lambda p: p[0]) if rio else None
    if wo is None or wo[0] >= 0:
        print(f"  PASS     setup Typical, I/O: {fmt(wo, no)}")
    elif ref_io is not None and wo[0] >= ref_io[0]:
        print(f"  PASS     setup Typical, I/O: {fmt(wo, no)} - not worse than the reference ({ref_io[0]:+.2f})")
    else:
        print(f"  FAIL     setup Typical, I/O: {fmt(wo, no)}"
              + (f" - reference {ref_io[0]:+.2f}" if ref_io is not None else ""))
        fails.append("setup Typical I/O")

    # hold: (name, paths, judge macro paths too)
    hold = [("Typical (rcx_sta)", paths(open(smin, errors="ignore").read()), True)]
    for rc in ("min", "max"):
        log = last(a.run, f"logs/signoff/*-rcx_mcsta.{rc}.log")
        if not log:
            print(f"  MISSING  logs/signoff/*-rcx_mcsta.{rc}.log")
            fails.append(f"hold RC {rc} missing")
            continue
        for c, t in corners(log, "report_checks -path_delay min").items():
            hold.append((f"{c}, RC {rc}", paths(t), c == "Typical"))
        for c, t in corners(log, "report_checks -path_delay max").items():
            if c != "Typical":
                w = paths(t)
                m = min(w, key=lambda p: p[0]) if w else None
                print(f"  info     setup {c}, RC {rc} (not judged): "
                      + ("no paths listed" if m is None else
                         f"worst {m[0]:+.2f} ns, {sum(1 for p in w if p[0] < 0)} violating listed"))
    for name, ps, all_kinds in hold:
        judged = ps if all_kinds else [p for p in ps if not has_macro(p)]
        kinds = by_kind(judged)
        bad = sorted(k for k, (w, n) in kinds.items() if w[0] < 0)
        m = min(judged, key=lambda p: p[0]) if judged else None
        scope = "every kind" if all_kinds else "paths without a macro pin"
        print(f"  {'FAIL' if bad else 'PASS'}     hold {name}, {scope}: "
              + ("no paths listed" if m is None else
                 f"worst {m[0]:+.2f} ns ({sum(1 for p in judged if p[0] < 0)} violating), {m[3]} -> {m[4]}")
              + (f" - failing kinds: {', '.join(bad)}" if bad else "") + full(ps))
        if bad:
            fails.append(f"hold {name}")
        if not all_kinds:
            mp = [p for p in ps if has_macro(p)]
            if mp:
                w = min(mp, key=lambda p: p[0])
                print(f"  info     hold {name}, through a macro pin (typical macro libs, not judged): "
                      f"worst {w[0]:+.2f} ns ({sum(1 for p in mp if p[0] < 0)} negative listed)")

    c, rc = checks(a.run), checks(a.ref) if a.ref else {}
    if c:
        print("  info     max slew / cap / fanout violations: "
              + ", ".join(f"{k} {c.get(k, '?')}" + (f" (ref {rc[k]})" if k in rc else "")
                          for k in ("slew", "cap", "fanout")))
    print(f"RESULT: {'FAIL (' + '; '.join(fails) + ')' if fails else 'PASS'}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
