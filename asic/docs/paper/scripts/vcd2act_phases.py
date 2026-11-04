#!/usr/bin/env python3
"""vcd2act_phases.py <vcd> <gls.log> <GEMM_top.nl.v> <row.nl.v> <shell.nl.v> <out prefix>
Whole-job version of vcd2act_ip.py. The VCD covers one job (vcd_job_ip.py window); every
testbench cycle of it gets a phase from phases.py (FSM_STATE + testbench lines of the same
simulation). Toggles of each net are counted per phase; time-at-1 (duty) is taken over the
whole job and used for every phase (it only weights state-dependent leakage / internal
power). Outputs:
  <prefix>.job.act, <prefix>.<phase>.act    pin <name> <toggles> <duty>, header '# cycles N'
  <prefix>.sram.csv    per SRAM macro and phase: cycles with csb0 low (port 0 selected),
                       of those with web0 low (write), cycles with csb1 low (port 1 read);
                       sampled at the end of each cycle, i.e. what the macro latches
  <prefix>.phases.csv  cycles per phase
Interval k of the dump = testbench cycle c0+1+k (vcd_job_ip.py convention).
VCD ids shared by several names (aliases of one net across a port) update every name;
vcd2act_ip.py (the 400-cycle windows) kept only the last name of each id, so the nets on
the row / AXI boundary had no activity there."""
import re, sys, collections, csv
from array import array
sys.path.insert(0, __import__("os").path.dirname(__file__))
from phases import split, PH
vcd, log, core_v, row_v, shell_v, out = sys.argv[1:7]
TOP = "dut"; SHELL = "u_axi_shell"; ROWRE = re.compile(r"g_pe_row\[(\d+)\]\.u_row$")
OUTPINS = {"X", "Y", "Q", "Q_N", "GCLK", "HI", "LO"}
PERIOD = 10000; HALF = 5000          # testbench clock (always #5), ps

S, E, lab, info = split(log)
ncyc = len(lab); NP = len(PH) + 1     # phases + whole job (index len(PH))
phidx = array('b', [PH.index(p) for p in lab])

# ---- SRAM select pins (top-level nets)
sram = {}                              # inst -> {pin: net}
s = open(core_v).read()
for m in re.finditer(r"^\s*sky130_sram_\w+\s+(\\\S+|\S+)\s*\((.*?)\);", s, re.M | re.S):
    pins = dict(re.findall(r"\.(\w+)\(\s*\\?([^()\s]*)\s*\)", m.group(2)))
    sram[m.group(1).lstrip("\\")] = {p: pins[p] for p in ("csb0", "web0", "csb1")}
del s
special = {("core", n) for d in sram.values() for n in d.values()}

# ---- VCD header
ids = {}; key = []; scope = []
f = open(vcd)
for line in f:
    if line.startswith("$scope"): scope.append(line.split()[2].lstrip("\\")); continue
    if line.startswith("$upscope"): scope.pop(); continue
    if line.startswith("$var"):
        tok = line.split(); w = int(tok[2]); vid = tok[3]; rest = tok[4:-1]
        name = rest[0].lstrip("\\"); sc = scope[-1]
        if sc == TOP: sd = "core"
        elif sc == SHELL: sd = "shell"
        else:
            mm = ROWRE.search(sc); sd = int(mm.group(1)) if mm else None
        if sd is None: continue
        if len(rest) == 2 and ":" in rest[1]:
            hi, lo = map(int, rest[1][1:-1].split(":")); step = -1 if hi >= lo else 1
            names = [f"{name}[{b}]" for b in range(hi, lo + step, step)]
        else:
            names = [name] if w == 1 else [f"{name}[{b}]" for b in range(w - 1, -1, -1)]
        idx = []
        for n in names: idx.append(len(key)); key.append((sd, n))
        # iverilog gives one VCD id to all names of one net (a top net and the row / AXI
        # port it connects to, assign aliases): every alias must follow the value
        ids.setdefault(vid, []).append(idx); continue
    if line.startswith("$enddefinitions"): break
nb = len(key)
kidx = {k: i for i, k in enumerate(key)}
val = bytearray(b"x" * nb); last = array('q', [0]) * nb; high = array('q', [0]) * nb
tog = [array('I', [0]) * nb for _ in range(NP)]
spec = sorted(kidx[k] for k in special if k in kidx)
samp = {i: bytearray(ncyc) for i in spec}           # value at the end of each cycle (ord)
t0 = None; p0 = None; pend = None; curk = -1; ph = -1
def advance(k):
    """sample the select pins for cycles curk .. k-1 (values before this timestamp)"""
    global curk
    for kk in range(max(curk, 0), min(k, ncyc)):
        for i in spec: samp[i][kk] = val[i]
    curk = k
def apply(idx, v, now):
    if len(v) < len(idx): v = v.rjust(len(idx), v[0] if v[0] in "xz" else "0")
    for j, i in enumerate(idx):
        nv = ord(v[j]); ov = val[i]
        if ov == nv: continue
        if ov == 49:                                      # '1'
            a = last[i] if last[i] > p0 else p0
            if now > a: high[i] += now - a
        if ph >= 0 and ov in (48, 49) and nv in (48, 49):
            tog[ph][i] += 1; tog[NP - 1][i] += 1
        val[i] = nv; last[i] = now
