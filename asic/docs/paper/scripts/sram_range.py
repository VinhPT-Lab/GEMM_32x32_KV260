#!/usr/bin/env python3
"""SRAM power as a range, per shape and phase, from <job>.sram.csv (vcd2act_phases.py).
OpenRAM lib (sky130_sram_2kbyte_1rw1r_32x512_8, TT): every clk0 / clk1 edge costs 13.8084 pJ
whatever csb / web are (the 'when' groups all carry the same value), i.e. 27.617 pJ per port
per cycle -> 80 macros x 2 ports at 50 MHz = 220.93 mW + leakage 2.836 mW (OpenSTA); this is the
upper bound (what report_power gives). Lower bound: only the cycles where the port is selected
(csb low, as the macro latches it at the clock edge) pay that energy; leakage unchanged.
usage: sram_range.py <out.csv> <job.sram.csv>..."""
import sys, csv, collections
E = 2 * 13.8084e-12; F = 50e6; LEAK = 2.8362e-3 / 80; N = 80   # leakage as OpenSTA reports it for the 80 macros
out = []
for path in sys.argv[2:]:
    shape = path.rsplit("/", 1)[-1].replace("job_", "").replace(".sram.csv", "")
    agg = collections.defaultdict(lambda: collections.Counter())
    for r in csv.DictReader(open(path)):
        a = agg[r["phase"]]; a["cycles"] = int(r["cycles"]); a["n"] += 1
        a["csb0"] += int(r["csb0_low"]); a["wr"] += int(r["csb0_low_web0_low"]); a["csb1"] += int(r["csb1_low"])
        a[f"{r['buffer']}:csb0"] += int(r["csb0_low"]); a[f"{r['buffer']}:csb1"] += int(r["csb1_low"])
    for ph, a in agg.items():
        c = a["cycles"]
        up = N * (2 * E * F + LEAK); lo = (a["csb0"] + a["csb1"]) / c * E * F + N * LEAK
        out.append(dict(shape=shape, phase=ph, cycles=c, macros=a["n"],
                        port0_selected_pct=round(100 * a["csb0"] / (N * c), 2), port0_write_pct=round(100 * a["wr"] / (N * c), 2),
                        port1_selected_pct=round(100 * a["csb1"] / (N * c), 2),
                        sram_mW_lower=round(lo * 1e3, 2), sram_mW_upper_lib=round(up * 1e3, 2),
                        avg_selected_macros_by_buffer_port=" ".join(f"{k}={v / c:.2f}" for k, v in sorted(a.items()) if ":" in k)))
        print("SRAMRANGE", out[-1])
with open(sys.argv[1], "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(out[0])); w.writeheader(); w.writerows(out)
