#!/usr/bin/env python3
"""sta_corners.py <run dir>
Multi-corner STA of a finished run (logs/signoff/*-rcx_mcsta.{min,max}.log): splits each
report_checks block by library corner (Slowest / Typical / Fastest) and prints the
sta_summary.py summary of setup at Slowest and hold at Fastest, for RC min and RC max.
Paths touching an I/O port are counted apart by sta_summary.py."""
import glob, os, subprocess, sys, tempfile

run = sys.argv[1]
here = os.path.dirname(os.path.abspath(__file__))
tmp = tempfile.mkdtemp(prefix="sta_corners_")
for rc in ("min", "max"):
    logs = sorted(glob.glob(os.path.join(run, "logs", "signoff", f"*-rcx_mcsta.{rc}.log")))
    if not logs:
        print(f"no *-rcx_mcsta.{rc}.log in {run}/logs/signoff"); continue
    text = open(logs[-1], errors="ignore").read()
    for kind, cmd, corner in (("setup", "report_checks -path_delay max", "Slowest"),
                              ("hold", "report_checks -path_delay min", "Fastest")):
        i = text.find(cmd)
        if i < 0:
            print(f"{os.path.basename(logs[-1])}: no '{cmd}'"); continue
        j = text.find("\nreport_checks", i + len(cmd))
        sec = text[i:j if j > 0 else len(text)]
        part = [c for c in sec.split("======================= ")[1:] if c.split()[0] == corner]
        if not part:
            print(f"{os.path.basename(logs[-1])}: no {corner} corner"); continue
        f = os.path.join(tmp, f"{kind}_{corner}_rc{rc}.txt")
        open(f, "w").write(part[0])
        print(f"\n===== {kind}, {corner}, RC {rc}  ({os.path.basename(logs[-1])})")
        sys.stdout.flush()
        subprocess.run([sys.executable, os.path.join(here, "sta_summary.py"), f, "--worst", "1"])