done = False
for line in f:
    c = line[0]
    if c == "#":
        t = int(line[1:])
        if t0 is None: t0 = t; p0 = t0 + HALF; pend = p0 + ncyc * PERIOD
        if t >= pend: done = True; break
        k = (t - p0) // PERIOD if t >= p0 else -1
        if k != curk: advance(k)
        ph = phidx[k] if k >= 0 else -1
    elif c in "01xz":
        for idx in ids.get(line[1:].strip(), ()): apply(idx, c, t)
    elif c == "b":
        v, vid = line[1:].split()
        for idx in ids.get(vid, ()): apply(idx, v, t)
f.close()
if not done: sys.exit(f"VCD ends at {t} ps before the job end {pend} ps")
advance(ncyc + 1)
for i in range(nb):
    if val[i] == 49:
        a = last[i] if last[i] > p0 else p0; high[i] += pend - a
T = pend - p0
print(f"vcd: {len(ids)} ids ({sum(len(v) for v in ids.values())} names), {nb} bits, job cycles {ncyc} ({S}..{E}), window {p0}..{pend} ps")

# ---- driver pins (as vcd2act_ip.py)
def cells(path):
    s = open(path).read()
    for m in re.finditer(r"^\s*(\w+)\s+(\\\S+|\S+)\s*\((.*?)\);", s, re.M | re.S):
        typ, inst, body = m.group(1), m.group(2).lstrip("\\"), m.group(3)
        if typ in ("module", "wire", "input", "output", "assign"): continue
        yield typ, inst, re.findall(r"\.(\w+)\(\s*(\{.*?\}|[^()]*?)\s*\)", body, re.S)
def nets_of(expr):
    expr = expr.strip()
    if expr.startswith("{"): return [e.strip().lstrip("\\").strip() for e in expr[1:-1].split(",")]
    return [expr.lstrip("\\").strip()]
drivers = []; rowinst = {}
for typ, inst, pins in cells(core_v):
    if typ == "ProcessingElementRow":
        rowinst[int(ROWRE.search(inst).group(1))] = inst; continue
    for p, e in pins:
        if typ.startswith("sky130_sram") and p in ("dout0", "dout1"):
            for i, n in enumerate(nets_of(e)): drivers.append((f"{inst}/{p}[{31 - i}]", "core", n))
        elif typ.startswith("sky130_fd_sc") and p in OUTPINS:
            drivers.append((f"{inst}/{p}", "core", nets_of(e)[0]))
rowdrv = [(f"{inst}/{p}", nets_of(e)[0]) for typ, inst, pins in cells(row_v) if typ.startswith("sky130_fd_sc")
          for p, e in pins if p in OUTPINS]
for r, ri in rowinst.items():
    for pin, n in rowdrv: drivers.append((f"{ri}/{pin}", r, n))
for typ, inst, pins in cells(shell_v):
    if not typ.startswith("sky130_fd_sc"): continue
    for p, e in pins:
        if p in OUTPINS: drivers.append((f"u_axi_shell/{inst}/{p}", "shell", nets_of(e)[0]))
pidx = [kidx.get((sd, n)) for _, sd, n in drivers]
miss = sum(1 for i in pidx if i is None)
cnt = collections.Counter(lab)
for q, name in enumerate(list(PH) + ["job"]):
    nc = ncyc if name == "job" else cnt[name]
    if nc == 0: continue
    with open(f"{out}.{name}.act", "w") as o:
        o.write(f"# cycles {nc} period_ps {PERIOD} phase {name}\n")
        for (pin, _, _), i in zip(drivers, pidx):
            if i is None: continue
            o.write(f"pin {pin} {tog[q][i]} {high[i] / T:.4f}\n")
print(f"drivers {len(drivers)}, without VCD net {miss}, rows {len(rowinst)}")
with open(f"{out}.phases.csv", "w", newline="") as o:
    w = csv.writer(o); w.writerow(["phase", "cycles"])
    for p in PH: w.writerow([p, cnt[p]])
    w.writerow(["job", ncyc])
# ---- SRAM selects per phase
with open(f"{out}.sram.csv", "w", newline="") as o:
    w = csv.writer(o)
    w.writerow(["inst", "buffer", "phase", "cycles", "csb0_low", "csb0_low_web0_low", "csb1_low"])
    for inst, d in sorted(sram.items()):
        buf = re.search(r"\.(u_\w+?_mem|u_\w+_buffer)\.", inst)
        buf = buf.group(1) if buf else inst.split(".")[1]
        a, b, c1 = (kidx.get(("core", d[p])) for p in ("csb0", "web0", "csb1"))
        for q, name in enumerate(list(PH) + ["job"]):
            ks = range(ncyc) if name == "job" else [k for k in range(ncyc) if phidx[k] == q]
            n0 = sum(1 for k in ks if samp[a][k] == 48) if a is not None else -1
            nw = sum(1 for k in ks if samp[a][k] == 48 and samp[b][k] == 48) if a is not None and b is not None else -1
            n1 = sum(1 for k in ks if samp[c1][k] == 48) if c1 is not None else -1
            w.writerow([inst, buf, name, len(ks), n0, nw, n1])
print("phases", dict(cnt), "sram", len(sram))
