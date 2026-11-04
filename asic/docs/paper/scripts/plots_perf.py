#!/usr/bin/env python3
"""Roofline and PE utilisation from data/perf_rtl_shapes.csv (perf_rtl.py), PNG + PDF.
Roofline: x = ops per byte moved on the AXI-Stream ports (2 inputs + 1 output, 256 bit each,
including padding and the operands re-sent by every sub-job), y = GOPS at 50 MHz.
Ceilings: compute 1024 MAC x 2 ops x 50 MHz = 102.4 GOPS; stream bandwidth 3 x 32 B x 50 MHz
= 4.8 GB/s (all three streams busy every cycle). The IP does not overlap load, compute and
drain (phases.py), so the points stay well below both ceilings.
usage: plots_perf.py <paper dir>"""
import sys, csv
import numpy as np
import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
P = sys.argv[1]
rows = list(csv.DictReader(open(f"{P}/data/perf_rtl_shapes.csv")))
PEAK = 102.4; BW = 4.8
fig, ax = plt.subplots(figsize=(6.4, 4.4))
x = np.logspace(0, 2.5, 200)
ax.loglog(x, np.minimum(PEAK, BW * x), "k-", lw=1.2, label="roofline (102.4 GOPS, 4.8 GB/s)")
ax.loglog(x, np.minimum(PEAK, 3.2 * x), "k:", lw=0.8, label="inputs only (3.2 GB/s)")
mk = {"tb": ("o", "testbench as given"), "fullrate": ("s", "full-rate streams")}
for mode, (m, lab) in mk.items():
    rr = [r for r in rows if r["mode"] == mode]
    ax.scatter([float(r["ops_per_byte"]) for r in rr], [float(r["gops"]) for r in rr], marker=m, s=22, label=lab, zorder=3)
    if mode == "fullrate":
        for r in rr:
            ax.annotate(r["shape"], (float(r["ops_per_byte"]), float(r["gops"])), fontsize=5.5, xytext=(3, 2), textcoords="offset points")
ax.set_xlabel("operational intensity (ops / AXI-Stream byte)"); ax.set_ylabel("GOPS at 50 MHz")
ax.set_title("Roofline, RTL sim of the built configuration (asic-sram, lean AXIS, CG)", fontsize=9)
ax.grid(True, which="both", lw=0.3); ax.legend(fontsize=7, loc="lower right"); ax.set_ylim(0.2, 200)
fig.tight_layout()
for ext in ("png", "pdf"): fig.savefig(f"{P}/figures/roofline.{ext}", dpi=200)
plt.close(fig)
# PE utilisation and phase split per shape
names = [r["shape"] for r in rows if r["mode"] == "tb"]
ut = {m: [float(next(r for r in rows if r["shape"] == n and r["mode"] == m)["pe_util_pct"]) for n in names] for m in mk}
PH = ["config", "input_load", "weight_tile", "compute", "tile_reload", "output_drain"]
fig, (a1, a2) = plt.subplots(2, 1, figsize=(8, 6.4), sharex=True)
i = np.arange(len(names))
a1.bar(i - 0.2, ut["tb"], 0.4, label="testbench as given"); a1.bar(i + 0.2, ut["fullrate"], 0.4, label="full-rate streams")
a1.set_ylabel("PE utilisation (%)"); a1.legend(fontsize=7); a1.grid(axis="y", lw=0.3)
a1.set_title("PE utilisation = MAC / (1024 x cycles), sub-jobs back to back", fontsize=9)
bot = np.zeros(len(names))
for p in PH:
    v = np.array([float(next(r for r in rows if r["shape"] == n and r["mode"] == "fullrate")[f"{p}_pct"]) for n in names])
    a2.bar(i, v, 0.6, bottom=bot, label=p); bot += v
a2.set_ylabel("share of cycles (%), full-rate"); a2.legend(fontsize=7, ncol=6, loc="upper center", bbox_to_anchor=(0.5, 1.15))
a2.set_xticks(i); a2.set_xticklabels([f"{n}\n{r['M']}x{r['K']}x{r['N']}" for n, r in zip(names, [r for r in rows if r["mode"] == "tb"])], rotation=45, ha="right", fontsize=6.5)
fig.tight_layout()
for ext in ("png", "pdf"): fig.savefig(f"{P}/figures/pe_utilisation.{ext}", dpi=200)
print("PLOTS roofline, pe_utilisation")
