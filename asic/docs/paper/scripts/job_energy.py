#!/usr/bin/env python3
"""Whole-job energy and per-phase power from job_power.sh results (data/power/job_<shape>/).
Power: OpenSTA report_power, TT, signoff SPEF (RC nom), 50 MHz, activity of the whole job 2
(or of the cycles of one phase) from the IP gate-level VCD. Energy = job-average power x job
time (job = JOB_2_START .. last RESULT_ACCEPT, original testbench). Groups as power_groups.py.
usage: job_energy.py <paper dir>"""
import sys, csv, re
P = sys.argv[1]; F = 50.0; PEAK = 102.4
SH = [("64x64x64", 262144), ("8x32x544", 139264), ("16x992x32", 507904)]
PH = ["config", "input_load", "weight_tile", "compute", "output_drain", "job"]
def groups(path):
    g = {}
    for l in open(path):
        m = re.match(r"(.+?)\s{2,}(\d+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)", l)
        if m: g[m.group(1).strip()] = [float(m.group(i)) for i in range(3, 7)]
    return g
def split(g):
    s = lambda pre: sum(v[3] for k, v in g.items() if k.startswith(pre))
    return dict(top_cells_mW=round(s("core:"), 2), rows_x32_mW=round(s("row:"), 2), axi_mW=round(s("AXI macro:"), 2),
                sram_mW=round(s("SRAM"), 2), clock_tree_mW=round(sum(v[3] for k, v in g.items() if "clock tree" in k), 2),
                total_mW=round(g["TOTAL"][3], 2), internal_mW=round(g["TOTAL"][0], 2), switching_mW=round(g["TOTAL"][1], 2),
                leakage_mW=round(g["TOTAL"][2], 2))
ph_rows, en_rows = [], []
for shape, mac in SH:
    d = f"{P}/data/power/job_{shape}/job_{shape}"
    cyc = {r["phase"]: int(r["cycles"]) for r in csv.DictReader(open(f"{d}.phases.csv"))}
    for p in PH:
        if cyc.get(p, 0) == 0: continue
        sp = split(groups(f"{d}.{p}.groups.txt"))
        ph_rows.append(dict(shape=shape, phase=p, cycles=cyc[p], time_us=round(cyc[p] / F, 2),
                            energy_uJ=round(sp["total_mW"] * cyc[p] / F / 1e3, 3), **sp))
    j = split(groups(f"{d}.job.groups.txt")); t = cyc["job"] / F
    e = j["total_mW"] * t / 1e3; gops = 2 * mac / (t * 1e3)
    en_rows.append(dict(shape=shape, f_mhz=F, corner="TT 25C 1.80V", rc="nom", activity="VCD of the whole job 2 (gate level)",
                        job_cycles=cyc["job"], job_time_us=round(t, 2), macs=mac, power_mW=j["total_mW"],
                        energy_per_gemm_uJ=round(e, 3), pJ_per_MAC=round(e * 1e6 / mac, 1), gops=round(gops, 3),
                        gops_per_W=round(gops / (j["total_mW"] / 1e3), 2),
                        sum_of_phases_uJ=round(sum(r["energy_uJ"] for r in ph_rows if r["shape"] == shape and r["phase"] != "job"), 3),
                        peak_gops_per_W_upper=round(PEAK / (j["total_mW"] / 1e3), 1)))
# SRAM as a range (sram_range.py): lower bound replaces the lib SRAM power by the access-based one
try:
    lo = {r["shape"]: float(r["sram_mW_lower"]) for r in csv.DictReader(open(f"{P}/data/sram_range_50MHz.csv")) if r["phase"] == "job"}
    for r in en_rows:
        sram = split(groups(f"{P}/data/power/job_{r['shape']}/job_{r['shape']}.job.groups.txt"))["sram_mW"]
        pl = r["power_mW"] - sram + lo[r["shape"]]; e = pl * r["job_time_us"] / 1e3
        r.update(power_mW_sram_lower=round(pl, 2), energy_uJ_sram_lower=round(e, 3),
                 pJ_per_MAC_sram_lower=round(e * 1e6 / r["macs"], 1), gops_per_W_sram_lower=round(r["gops"] / (pl / 1e3), 2))
except FileNotFoundError:
    pass
for fn, rr in (("power_by_phase_50MHz.csv", ph_rows), ("energy_job_50MHz.csv", en_rows)):
    with open(f"{P}/data/{fn}", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rr[0])); w.writeheader(); w.writerows(rr)
for r in en_rows: print("ENERGY", r)
for r in ph_rows: print("PHASE", r["shape"], r["phase"], r["cycles"], r["total_mW"], r["top_cells_mW"], r["rows_x32_mW"], r["axi_mW"], r["sram_mW"], r["energy_uJ"])
