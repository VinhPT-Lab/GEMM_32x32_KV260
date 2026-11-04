#!/usr/bin/env python3
"""vcd2act_ip.py
SUPERSEDED: keeps only the last name of each VCD id, so nets on the row / AXI boundary get no
activity (see data/superseded_alias_bug/README.txt); use vcd2act_phases.py / job_power.sh.
 <vcd> <GEMM_top.nl.v> <row.nl.v> <shell.nl.v> <out.txt>
IP version of tools/power/vcd2act.py: scopes are the IP top (flat core), the 32 rows and
the AXI shell (u_axi_shell, flat gate netlist; ICG GCLK pins are drivers too).
Per-net toggle count and time-at-1 from a net-level VCD (depth 1), mapped to the
driver pin of each net (std-cell outputs, SRAM dout) and to the core input ports. Output lines:
  pin|port <name> <toggles> <duty>     plus header '# cycles N period_ps P'
read_power_activities of OpenSTA 41a51eaf matches VCD names to pins only, so power.tcl sets these per pin."""
import re, sys, collections
vcd, core_v, row_v, shell_v, out = sys.argv[1:6]
TOP = "dut"; SHELL = "u_axi_shell"; ROWRE = re.compile(r"g_pe_row\[(\d+)\]\.u_row$")
OUTPINS = {"X", "Y", "Q", "Q_N", "GCLK", "HI", "LO"}
PERIOD_PS = 10000   # testbench clock (always #5); activity is per cycle, applied to the SDC clock

# ---- VCD
ids = collections.defaultdict(list)          # id -> [(scope, net)] per bit, MSB first for buses
scope = []; t0 = None; t = 0
with open(vcd) as f:
    for line in f:
        if line.startswith("$scope"):
            scope.append(line.split()[2].lstrip("\\")); continue
        if line.startswith("$upscope"):
            scope.pop(); continue
        if line.startswith("$var"):
            tok = line.split(); w = int(tok[2]); vid = tok[3]; rest = tok[4:-1]
            name = rest[0].lstrip("\\")
            sc = scope[-1]
            if sc == TOP: s = "core"
            elif sc == SHELL: s = "shell"
            else:
                m = ROWRE.search(sc); s = int(m.group(1)) if m else None
            if s is None: continue
            if len(rest) == 2 and ":" in rest[1]:
                hi, lo = map(int, rest[1][1:-1].split(":"))
                step = -1 if hi >= lo else 1
                bits = [(s, f"{name}[{b}]") for b in range(hi, lo + step, step)]
            else:
                bits = [(s, name)] if w == 1 else [(s, f"{name}[{b}]") for b in range(w - 1, -1, -1)]
            ids[vid] = bits; continue
        if line.startswith("$enddefinitions"): break
    nbits = sum(len(v) for v in ids.values())
    val = {}; last = {}; tog = collections.Counter(); high = collections.Counter()
    def setbits(vid, v, now):
        bits = ids.get(vid)
        if bits is None: return
        v = v.rjust(len(bits), v[0] if v[0] in "xz" else "0")
        for i, k in enumerate(bits):
            nv = v[i]; ov = val.get(k)
            if ov == nv: continue
            if ov == "1": high[k] += now - last[k]
            if ov in ("0", "1") and nv in ("0", "1"): tog[k] += 1
            val[k] = nv; last[k] = now
    for line in f:
        c = line[0]
        if c == "#":
            t = int(line[1:]); 
            if t0 is None: t0 = t
        elif c in "01xz":
            setbits(line[1:].strip(), c, t)
        elif c == "b":
            v, vid = line[1:].split(); setbits(vid, v, t)
    t1 = t
for k, v in val.items():
    if v == "1": high[k] += t1 - last[k]
T = t1 - t0
print(f"vcd: {len(ids)} ids, {nbits} bits, window {t0}..{t1} ps")

# ---- driver pins from the netlists
def cells(path):
    s = open(path).read()
    for m in re.finditer(r"^\s*(\w+)\s+(\\\S+|\S+)\s*\((.*?)\);", s, re.M | re.S):
        typ, inst, body = m.group(1), m.group(2).lstrip("\\"), m.group(3)
        if typ in ("module", "wire", "input", "output", "assign"): continue
        yield typ, inst, re.findall(r"\.(\w+)\(\s*(\{.*?\}|[^()]*?)\s*\)", body, re.S)
def nets_of(expr):
    expr = expr.strip()
    if expr.startswith("{"):
        return [e.strip().lstrip("\\").strip() for e in expr[1:-1].split(",")]
    return [expr.lstrip("\\").strip()]
drivers = []                                   # (pinpath, scope, net)
rowinst = {}
for typ, inst, pins in cells(core_v):
    if typ == "ProcessingElementRow":
        rowinst[int(ROWRE.search(inst).group(1))] = inst; continue
    for p, e in pins:
        if typ.startswith("sky130_sram") and p in ("dout0", "dout1"):
            for i, n in enumerate(nets_of(e)):
                drivers.append((f"{inst}/{p}[{31 - i}]", "core", n))
        elif typ.startswith("sky130_fd_sc") and p in OUTPINS:
            drivers.append((f"{inst}/{p}", "core", nets_of(e)[0]))
rowdrv = [(f"{inst}/{p}", nets_of(e)[0]) for typ, inst, pins in cells(row_v) if typ.startswith("sky130_fd_sc")
          for p, e in pins if p in OUTPINS]
for r, ri in rowinst.items():
    for pin, n in rowdrv:
        drivers.append((f"{ri}/{pin}", r, n))
for typ, inst, pins in cells(shell_v):
    if not typ.startswith("sky130_fd_sc"): continue
    for p, e in pins:
        if p in OUTPINS: drivers.append((f"u_axi_shell/{inst}/{p}", "shell", nets_of(e)[0]))
ports = sorted({k for k in val if k[0] == "core" and re.match(r"i_\w+", k[1])})   # top inputs (+ inputs only by name)
miss = 0; ncyc = round(T / PERIOD_PS)
with open(out, "w") as o:
    o.write(f"# cycles {ncyc} period_ps {PERIOD_PS} window_ps {T}\n")
    for pin, s, n in drivers:
        k = (s, n)
        if k not in val: miss += 1; continue
        o.write(f"pin {pin} {tog[k]} {high[k] / T:.4f}\n")
    for k in ports:
        o.write(f"port {k[1]} {tog[k]} {high[k] / T:.4f}\n")
print(f"drivers {len(drivers)}, without VCD net {miss}, rows {len(rowinst)}, ports {len(ports)}, cycles {ncyc}")
