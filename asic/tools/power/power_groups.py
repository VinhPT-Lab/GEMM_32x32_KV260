# power_groups.py <inst.rpt> <refs.txt>: per-instance power (report_power -instances) summed by group
import sys, collections
ref = {}
for l in open(sys.argv[2]):
    n, r = l.rsplit(" ", 1); ref[n] = r.strip()
def group(n, r):
    if r.startswith("sky130_sram"): return "SRAM (80 macro)"
    leaf = n.rsplit("/", 1)[-1]
    clk = leaf.startswith(("clkbuf_", "clkload")) or "__clkbuf" in r and leaf.startswith("clk")
    seq = any(k in r for k in ("__df", "__dl", "__sdf", "__edf"))
    kind = "clock tree" if clk else ("sequential" if seq else ("diode" if "__diode" in r else "combinational"))
    where = "row" if "u_row/" in n else "AXI macro" if n.startswith("u_axi_shell/") else "core"
    return f"{where}: {kind}"
tot = collections.defaultdict(lambda: [0.0]*4); cnt = collections.Counter(); miss = 0
for l in open(sys.argv[1]):
    f = l.split()
    if len(f) != 5: continue
    try: v = [float(x) for x in f[:4]]
    except ValueError: continue
    r = ref.get(f[4]); 
    if r is None: miss += 1; continue
    g = group(f[4], r); cnt[g] += 1
    for i in range(4): tot[g][i] += v[i]
T = [sum(t[i] for t in tot.values()) for i in range(4)]
print(f"{'group':28s} {'cells':>8s} {'internal':>10s} {'switching':>10s} {'leakage':>10s} {'total mW':>10s}   %")
for g in sorted(tot, key=lambda g: -tot[g][3]):
    t = tot[g]; print(f"{g:28s} {cnt[g]:8d} " + " ".join(f"{x*1e3:10.2f}" for x in t) + f" {100*t[3]/T[3]:5.1f}")
print(f"{'TOTAL':28s} {sum(cnt.values()):8d} " + " ".join(f"{x*1e3:10.2f}" for x in T) + f"   (unmatched lines {miss})")
