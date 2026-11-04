#!/usr/bin/env python3
"""
clock_latency.py <array run dir> <out.tcl>
Read the signoff STA reports of a finished gemm_array run, collect the
propagated clock network delay seen at the flops/macros, and write
  set ::env(GEMM_CLK_LAT_MIN) ...
  set ::env(GEMM_CLK_LAT_MAX) ...
for array.sdc, so the I/O delays of the next run are measured from the same
clock arrival as the flops inside (in the final chip these ports face flops
on the same clock tree, not an ideal clock at 0 ns).
"""
import glob, os, re, sys, statistics

run, out = sys.argv[1], sys.argv[2]
vals = []
for pat in ("*rcx_sta.min.rpt", "*rcx_sta.max.rpt"):
    fs = sorted(glob.glob(os.path.join(run, "reports/signoff", pat)))
    if not fs:
        continue
    edge = 0.0
    for line in open(fs[-1], errors="replace"):
        # every clock path starts at its edge (0 for launch, one period later
        # for a setup capture) - latency is measured from that edge
        e = re.search(r"(-?\d+\.\d+)\s+clock \S+ \((?:rise|fall) edge\)", line)
        if e:
            edge = float(e.group(1))
            continue
        # plain format: "  1.20  1.20  clock network delay (propagated)"
        m = re.match(r"\s*(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+clock network delay \(propagated\)", line)
        if m and float(m.group(1)) > 0:
            vals.append(float(m.group(1)))
            continue
        # full_clock_expanded: the time on the flop CLK / macro i_clk pin line
        m = re.search(r"(-?\d+\.\d+)\s+[\^v]\s+\S+/(CLK|CLK_N|i_clk)\s+\(", line)
        if m:
            vals.append(float(m.group(1)) - edge)
if len(vals) < 10:
    sys.exit(f"only {len(vals)} propagated clock delays found in {run}/reports/signoff - nothing written")
# breakdown: row macro clock pins (per row) vs top-level flops
rows, flops, named = {}, [], {}
for pat in ("*rcx_sta.min.rpt", "*rcx_sta.max.rpt"):
    fs = sorted(glob.glob(os.path.join(run, "reports/signoff", pat)))
    edge = 0.0
    for line in (open(fs[-1], errors="replace") if fs else []):
        e = re.search(r"(-?\d+\.\d+)\s+clock \S+ \((?:rise|fall) edge\)", line)
        if e:
            edge = float(e.group(1))
            continue
        m = re.search(r"(-?\d+\.\d+)\s+[\^v]\s+(\S+)/(CLK|CLK_N|i_clk)\s+\(", line)
        if not m:
            continue
        m_t = float(m.group(1)) - edge
        r = re.search(r"g_pe_row\\?\[(\d+)\\?\]", m.group(2))
        if r:
            rows.setdefault(int(r.group(1)), []).append(m_t)
        else:
            flops.append(m_t)
            named[m.group(2)] = max(named.get(m.group(2), 0.0), m_t)
if flops:
    flops.sort()
    print(f"top-level flops : min {flops[0]:.2f}  median {statistics.median(flops):.2f}  max {flops[-1]:.2f} ns ({len(flops)} samples)")
if rows:
    print("row macro i_clk : " + "  ".join(f"r{k}:{max(v):.2f}" for k, v in sorted(rows.items())))
# where are the earliest / latest flops? (positions from the final DEF)
defs = sorted(glob.glob(os.path.join(run, "results", "final", "def", "*.def")))
if named and defs:
    srt = sorted(named.items(), key=lambda kv: kv[1])
    pick = dict(srt[:6] + srt[-6:])
    pos, units, inside = {}, 1000.0, False
    for line in open(defs[-1], errors="replace"):
        if line.startswith("UNITS DISTANCE MICRONS"):
            units = float(line.split()[3])
        elif line.startswith("COMPONENTS"):
            inside = True
        elif line.startswith("END COMPONENTS"):
            break
        elif inside:
            mm = re.match(r"^\s*-\s+(\S+)\s+\S+.*?\(\s*(-?\d+)\s+(-?\d+)\s*\)", line)
            if mm and mm.group(1) in pick:
                pos[mm.group(1)] = (int(mm.group(2)) / units, int(mm.group(3)) / units)
    for label, part in (("earliest", srt[:6]), ("latest", srt[-6:])):
        print(f"{label:9s}: " + "  ".join(
            f"{n}@{v:.1f}ns({pos[n][0]:.0f},{pos[n][1]:.0f})" if n in pos else f"{n}@{v:.1f}ns" for n, v in part))
vals.sort()
lo, hi, med = vals[0], vals[-1], statistics.median(vals)
print(f"clock network delay at flops/macros: min {lo:.2f}  median {med:.2f}  max {hi:.2f} ns  ({len(vals)} samples)")
with open(out, "w") as f:
    f.write(f"# written by tools/clock_latency.py from {run}\n")
    # the outside flops (Buffer_feeder / Out_buffer) are modelled at the TYPICAL
    # latency of the inside ones; the full spread is the tree's own skew, which
    # the internal paths already see
    f.write(f"# observed min {lo:.2f} / median {med:.2f} / max {hi:.2f} ns\n")
    f.write(f"set ::env(GEMM_CLK_LAT_MIN) {med:.2f}\nset ::env(GEMM_CLK_LAT_MAX) {med:.2f}\n")
print(f"wrote {out}")
