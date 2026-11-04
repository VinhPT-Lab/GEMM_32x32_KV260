#!/usr/bin/env python3
"""vcd2act_flat.py <vcd> <netlist.nl.v> <scope> <out.act>
Activity of a FLAT gate netlist (e.g. the GemmAxiShell run) from a net-level VCD
of one scope (depth 1, e.g. tb.dut.u_axi_shell): per-net toggle count and time
at 1, mapped to the driver pin of every net (std-cell outputs, ICG GCLK).
Same output format as vcd2act.py, so tools/power/shell_power.tcl reads it the
way power.tcl reads the core's:
  pin|port <name> <toggles> <duty>     plus header '# cycles N period_ps P window_ps T'
Input ports are listed as 'port' lines. shell_power.tcl applies both kinds (the core's
power.tcl applies only 'pin' lines; the shell is mostly port-facing logic)."""
import collections
import re
import sys

vcd, netlist, scope_name, out = sys.argv[1:5]
OUTPINS = {"X", "Y", "Q", "Q_N", "GCLK", "HI", "LO"}
PERIOD_PS = 10000

ids = collections.defaultdict(list)
scope = []
t0 = None
t = 0
with open(vcd) as f:
    for line in f:
        if line.startswith("$scope"):
            scope.append(line.split()[2].lstrip("\\"))
            continue
        if line.startswith("$upscope"):
            scope.pop()
            continue
        if line.startswith("$var"):
            if not scope or scope[-1] != scope_name:
                continue
            tok = line.split()
            w = int(tok[2])
            vid = tok[3]
            rest = tok[4:-1]
            name = rest[0].lstrip("\\")
            if len(rest) == 2 and ":" in rest[1]:
                hi, lo = map(int, rest[1][1:-1].split(":"))
                step = -1 if hi >= lo else 1
                bits = [f"{name}[{b}]" for b in range(hi, lo + step, step)]
            else:
                bits = [name] if w == 1 else [f"{name}[{b}]" for b in range(w - 1, -1, -1)]
            ids[vid].append(bits)          # several names can share one VCD id (aliases)
            continue
        if line.startswith("$enddefinitions"):
            break
    val, last = {}, {}
    tog, high = collections.Counter(), collections.Counter()

    def setbits(vid, v, now):
        for bits in ids.get(vid, ()):
            vv = v.rjust(len(bits), v[0] if v[0] in "xz" else "0")
            for i, k in enumerate(bits):
                nv = vv[i]
                ov = val.get(k)
                if ov == nv:
                    continue
                if ov == "1":
                    high[k] += now - last[k]
                if ov in ("0", "1") and nv in ("0", "1"):
                    tog[k] += 1
                val[k] = nv
                last[k] = now

    for line in f:
        c = line[0]
        if c == "#":
            t = int(line[1:])
            if t0 is None:
                t0 = t
        elif c in "01xz":
            setbits(line[1:].strip(), c, t)
        elif c == "b":
            v, vid = line[1:].split()
            setbits(vid, v, t)
    t1 = t
for k, v in val.items():
    if v == "1":
        high[k] += t1 - last[k]
T = max(1, (t1 or 0) - (t0 or 0))
nbits = sum(len(b) for v in ids.values() for b in v)
print(f"vcd: scope {scope_name}: {len(ids)} ids, {nbits} bits, window {t0}..{t1} ps")
if not ids:
    sys.exit(f"vcd2act_flat.py: no nets of scope '{scope_name}' in {vcd}")

text = open(netlist).read()
m = re.search(r"\bmodule\s+(\w+)\s*\((.*?)\);", text, re.S)
inputs = set()
for mm in re.finditer(r"^\s*input\s+(?:wire\s+)?(\[[^\]]*\]\s*)?([\w\\\[\]$]+)\s*;", text, re.M):
    rng, name = mm.group(1), mm.group(2).lstrip("\\")
    if rng:
        hi, lo = map(int, rng.strip()[1:-1].split(":"))
        for b in range(min(hi, lo), max(hi, lo) + 1):
            inputs.add(f"{name}[{b}]")
    else:
        inputs.add(name)

drivers = []
for mm in re.finditer(r"^\s*(sky130_\w+)\s+(\\\S+|\S+)\s*\((.*?)\);", text, re.M | re.S):
    typ, inst, body = mm.group(1), mm.group(2).lstrip("\\"), mm.group(3)
    for p, e in re.findall(r"\.(\w+)\(\s*([^()]*?)\s*\)", body, re.S):
        if p in OUTPINS and e:
            drivers.append((f"{inst}/{p}", e.strip().lstrip("\\").strip()))

ncyc = round(T / PERIOD_PS)
miss = 0
with open(out, "w") as o:
    o.write(f"# cycles {ncyc} period_ps {PERIOD_PS} window_ps {T}\n")
    for pin, n in drivers:
        if n not in val:
            miss += 1
            continue
        o.write(f"pin {pin} {tog[n]} {high[n] / T:.4f}\n")
    for n in sorted(inputs):
        if n in val:
            o.write(f"port {n} {tog[n]} {high[n] / T:.4f}\n")
print(f"drivers {len(drivers)}, without VCD net {miss}, input ports {len(inputs)}, cycles {ncyc}")
