#!/usr/bin/env python3
"""
core_triage.py <run dir> - where and how an OpenLane v1 run of gemm_core died.

Reads only the run directory (no OpenLane needed):
  * openlane.log: the "[ERROR]: Step N (...) failed" line and how the child
    process ended (SIGABRT / SIGKILL / exit code)
  * the newest log under logs/ (the step that was running), its last lines
  * inside a routing log: how far global routing got
      GRT-0053  routing resources printed       (grid built)
      GRT-0101  extra iterations for overflow   (the design is congested)
      GRT-0103  "hard benchmark" extra run      (>= 20 congestion iterations)
      GRT-0111/0096/0018  global routing finished
      RSZ-...   repair_design ran after it
      DPL-...   detailed placement ran after it
  * crash signatures (glibc heap/stack checks, uncaught C++ exception,
    assertion, out of memory)
  * disk full ("No space left on device", ODB-0172 cannot open a file for
    writing) in openlane.log or the newest step logs: signal=disk

Last line is machine-readable for run_flow.sh:
  TRIAGE stage=<grt-initial|grt-overflow|grt-congestion|rsz|dpl|after-dpl|finished|other|none> signal=<...>
"""
import glob
import os
import re
import sys

SIGS = [
    ("stack-smashing", r"stack smashing detected"),
    ("heap-corruption", r"corrupted|double free|free\(\): invalid|malloc\(\)|munmap_chunk|realloc\(\): invalid"),
    ("uncaught-exception", r"terminate called after throwing|what\(\):"),
    ("fastroute-route-buffer", r"updateRouteType1|updateRouteType2"),
    ("assertion", r"Assertion .* failed"),
    ("out-of-memory", r"out of memory|std::bad_alloc|Cannot allocate memory"),
    ("segfault", r"Segmentation fault|SIGSEGV|Signal 11 received"),
    ("abort", r"Signal 6 received"),
    ("grt-guides-reload", r"loadGuidesFromDB|GlobalRouter::haveRoutes|GlobalRouter::readGuides"),
    ("grt-congestion", r"GRT-011[89]"),
    ("dpl-failed", r"DPL-0036|Detailed placement failed"),
    ("tcl-error", r"^Error: "),
]


def tail(path, n):
    with open(path, errors="ignore") as f:
        return f.read().splitlines()[-n:]


