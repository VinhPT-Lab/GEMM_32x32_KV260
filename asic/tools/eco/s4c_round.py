# 4c, one antenna ECO round (OpenROAD dcf3613, openroad -python), local filler removal:
#  1. targets: gates of every antenna violation at ratio margin MARGIN (the same
#     AntennaChecker::getAntennaViolations call repair_antennas makes); nets whose
#     diode_count_per_gate is 0 cannot be fixed by diodes (GRT-0243) - listed apart
#  2. remove every CORE SPACER instance (fill, fd/ef decap) whose bbox meets a
#     +-WIN um window around a target instance (FULL=1: remove_fillers, all of them)
#  3. repair_antennas (-iterations 1, -ratio_margin MARGIN, -allow_congestion)
#     -> detailed_route (INCR) -> filler_placement with the OL1 cell list
#  4. checks: empty row sites before/after, antenna count; write ODB + DEF
# env: IN (def|odb) OUT (prefix under the probe) GUIDE (for a DEF) WIN MARGIN FULL DRY
# exit 3: repair_antennas / detailed placement failed (caller retries)
import os, sys, time, bisect
import odb
from openroad import Design, Tech

P = os.environ['ECO_DIR']
HERE = os.environ.get('ECO_TOOLS') or os.path.dirname(os.path.abspath(__file__))
PDK = os.path.join(os.environ['PDK_ROOT'], 'sky130A')
IN = os.environ['IN']; OUT = os.path.join(P, os.environ['OUT'])
WIN = float(os.environ.get('WIN', '15')); MARGIN = float(os.environ.get('MARGIN', '10'))
FULL = os.environ.get('FULL', '0') == '1'; DRY = os.environ.get('DRY', '0') == '1'
os.makedirs(os.path.dirname(OUT), exist_ok=True)
FILL_LIST = ('sky130_ef_sc_hd__decap_12 sky130_fd_sc_hd__decap_8 sky130_fd_sc_hd__decap_6 '
             'sky130_fd_sc_hd__decap_4 sky130_fd_sc_hd__decap_3 sky130_fd_sc_hd__fill*')   # OL1: "$DECAP_CELL $FILL_CELL"
t0 = time.time()
def hwm():
    for l in open('/proc/self/status'):
        if l.startswith('VmHWM'): return int(l.split()[1]) // 1024
def say(msg):
    print(f'PROBE {msg}; {time.time() - t0:.0f} s, peak {hwm()} MB', flush=True)

tech = Tech(); design = Design(tech)
tcl = design.evalTclString
tcl(f'source {HERE}/common.tcl')
tcl(f'read_db {IN}' if IN.endswith('.odb') else f'read_def {IN}')
tcl('route_setup')
if os.environ.get("GUIDE"):
    tcl(f'read_guides {os.environ["GUIDE"]}')
block = design.getBlock(); dbu = block.getDbUnitsPerMicron()
say(f'read {IN}')
tcl(f'ant_count {os.environ["OUT"]}.before')

def mtype(m):
    t = m.getType()
    return t if isinstance(t, str) else t.getString()
def is_spacer(inst):
    return mtype(inst.getMaster()) == 'CORE_SPACER'
print('PROBE master types: decap_12', mtype(block.getDataBase().findMaster('sky130_ef_sc_hd__decap_12')),
      'fill_1', mtype(block.getDataBase().findMaster('sky130_fd_sc_hd__fill_1')),
      'tap', mtype(block.getDataBase().findMaster('sky130_fd_sc_hd__tapvpwrvgnd_1')),
      'diode', mtype(block.getDataBase().findMaster('sky130_fd_sc_hd__diode_2')), flush=True)

def row_gaps():
    """empty row sites: total row length minus the widths of the core cells placed in rows"""
    total = sum(r.getSiteCount() * r.getSite().getWidth() for r in block.getRows())
    used = 0
    for inst in block.getInsts():
        m = inst.getMaster()
        if mtype(m).startswith('CORE') and inst.isPlaced():
            used += m.getWidth()
    return (total - used) // block.getRows()[0].getSite().getWidth()

