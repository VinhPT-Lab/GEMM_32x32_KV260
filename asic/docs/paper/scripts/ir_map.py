#!/usr/bin/env python3
"""IR-drop maps and summary from the per-instance voltages written by OpenROAD PSM
(analyze_power_grid -outfile, OpenLane 1.0.2 image), one CSV per net.
usage: ir_map.py <paper dir> <vccd1.csv> <vssd1.csv> [tag]   (tag is appended to the output names)"""
import sys, csv, statistics as st
import matplotlib; matplotlib.use('Agg'); import matplotlib.pyplot as plt
P, fv, fg = sys.argv[1:4]; TAG = ('_' + sys.argv[4]) if len(sys.argv) > 4 else ''
def load(f):
    rows = []
    for t in csv.reader(open(f)):
        if not t or t[0].startswith('Instance'): continue
        rows.append((t[0].strip(), float(t[1]), float(t[2]), float(t[3])))
    return rows
summ = []; fig, axs = plt.subplots(1, 2, figsize=(10, 7))
for ax, (net, f, vdd) in zip(axs, (('vccd1', fv, 1.8), ('vssd1', fg, 0.0))):
    r = load(f)
    drop = [(vdd - v) if vdd else v for _, _, _, v in r]
    d = sorted(drop); n = len(d)
    worst = max(r, key=lambda x: (vdd - x[3]) if vdd else x[3])
    summ.append(dict(net=net, nodes=n, worst_drop_mV=round(d[-1] * 1e3, 2), mean_drop_mV=round(st.mean(d) * 1e3, 3),
                     p99_drop_mV=round(d[int(n * .99)] * 1e3, 2), p999_drop_mV=round(d[int(n * .999)] * 1e3, 2),
                     worst_pct_of_vdd=round(d[-1] / 1.8 * 100, 2), worst_instance=worst[0], worst_x_um=worst[1], worst_y_um=worst[2]))
    sc = ax.scatter([x for _, x, _, _ in r], [y for _, _, y, _ in r], c=[x * 1e3 for x in drop], s=0.3, cmap='inferno_r', rasterized=True)
    ax.set_aspect('equal'); ax.set_title(f'{net}: worst {d[-1]*1e3:.0f} mV, mean {st.mean(d)*1e3:.2f} mV', fontsize=9)
    ax.set_xlabel('x (um)'); ax.set_ylabel('y (um)'); fig.colorbar(sc, ax=ax, label='IR drop (mV)', shrink=.7)
    top = sorted(zip(drop, r), key=lambda z: -z[0])[:100]
    with open(f'{P}/data/irdrop{TAG}_{net}_worst100.csv', 'w', newline='') as o:
        w = csv.writer(o); w.writerow(['instance', 'x_um', 'y_um', 'voltage_V', 'drop_mV'])
        for dd, (i, x, y, v) in top: w.writerow([i, x, y, v, round(dd * 1e3, 3)])
fig.suptitle(f'Static IR drop, TT, 50 MHz, VCD activity of the compute phase of the 64x64x64 job (OpenROAD PSM){TAG}', fontsize=9)
fig.tight_layout()
for ext in ('png', 'pdf'): fig.savefig(f'{P}/figures/irdrop_map{TAG}.{ext}', dpi=200)
with open(f'{P}/data/irdrop{TAG}_summary.csv', 'w', newline='') as o:
    w = csv.DictWriter(o, fieldnames=list(summ[0])); w.writeheader(); w.writerows(summ)
for s in summ: print('IRMAP', s)