def block_after(lines, marker, n, stop=None, times=1):
    """lines from the first one containing marker: at most n, or up to the
    times-th line matching stop"""
    for i, l in enumerate(lines):
        if marker in l:
            out, seen = [], 0
            for k in lines[i:i + n]:
                out.append(k)
                if stop and re.match(stop, k):
                    seen += 1
                    if seen == times:
                        break
            return out
    return []


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    run = sys.argv[1].rstrip("/")
    if not os.path.isdir(run):
        print(f"no run directory {run}")
        print("TRIAGE stage=none signal=none")
        return 0

    signal = "none"
    complete = os.path.exists(os.path.join(run, "reports", "metrics.csv"))
    ol = os.path.join(run, "openlane.log")
    if os.path.exists(ol):
        txt = open(ol, errors="ignore").read()
        steps = re.findall(r"\[ERROR\]: Step (\d+) \(([^)]*)\) failed", txt)
        m = re.search(r"child killed: (\w+)", txt)
        if m:
            signal = m.group(1)
        elif "child process exited abnormally" in txt:
            signal = "exit"
        if steps:
            print(f"openlane.log : step {steps[-1][0]} ({steps[-1][1]}) failed, child: {signal}")
        elif "Flow complete" in txt:
            print("openlane.log : flow complete")
            complete = True
        else:
            print("openlane.log : no failed step recorded (still running, or killed from outside?)")
    else:
        print("openlane.log : not found")

    logs = [p for p in glob.glob(os.path.join(run, "logs", "**", "*.log"), recursive=True)
            if os.path.getsize(p) > 0]
    # disk full (core_v7r: tmp/routing/22-fill.def could not be written, ODB-0172):
    # looked for in openlane.log and the newest step logs only
    newest = sorted(logs, key=os.path.getmtime)[-5:]
    for p in ([ol] if os.path.exists(ol) else []) + newest:
        with open(p, errors="ignore") as f:
            hit = next((ln.strip() for ln in f if "No space left on device" in ln or "ODB-0172" in ln), None)
        if hit:
            signal = "disk"
            print(f"disk full    : {os.path.relpath(p, run)}: {hit[:150]}")
            break
    if not logs:
        print("no step logs")
        print(f"TRIAGE stage=none signal={signal}")
        return 0
    last = max(logs, key=os.path.getmtime)
    lines = open(last, errors="ignore").read().splitlines()
    rel = os.path.relpath(last, run)
    print(f"last log     : {rel}  ({len(lines)} lines, {os.path.getsize(last) / 1e6:.1f} MB)")

    text = "\n".join(lines)
    has = {k: (k in text) for k in ("GRT-0053", "GRT-0101", "GRT-0103", "GRT-0111", "GRT-0096", "GRT-0018")}
    grt_started = has["GRT-0053"] or "-congestion_iterations" in text
    grt_done = has["GRT-0111"] or has["GRT-0096"] or has["GRT-0018"]
    # what ran after global routing finished
    after = text.split("GRT-0018")[-1] if has["GRT-0018"] else (text.split("GRT-0096")[-1] if has["GRT-0096"] else "")
    rsz = bool(re.search(r"RSZ-\d+", after))
    dpl = bool(re.search(r"DPL-\d+|Placement Analysis", after))
    area = "area_report" in after or "Design area" in after

    if not grt_started:
        stage = "other"
    elif re.search(r"GRT-011[89]", text):
        stage = "grt-congestion"     # finished its iterations, overflow left -> error
    elif not grt_done:
        stage = "grt-overflow" if has["GRT-0101"] else "grt-initial"
    elif area:
        stage = "after-dpl"
    elif dpl:
        stage = "dpl"
    elif rsz:
        stage = "rsz"
    else:
        stage = "rsz"      # GRT finished, nothing logged yet: estimate_parasitics / repair_design
    if "GEMM_PROBE_DONE" in text or "Flow complete" in text or complete:
        stage = "finished"

    marks = " ".join(f"{k}:{'yes' if v else 'no'}" for k, v in has.items())
    print(f"global route : {marks}")
    hit = [name for name, rx in SIGS if re.search(rx, text, re.M)]
    print(f"signatures   : {', '.join(hit) if hit else 'none in the log (the process died without a message)'}")

    res = block_after(lines, "GRT-0053", 14, r"^-{10,}", 2)
    if res:
        print("\n--- routing resources (GRT-0053)")
        print("\n".join(res))
    cong = block_after(lines, "GRT-0096", 16, r"^Total")
    if cong:
        print("\n--- final congestion (GRT-0096)")
        print("\n".join(cong))
    st = next((i for i, l in enumerate(lines) if "Stack trace" in l), None)
    if st is not None:
        # the frames that name the crashing function come first; the Tcl frames after them do not matter
        print(f"\n--- crash in {rel} (first frames)")
        print("\n".join(lines[max(0, st - 6):st + 14]))
    else:
        print(f"\n--- last 25 lines of {rel}")
        print("\n".join(lines[-25:]))

    print("\n--- reading")
    if stage == "grt-overflow":
        print("  global route found overflow after the first routing and died during the")
        print("  congestion (rip-up/re-route) iterations.")
        if "fastroute-route-buffer" in hit:
            print("  updateRouteType1/2 in the stack: FastRoute (this OpenROAD) copies a detoured")
            print("  route into a buffer sized x+y gcells of the die and overruns it once a net")
            print("  detours further than that - a symptom of heavy congestion, not of memory.")
        print("  Look at the congestion first:")
        print("  openlane/run_flow.sh core-probe  (global route only, no iterations, ~15-30 min)")
    elif stage == "grt-congestion":
        print("  global route went through all its congestion iterations and still had")
        print("  overflow (GRT-0118/0119), so OpenLane stopped. The congestion report it wrote")
        print("  (tmp/routing/*congestion*.rpt) shows where; run_flow.sh core-triage maps it.")
    elif stage == "grt-initial":
        print("  global route died before any congestion iteration (initial pattern/maze")
        print("  routing). openlane/run_flow.sh core-probe reproduces just this part.")
    elif stage in ("rsz", "dpl", "after-dpl"):
        print("  global route itself finished; the crash came in the resizer/placement part of")
        print("  the GRT-based optimisation. core-route resumes from CTS without that step.")
    elif stage == "finished":
        print("  the run finished.")
    else:
        print("  not a routing crash - read the last lines above.")
    print(f"TRIAGE stage={stage} signal={signal}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
