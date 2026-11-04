#!/usr/bin/env python3
"""Energy per GEMM, pJ/MAC and GOPS/W at 50 MHz from the activity-based power of a
400-cycle window taken while the array computes (job 2 of each shape) and the job length
of the gate-level simulation (perf_gls_50MHz.csv, window 'job', job 2).
Assumption: the window power stands for the whole job (the window is inside the compute
phase; the data-in / data-out phases may draw less).
usage: energy.py <paper dir>"""
import csv, re, sys
P = sys.argv[1]
perf = {(r['shape'], r['job'], r['window']): r for r in csv.DictReader(open(f'{P}/data/perf_gls_50MHz.csv'))}
win = {'64x64x64': '2400_2800', '8x32x544': '8000_8400', '16x992x32': '15000_15400'}
rows = []
for shape, w in win.items():
    g = open(f'{P}/data/power/vcd_{shape}_{w}.groups.txt').read()
    tot = re.search(r'^TOTAL\s+\d+\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)', g, re.M)
    internal, switching, leak, p_mw = (float(x) for x in tot.groups())
    sram = float(re.search(r'^SRAM \(80 macro\)\s+\d+\s+[\d.]+\s+[\d.]+\s+[\d.]+\s+([\d.]+)', g, re.M).group(1))
    r = perf[(shape, '2', 'job')]
    t_s = float(r['time_us']) * 1e-6; macs = int(r['macs']); gops = float(r['gops'])
    e_uj = p_mw * 1e-3 * t_s * 1e6
    rows.append(dict(shape=shape, vcd_window_cycles=w.replace('_', '..'), f_mhz=50, corner='TT 25C 1.80V', rc='nom',
                     power_mw=p_mw, internal_mw=internal, switching_mw=switching, leakage_mw=leak, sram_mw=sram,
                     job_cycles=r['cycles'], job_time_us=r['time_us'], macs=macs, energy_per_gemm_uj=round(e_uj, 3),
                     pj_per_mac=round(e_uj * 1e6 / macs, 2), gops_effective=gops, gops_per_w=round(gops / (p_mw * 1e-3), 2),
                     peak_gops=102.4, gops_per_w_at_peak=round(102.4 / (p_mw * 1e-3), 1)))
with open(f'{P}/data/energy_50MHz.csv', 'w', newline='') as f:
    wr = csv.DictWriter(f, fieldnames=list(rows[0])); wr.writeheader(); wr.writerows(rows)
for r in rows: print('ENERGY', {k: r[k] for k in ('shape', 'power_mw', 'energy_per_gemm_uj', 'pj_per_mac', 'gops_effective', 'gops_per_w', 'gops_per_w_at_peak')})
