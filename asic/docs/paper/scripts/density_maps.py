#!/usr/bin/env python3
"""Placement density map (from OpenROAD gui::dump_heatmap Placement, 10 um bins) and
post-route wire utilisation per layer from the final DEF: signal wire length in each
50 um tile / track length available in the tile (tile area / track pitch of the layer).
This is the routed result, not a global-route estimate.
usage: density_maps.py <paper dir> <final DEF> <placement heatmap csv.gz>"""
import sys, re, gzip, csv, collections
import numpy as np
import matplotlib; matplotlib.use('Agg'); import matplotlib.pyplot as plt
P, DEF, HM = sys.argv[1:4]
T = 50.0
PITCH = {'met1': 0.34, 'met2': 0.46, 'met3': 0.68, 'met4': 0.92}
# ---- placement density
rows = [r for r in csv.DictReader(gzip.open(HM, 'rt'))]
x1 = max(float(r['x1']) for r in rows); y1 = max(float(r['y1']) for r in rows); s = 10.0
img = np.zeros((int(y1 / s) + 1, int(x1 / s) + 1))
for r in rows: img[int(float(r['y0']) / s), int(float(r['x0']) / s)] = float(r['value'])
fig, ax = plt.subplots(figsize=(5.5, 7))
im = ax.imshow(img, origin='lower', extent=(0, x1, 0, y1), cmap='viridis', vmin=0, vmax=100)
fig.colorbar(im, ax=ax, label='placement density (%)', shrink=.7)
ax.set_xlabel('x (um)'); ax.set_ylabel('y (um)'); ax.set_title('Placement density, 10 um bins (OpenROAD heat map)', fontsize=9)
fig.tight_layout()
for ext in ('png', 'pdf'): fig.savefig(f'{P}/figures/placement_density.{ext}', dpi=200)
plt.close(fig)
# ---- routed wire utilisation per layer
dbu = 1000; die = None; wl = {l: collections.Counter() for l in PITCH}; sec = None
for line in open(DEF):
    if sec is None:
        if line.startswith('DIEAREA'):
            v = [int(x) for x in re.findall(r'-?\d+', line)]; die = (v[2] / dbu, v[3] / dbu)
        elif line.startswith('NETS '): sec = 'N'
        continue
    if line.startswith('END NETS'): break
    for part in re.split(r'\bNEW\b|\+ ROUTED', line):
        m = re.match(r'\s*(met[1-4])\s+(?:\d+\s+)?\(\s*(-?\d+)\s+(-?\d+)[^)]*\)\s*\(\s*(\S+)\s+(\S+)[^)]*\)', part)
        if not m: continue
        l = m.group(1); xa, ya = int(m.group(2)) / dbu, int(m.group(3)) / dbu
        xb = xa if m.group(4) == '*' else int(m.group(4)) / dbu; yb = ya if m.group(5) == '*' else int(m.group(5)) / dbu
        L = abs(xb - xa) + abs(yb - ya)
        if L == 0: continue
        n = max(1, int(L / (T / 4)))            # split long wires so each piece lands in its tile
        for k in range(n):
            f = (k + 0.5) / n
            wl[l][(int((xa + (xb - xa) * f) / T), int((ya + (yb - ya) * f) / T))] += L / n
nx, ny = int(die[0] / T) + 1, int(die[1] / T) + 1
fig, axs = plt.subplots(1, 4, figsize=(14, 5.5))
summ = []
for ax, l in zip(axs, PITCH):
    a = np.zeros((ny, nx))
    for (i, j), v in wl[l].items():
        if 0 <= i < nx and 0 <= j < ny: a[j, i] = v / (T * T / PITCH[l]) * 100
    im = ax.imshow(a, origin='lower', extent=(0, nx * T, 0, ny * T), cmap='magma', vmin=0, vmax=100)
    ax.set_title(f'{l}: max {a.max():.0f} %, mean {a.mean():.1f} %', fontsize=9); ax.set_xticks([]); ax.set_yticks([])
    summ.append([l, PITCH[l], round(a.max(), 1), round(a.mean(), 2), round(float(np.percentile(a, 99)), 1), int((a > 70).sum())])
fig.colorbar(im, ax=axs, label='routed signal wire / track capacity (%)', shrink=.7)
fig.suptitle('Post-route wire utilisation per 50 um tile, final layout (signal nets)', fontsize=10)
for ext in ('png', 'pdf'): fig.savefig(f'{P}/figures/routing_utilisation.{ext}', dpi=200)
with open(f'{P}/data/routing_utilisation.csv', 'w', newline='') as f:
    w = csv.writer(f); w.writerow(['layer', 'track_pitch_um', 'max_pct', 'mean_pct', 'p99_pct', 'tiles_over_70pct']); w.writerows(summ)
for r in summ: print('ROUTEUTIL', r)
