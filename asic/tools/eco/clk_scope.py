#!/usr/bin/env python3
"""B: clock nets in scope from clk_scope.tcl dumps (TT nom, SS max): a sink pin over
its target (SRAM clk pin: 0.75 ns TT nom, 1.0 ns SS max; any other pin: its lib slew
limit, 1.5 ns; AXI shell S_AXI_ACLK: as SRAM), plus slew statistics of SRAM clock pins and flop CLK pins.
usage: clk_scope.py tt_nom.tsv ss_max.tsv out_prefix"""
import sys, collections
tt, ss, out = sys.argv[1:4]
def stat(v):
    v = sorted(v); n = len(v)
    return f'n {n} median {v[n//2]:.3f} p95 {v[int(n*0.95)]:.3f} max {v[-1]:.3f}'
nets = collections.defaultdict(dict); drv = {}
for fn, c, tgt in ((tt, 'tt', 0.75), (ss, 'ss', 1.0)):
    sram = []; flop = []; bad = collections.defaultdict(list)
    for l in open(fn):
        t = l.rstrip('\n').split('\t')
        if t[6] != 'input' or t[11] == 'nan': continue
        v = float(t[11]); drv[t[0]] = (t[1], t[2], t[3])
        if t[5] == 'GemmAxiShell' and t[4].endswith('/S_AXI_ACLK'):
            # no lib limit on the shell clock pin: same target as the SRAM clock pins
            print(f'CLKSCOPE {c}: {t[4]} slew {v:.3f} (target {tgt})')
            if v > tgt: bad[t[0]].append((t[4], v, 'AXI'))
        elif t[5].startswith('sky130_sram'):
            sram.append(v)
            if v > tgt: bad[t[0]].append((t[4], v, 'SRAM'))
        else:
            if t[4].endswith('/CLK'): flop.append(v)
            lim = float(t[7]) if t[7] not in ('', '0.00') else 1.5
            if v > lim: bad[t[0]].append((t[4], v, t[5].replace('sky130_fd_sc_hd__', '')))
    print(f'CLKSCOPE {c}: SRAM clk pins {stat(sram)}, over {tgt}: {sum(x > tgt for x in sram)}; flop CLK {stat(flop)}; nets with a sink over target {len(bad)}')
    for n, v in bad.items(): nets[n][c] = v
with open(out + '.tsv', 'w') as f:
    for n in sorted(nets):
        d = drv[n]
        f.write(f'{n}\t{d[0]}\t{d[1]}\t{d[2]}\t{len(nets[n].get("tt", []))}\t{len(nets[n].get("ss", []))}\t'
                + ' '.join(f'{p}:{v:.2f}' for p, v, k in nets[n].get('ss', nets[n].get('tt', []))) + '\n')
open(out + '.nets', 'w').write('\n'.join(sorted(nets)) + '\n')
print(f'CLKSCOPE scope: {len(nets)} nets; drivers ' + str(dict(collections.Counter(drv[n][1] for n in nets))))
print('CLKSCOPE driver levels ' + str(dict(collections.Counter(n.split('_')[1] if n.startswith('clknet_') else n for n in nets))))