# 1. targets
ac = design.getAntennaChecker(); ac.initAntennaRules()
diode = block.getDataBase().findMaster('sky130_fd_sc_hd__diode_2')
dmterm = [m for m in diode.getMTerms() if m.getSigType() not in ('POWER', 'GROUND')][0]
# repair_antennas uses AntennaChecker::getAntennaViolations(net, diode, margin); its
# Violation.gates (std::vector<dbITerm*>) is not wrapped for Python, so the gates
# are taken from the verbose check_antennas report (margin 0) with the same test
# as checkPAR / checkPSR: calculated > required * (1 - margin); CAR / CSR without
# margin (checkCAR / checkCSR take none). Diode pins are not gates.
import re
targets = {}; tnets = set(); net = pin = None; is_diode = False; layer = None
rep = os.path.join(P, os.environ['OUT'] + '.before.ant.rpt')
calc = None
for line in open(rep):
    s_ = line.strip()
    if line.startswith('Net: '): net = s_.split()[1]; continue
    if s_.startswith('Pin:'):
        t_ = s_.split(); pin = t_[1]; is_diode = 'diode' in t_[2]; continue
    if s_.startswith('Layer:'): layer = s_.split()[1]; continue
    m = re.match(r'(Partial|Cumulative) area ratio:\s+(\S+)', s_)
    if m: calc = float(m.group(2)); kind = m.group(1); continue
    m = re.match(r'Required ratio:\s+(\S+) \((Gate area|Side area|Cumulative area|Cumulative side area)\)', s_)
    if m and not is_diode:
        req = float(m.group(1))
        if req == 0: continue
        lim = req * (1 - MARGIN / 100) if m.group(2) in ('Gate area', 'Side area') else req
        if calc > lim:
            inst = block.findInst(pin.rsplit('/', 1)[0])
            if inst is not None:
                targets.setdefault(inst.getName(), inst); tnets.add(net)
nofix = []; nviol = 0; ndiode = 0
for netn in sorted(tnets):
    n_ = block.findNet(netn)
    v = ac.getAntennaViolations(n_, dmterm, MARGIN) if n_ is not None else []
    if len(v): nviol += 1
    for viol in v:
        if viol.diode_count_per_gate <= 0:
            nofix.append((netn, viol.routing_level, 'diode_count_per_gate %d' % viol.diode_count_per_gate))
        else:
            ndiode += viol.diode_count_per_gate
with open(OUT + '.targets.tsv', 'w') as f:
    for n in sorted(targets): f.write(n + '\n')
with open(OUT + '.nofix.tsv', 'w') as f:
    for r in nofix: f.write('%s\t%d\t%s\n' % r)
say(f'targets at margin {MARGIN:g} %: {len(tnets)} nets from the report ({nviol} confirmed by getAntennaViolations), {len(targets)} gate instances, diodes per gate summed {ndiode}; '
    f'nets not fixable by diodes: {len(set(r[0] for r in nofix))}')

# 2. remove fillers
gaps0 = row_gaps()
dp = design.getOpendp()
if FULL:
    n_sp = sum(1 for i in block.getInsts() if is_spacer(i))
    if not DRY: dp.removeFillers()
    removed = n_sp
else:
    rows = {}
    for inst in block.getInsts():
        if is_spacer(inst):
            b = inst.getBBox()
            rows.setdefault(b.yMin(), []).append((b.xMin(), b.xMax(), inst))
    for k in rows: rows[k].sort(key=lambda t: t[0])
    ykeys = sorted(rows)
    maxw = 12 * 460   # widest spacer (decap_12)
    w = int(WIN * dbu); kill = {}
    for inst in targets.values():
        b = inst.getBBox()
        x0, y0, x1, y1 = b.xMin() - w, b.yMin() - w, b.xMax() + w, b.yMax() + w
        for yk in ykeys[bisect.bisect_left(ykeys, y0 - 2720):bisect.bisect_right(ykeys, y1)]:
            r = rows[yk]
            if yk + 2720 < y0: continue
            i = bisect.bisect_left(r, (x0 - maxw,))
            while i < len(r) and r[i][0] <= x1:
                if r[i][1] >= x0: kill[r[i][2].getName()] = r[i][2]
                i += 1
    removed = len(kill)
    if not DRY:
        for inst in kill.values(): odb.dbInst.destroy(inst)
