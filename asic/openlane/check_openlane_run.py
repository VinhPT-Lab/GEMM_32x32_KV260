#!/usr/bin/env python3
"""
check_openlane_run.py - PASS/FAIL one OpenLane v1 run, plus how much RAM it took.

usage: check_openlane_run.py [--waive-io-timing] <designs/<name>/runs/<tag>>

--waive-io-timing (used for gemm_array): setup/hold are judged on the paths
  INSIDE the block only. Paths that start at an input port or end at an output
  port are listed but waived - with OpenLane's SDC the port sees an ideal clock
  while the flops sit behind a multi-ns clock tree, and in the chip these ports
  face Buffer_feeder / Out_buffer flops on the same tree anyway. A run that
  "failed" only because of those timing checks counts as complete if every
  signoff step ran.

Reads reports/metrics.csv (written at the end of every OpenLane run) and the
signoff STA summary for hold slack. A value of -1 in metrics.csv means that
step did not run; it is reported as MISSING, never as a pass.
"""
import csv
import glob
import os
import re
import sys

RULES = [
    # (column,                 test,                        essential)
    ("tritonRoute_violations", lambda v: v == 0,            True),
    ("Magic_violations",       lambda v: v == 0,            True),
    ("lvs_total_errors",       lambda v: v == 0,            True),
    ("pin_antenna_violations", lambda v: v == 0,            True),
    ("net_antenna_violations", lambda v: v == 0,            False),
    ("spef_wns",               lambda v: v >= 0,            True),   # signoff setup
    ("klayout_violations",     lambda v: v == 0,            False),
]
INFO = ["DIEAREA_mm^2", "synth_cell_count", "TotalCells", "DFF", "Final_Util",
        "spef_tns", "wire_length", "total_runtime", "routed_runtime"]


def hold_slack(run):
    files = sorted(glob.glob(os.path.join(run, "reports", "signoff", "*rcx_sta.summary.rpt")))
    if not files:
        return None
    text = open(files[-1], errors="ignore").read()
    m = re.search(r"report_worst_slack -min.*?worst slack\s+(-?[\d.]+)", text, re.S)
    return float(m.group(1)) if m else None


def sta_paths(run, kind):
    """(slack, touches_port, start, end) of every path in the signoff STA report.
    The .rpt files are only written at the very end of the flow; a run that
    stopped earlier still has the same paths in logs/signoff/*-rcx_sta.log
    (setup and hold together, told apart by "Path Type: max/min")."""
    fs = sorted(glob.glob(os.path.join(run, "reports", "signoff", f"*rcx_sta.{kind}.rpt")))
    from_log = not fs
    if from_log:
        fs = sorted(glob.glob(os.path.join(run, "logs", "signoff", "*-rcx_sta.log")), key=os.path.getmtime)
        if not fs:
            return None
    out = []
    for blk in re.split(r"\n(?=Startpoint: )", "\n" + open(fs[-1], errors="ignore").read())[1:]:
        if from_log and not re.search(rf"^Path Type: {kind}\b", blk, re.M):
            continue
        st = re.search(r"Startpoint: (\S+) \(([^)]*)\)", blk)
        en = re.search(r"Endpoint: (\S+) \(([^)]*)\)", blk)
        sl = re.search(r"(-?\d+\.\d+)\s+slack \((?:VIOLATED|MET)\)", blk)
        if st and en and sl:
            port = "input port" in st.group(2) or "output port" in en.group(2)
            out.append((float(sl.group(1)), port, st.group(1), en.group(1)))
    if from_log:
        print(f"  (no rcx_sta.{kind}.rpt - {kind} paths read from {os.path.relpath(fs[-1], run)})")
    return out


def internal_timing(run, kind, label):
    """worst slack of block-internal paths; None if it cannot be decided"""
    P = sta_paths(run, kind)
    if P is None:
        print(f"  MISSING  {label}: no signoff {kind} report")
        return None
    io = [p for p in P if p[1] and p[0] < 0]
    inner = [p for p in P if not p[1]]
    bad_inner = [p for p in inner if p[0] < 0]
    worst_io = min((p[0] for p in io), default=0.0)
    if io:
        print(f"  waived   {label}: {len(io)} I/O-boundary paths violate (worst {worst_io:.2f})")
    if len(P) >= 1000 and all(p[0] < 0 for p in P):
        print(f"  FAIL     {label}: all 1000 listed paths violate - cannot see the internal ones")
        return -1.0
    if bad_inner:
        w = min(p[0] for p in bad_inner)
        print(f"  FAIL     {label} (internal) worst {w:.2f}: {bad_inner[0][2]} -> {bad_inner[0][3]}")
        return w
    w = min((p[0] for p in inner), default=None)
    print(f"  PASS     {label} (internal) worst listed {w if w is not None else 'n/a'}"
          f"  - no internal path violates")
    return 0.0 if w is None else w


def main():
    args = sys.argv[1:]
    waive = "--waive-io-timing" in args
    args = [a for a in args if a != "--waive-io-timing"]
    if len(args) != 1:
        print(__doc__)
        return 2
    run = args[0].rstrip("/")
    path = os.path.join(run, "reports", "metrics.csv")
    if not os.path.exists(path):
        print(f"no {path} - the run stopped before the end; read the last log in {run}/logs/")
        return 1
    row = next(csv.DictReader(open(path)))

    ok = True
    print(f"--- {row.get('design_name', '?')}   ({run})")
    print(f"  flow_status          = {row.get('flow_status')}")
    if "completed" not in str(row.get("flow_status", "")).lower():
        gds = glob.glob(os.path.join(run, "results", "final", "gds", "*.gds"))
        signoff_ran = all(str(row.get(c, "-1")) not in ("-1", "", "None")
                          for c in ("Magic_violations", "lvs_total_errors", "pin_antenna_violations"))
        if waive and gds and signoff_ran:
            print("           (flow stopped only at the final timing gate: GDS written, signoff ran)")
        else:
            ok = False
    mem = row.get("Peak_Memory_Usage_MB")
    print(f"  Peak_Memory_Usage_MB = {mem}   <- the number to watch on a 16 GB machine")

    for col, test, essential in RULES:
        if waive and col == "spef_wns":
            continue
        raw = row.get(col)
        try:
            v = float(raw)
        except (TypeError, ValueError):
            v = None
        if v is None or v == -1:
            print(f"  {'MISSING' if essential else 'missing':8s} {col}")
            ok &= not essential
            continue
        good = test(v)
        ok &= good
        print(f"  {'PASS' if good else 'FAIL':8s} {col} = {raw}")

    if waive:
        for kind, label in (("max", "setup"), ("min", "hold")):
            w = internal_timing(run, kind, label)
            ok &= w is not None and w >= 0
        h = "waived"
    else:
        h = hold_slack(run)
    if h == "waived":
        pass
    elif h is None:
        print("  MISSING  hold slack (signoff rcx_sta summary not found)")
        ok = False
    else:
        print(f"  {'PASS' if h >= 0 else 'FAIL':8s} hold worst slack = {h}")
        ok &= h >= 0

    print("--- info")
    for col in INFO:
        if col in row:
            print(f"           {col} = {row[col]}")
    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
