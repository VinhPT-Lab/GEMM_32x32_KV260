#!/usr/bin/env python3
"""Figures of the paper package from the CSVs in data/ (PNG + PDF in figures/).
usage: plots.py <paper dir>     (matplotlib 3.9.2, numpy 2.x; see SUMMARY.md)"""
import csv, sys, os, collections
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

P = sys.argv[1]; D = f'{P}/data'; F = f'{P}/figures'; os.makedirs(F, exist_ok=True)
rd = lambda f: list(csv.DictReader(open(f'{D}/{f}')))
def save(fig, name):
    fig.tight_layout()
    for ext in ('png', 'pdf'): fig.savefig(f'{F}/{name}.{ext}', dpi=200)
    plt.close(fig); print('FIG', name)

# 1. antenna convergence: full re-route (OpenLane 1.0.2) vs incremental ECO (OpenROAD dcf3613)
a = rd('antenna_convergence.csv')
fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(9, 3.6))
for flow, lab, mk in (('full_reroute_OL1', 'full re-route ECO (OpenLane 1.0.2)', 'o-'),
                      ('incremental_dcf3613', 'incremental ECO (OpenROAD dcf3613)', 's-')):
    r = [x for x in a if x['flow'] == flow]
    # x = rounds after ip_v3r routing round 1 (446 pins), the common starting layout
    sh = 1 if flow == 'full_reroute_OL1' else 0
    ax1.plot([int(x['round']) - sh for x in r], [int(x['violating_pins']) for x in r], mk, label=lab)
    r2 = [x for x in r if int(x['round']) - sh > 0]
    ax2.plot([int(x['round']) - sh for x in r2], [float(x['nets_rerouted_pct']) for x in r2], mk, label=lab)
ax1.axvline(0, color='k', lw=.8, ls=':')
ax1.set_yscale('symlog', linthresh=1); ax1.set_xlabel('ECO round after ip_v3r round 1 (446 pins)'); ax1.set_ylabel('antenna violating pins (ARC)')
ax1.legend(fontsize=7); ax1.grid(alpha=.3)
ax2.set_yscale('symlog', linthresh=0.01); ax2.set_xlabel('ECO round after ip_v3r round 1'); ax2.set_ylabel('nets re-routed per round (%)'); ax2.grid(alpha=.3)
save(fig, 'antenna_convergence')

# 2. DRV through the ECO rounds
d = rd('drv_by_eco_round.csv')
fig, ax = plt.subplots(figsize=(9, 3.6))
for corner, mk in (('tt RC nom', 'o-'), ('ss RC max', 's-')):
    r = [x for x in d if x['corner'] == corner and x['tag'] != 'final']
    ax.plot(range(len(r)), [int(x['std_cell_nets_over_lib']) for x in r], mk, label=f'std-cell nets over lib limit, {corner}')
r = [x for x in d if x['corner'] == 'tt RC nom' and x['tag'] != 'final']
ax.set_xticks(range(len(r))); ax.set_xticklabels([x['tag'] for x in r], rotation=0)
ax.set_yscale('symlog', linthresh=1); ax.set_ylabel('nets'); ax.set_xlabel('layout after ECO step')
ax.legend(fontsize=8); ax.grid(alpha=.3)
save(fig, 'drv_by_eco_round')

# 3. SRAM clock pin slew before / after the clock ECO
s = rd('sram_clk_slew_before_after.csv')
fig, axs = plt.subplots(1, 2, figsize=(9, 3.6))
for ax, corner, tgt in ((axs[0], 'tt RC nom', 0.75), (axs[1], 'ss RC max', 1.0)):
    r = [x for x in s if x['corner'] == corner]
    b = sorted(float(x['slew_before_ns']) for x in r); af = sorted(float(x['slew_after_ns']) for x in r)
    ax.plot(range(len(b)), b, label='before clock ECO (layout a2)'); ax.plot(range(len(af)), af, label='final layout')
    ax.axhline(tgt, color='k', ls='--', lw=1, label=f'target {tgt} ns')
    ax.set_yscale('log'); ax.set_xlabel('SRAM clock pins (sorted)'); ax.set_ylabel('slew (ns)'); ax.set_title(corner, fontsize=9)
    ax.legend(fontsize=7); ax.grid(alpha=.3)
save(fig, 'sram_clk_slew')

# 4. slack histograms of the final layout, internal paths, per corner
h = rd('slack_histogram_final.csv')
fig, axs = plt.subplots(2, 3, figsize=(11, 5.5), sharey=False)
for j, c in enumerate(('tt', 'ff', 'ss')):
    for i, chk in enumerate(('setup', 'hold')):
        ax = axs[i][j]
        for kind, lab in (('cc', 'cell-to-cell'), ('cm', 'touching a macro'), ('io', 'I/O (report only)')):
            r = [x for x in h if x['lib_corner'] == c and x['rc'] == 'max' and x['check'] == chk and x['path_kind'] == kind]
            if not r: continue
            ax.bar([float(x['bin_lo_ns']) for x in r], [int(x['endpoints']) for x in r], width=0.1, alpha=.55, label=lab, align='edge')
        ax.axvline(0, color='k', lw=1); ax.set_yscale('log'); ax.set_title(f'{chk}, {c.upper()} RC max', fontsize=9)
        ax.set_xlabel('slack (ns), clock 20 ns'); ax.set_ylabel('endpoints')
        if i == 0 and j == 0: ax.legend(fontsize=7)
save(fig, 'slack_histograms')

# 5. RCX / GRT capacitance ratio on the 85 long nets
c = rd('cap_ratio_rcx_grt.csv')
fig, ax = plt.subplots(figsize=(4.5, 3.6))
ax.scatter([float(x['grt_total_pF']) for x in c], [float(x['rcx_total_pF']) for x in c], s=10)
m = max(float(x['rcx_total_pF']) for x in c)
for k in (1, 2, 3): ax.plot([0, m / k], [0, m], lw=.8, ls='--', label=f'RCX = {k} x GRT')
ax.set_xlabel('C after global route (pF)'); ax.set_ylabel('C extracted, RCX max (pF)'); ax.legend(fontsize=7); ax.grid(alpha=.3)
save(fig, 'cap_ratio_rcx_grt')