say(f'{"would remove" if DRY else "removed"} {removed} CORE SPACER instances ({"all" if FULL else f"+-{WIN:g} um windows"}); '
    f'empty sites before removal {gaps0}')
if DRY:
    sys.exit(0)

# 3. ECO
n0 = len(block.getInsts())
if os.environ.get('GRTDBG'): tcl('set_debug_level GRT repair_antennas ' + os.environ['GRTDBG'])
# repair_antennas names new diodes ANTENNA_<i> from the first free index on and never
# skips a taken name, so after diodes were removed (clock nets, step 7B) dbInst::create
# returns null on a clash and setDiodeLoc segfaults. The old diodes get a temporary
# name meanwhile; the new ones are then numbered after the largest old index.
old_dio = {}
for i in block.getInsts():
    m_ = re.match(r'^ANTENNA_(\d+)$', i.getName())
    if m_: old_dio[int(m_.group(1))] = i
for k_, i in old_dio.items(): assert i.rename(f'OLDANT_TMP_{k_}')
r = tcl(f'if {{[catch {{repair_antennas sky130_fd_sc_hd__diode_2 -iterations 1 -ratio_margin {MARGIN:g} -allow_congestion}} e]}} '
        f'{{ puts "PROBE repair_antennas FAILED: $e"; exit 3 }}')
nxt = max(old_dio) + 1 if old_dio else 1
new_dio = sorted((int(re.match(r'^ANTENNA_(\d+)$', i.getName()).group(1)), i) for i in block.getInsts() if re.match(r'^ANTENNA_\d+$', i.getName()))
for k_, i in new_dio:
    while block.findInst(f'ANTENNA_{nxt}') is not None: nxt += 1
    assert i.rename(f'ANTENNA_{nxt}'); nxt += 1
for k_, i in old_dio.items(): assert i.rename(f'ANTENNA_{k_}')
say(f'diode names: {len(old_dio)} old kept, {len(new_dio)} new numbered after {max(old_dio) if old_dio else 0}')
say(f'repair_antennas: +{len(block.getInsts()) - n0} instances')
tcl(f'detailed_route -output_drc {OUT}.drt.drc -droute_end_iter 64 -or_seed 42 -verbose 1')
say('detailed_route done')
gaps1 = row_gaps()
tcl(f'filler_placement "{FILL_LIST}"')
gaps2 = row_gaps()
say(f'filler_placement: empty sites after DRT {gaps1}, after fill {gaps2} (before ECO {gaps0})')
# power pins of the new diodes and fillers, as set_global_connections of OL1
# (STD_CELL_POWER_PINS VPWR VPB -> vccd1, STD_CELL_GROUND_PINS VGND VNB -> vssd1)
for pin, net, kind in (('VPWR', 'vccd1', 'power'), ('VPB', 'vccd1', 'power'), ('VGND', 'vssd1', 'ground'), ('VNB', 'vssd1', 'ground')):
    tcl(f'add_global_connection -net {net} -inst_pattern .* -pin_pattern ^{pin}$ -{kind}')
tcl('global_connect')
unp = sum(1 for i in block.getInsts() if mtype(i.getMaster()).startswith('CORE')
          for it in i.getITerms() if it.getSigType() in ('POWER', 'GROUND') and it.getNet() is None)
say(f'global_connect: core power/ground pins left unconnected {unp}')
tcl(f'ant_count {os.environ["OUT"]}.after')
tcl(f'write_def {OUT}.def')   # no ODB: this version writes ODBs that do not read back after net edits
say(f'round {os.environ["OUT"]} written')
