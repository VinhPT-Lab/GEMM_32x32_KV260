# 7A: replay on the routed DEF the topology that repair_design made in memory
# (s7_long_try.py: TOPO = <prefix>.topo.tsv, OLDCHG = <prefix>.oldchg.tsv), then as 6c.
# TOPO rows: INST name master x y (new instances), NET name pins (final pin list of
# every listed net and every new net), DEL name (a diode to remove). OLDCHG rows: old instances whose master changed.
# The listed nets lose their wires (their pin sets change) and are routed again.
# Original header of 6c, the placement / route part is unchanged:
# 6c: apply a DRV / hold ECO plan (OpenROAD dcf3613, openroad -python).
# PLAN rows (tab separated, from drv_pick.py / hold_plan): net kind driver_pin ... action cell
#   RESIZE  swap the master of the driver instance to <cell> (same pin names)
#   BUFFER  driver side: the driver pin moves to a new net that drives only the
#           buffer; the buffer drives the whole old net. Placed at the driver pin
#           (for an SRAM: at its dout pin), not at the centre of the net.
#   SINKBUF sink side (hold): driver_pin column = the sink pin; the sink pin moves
#           to a new net driven by the buffer, the buffer input stays on the old net
#           (as Odb.InsertECOBuffers with a sink target), placed at the sink pin.
#           A cell "a+b" puts two buffers in series, a first (a: e.g. dlygate),
#           b driving the sink pin.
# Then, as 6a: remove CORE SPACER cells meeting +-15 um around every changed or new
# instance, lock every other instance, legalize, incremental global route of the
# touched nets, detailed_route (INCR), filler_placement (OL1 list), global connect
# (OL1), antenna check, write DEF (the ODB this version writes after creating nets
# does not read back, see 6a).
# env: IN (def) GUIDE OUT (prefix) TOPO OLDCHG
import os, time, bisect
import odb, grt as GRT
from openroad import Design, Tech

P = os.environ['ECO_DIR']
HERE = os.environ.get('ECO_TOOLS') or os.path.dirname(os.path.abspath(__file__))
IN = os.environ['IN']; OUT = os.path.join(P, os.environ['OUT']); WIN = 15.0
os.makedirs(os.path.dirname(OUT), exist_ok=True)
FILL_LIST = ('sky130_ef_sc_hd__decap_12 sky130_fd_sc_hd__decap_8 sky130_fd_sc_hd__decap_6 '
             'sky130_fd_sc_hd__decap_4 sky130_fd_sc_hd__decap_3 sky130_fd_sc_hd__fill*')
t0 = time.time()
def hwm():
    for l in open('/proc/self/status'):
        if l.startswith('VmHWM'): return int(l.split()[1]) // 1024
def say(msg): print(f'PROBE {msg}; {time.time() - t0:.0f} s, peak {hwm()} MB', flush=True)
def mtype(m):
    t = m.getType(); return t if isinstance(t, str) else t.getString()
def esc(name):   # STA names -> DEF/ODB names (escaped brackets in the instance part)
    return name.replace('[', '\\[').replace(']', '\\]')

tech = Tech(); design = Design(tech); tcl = design.evalTclString
tcl(f'source {HERE}/common.tcl')
tcl(f"read_liberty {os.environ['PDK_ROOT']}/sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib")  # swapMaster callback
tcl(f'read_def {IN}'); tcl('route_setup'); tcl(f'read_guides {os.environ["GUIDE"]}')
block = design.getBlock(); db = block.getDataBase(); dbu = block.getDbUnitsPerMicron()
say(f'read {IN} + guides')
tcl(f'ant_count {os.environ["OUT"]}.before')

def find_iterm(pin):
    i, p = pin.rsplit('/', 1)
    inst = block.findInst(esc(i)) or block.findInst(i)
    if inst is None: return None, None
    return inst, inst.findITerm(p)


topo_i = []; topo_n = {}; topo_d = []
for l in open(os.environ['TOPO']):
    t = l.rstrip('\n').split('\t')
    if t[0] == 'INST': topo_i.append((t[1], t[2], int(t[3]), int(t[4])))
    elif t[0] == 'DEL': topo_d.append(t[1])
    else: topo_n[t[1]] = t[2].split() if len(t) > 2 and t[2] else []
# DEL rows: instances to remove (antenna diodes of the clock nets being split); only
# diodes are allowed here
for nm in topo_d:
    inst = block.findInst(esc(nm)) or block.findInst(nm)
    assert inst is not None and 'diode' in inst.getMaster().getName(), nm
    odb.dbInst.destroy(inst)
say(f'removed {len(topo_d)} diode instances (DEL rows)')
resz = [l.rstrip('\n').split('\t')[:3] for l in open(os.environ['OLDCHG']) if l.strip()]
new_names = {t[0] for t in topo_i}
resz = [r for r in resz if r[0] not in new_names and r[1] != r[2]]
spots = []
for nm, m, x, y in topo_i: spots.append((x, y, x + db.findMaster(m).getWidth(), y + db.findMaster(m).getHeight()))
for nm, o, m in resz:
    b = (block.findInst(esc(nm)) or block.findInst(nm)).getBBox(); spots.append((b.xMin(), b.yMin(), b.xMax(), b.yMax()))
rows = {}
for o in block.getInsts():
    if mtype(o.getMaster()) == 'CORE_SPACER':
        ob = o.getBBox(); rows.setdefault(ob.yMin(), []).append((ob.xMin(), ob.xMax(), o))
for k in rows: rows[k].sort(key=lambda r: r[0])
ykeys = sorted(rows); w = int(float(os.environ.get('WIN', WIN)) * dbu); kill = {}
for (x0, y0, x1, y1) in spots:
    x0 -= w; y0 -= w; x1 += w; y1 += w
    for yk in ykeys[bisect.bisect_left(ykeys, y0 - 2720):bisect.bisect_right(ykeys, y1)]:
        r = rows[yk]; i = bisect.bisect_left(r, (x0 - 5520,))
        while i < len(r) and r[i][0] <= x1:
            if r[i][1] >= x0: kill[r[i][2].getName()] = r[i][2]
            i += 1
for o in kill.values(): odb.dbInst.destroy(o)
say(f'removed {len(kill)} CORE SPACER instances (+-{os.environ.get("WIN", WIN)} um); new {len(topo_i)}, resized {len(resz)}')

locked = []
for i in block.getInsts():
    if i.getPlacementStatus() != 'LOCKED':
        locked.append((i, i.getPlacementStatus())); i.setPlacementStatus('LOCKED')
g = design.getGlobalRouter()
lv = lambda n: db.getTech().findLayer(n).getRoutingLevel()
g.setAllowCongestion(True)
g.setMinLayerForClock(lv('met3')); g.setMaxLayerForClock(lv('met5'))
g.initFastRoute(lv('met1'), lv('met5'))
grt_inc = GRT.IncrementalGRoute(g, block)

moved = []; dirty = set(); log = open(OUT + '.applied.tsv', 'w')
for nm, o, m in resz:
    inst = block.findInst(esc(nm)) or block.findInst(nm)
    assert inst.getMaster().getName() == o, (nm, o)
    assert inst.swapMaster(db.findMaster(m)), (nm, m)
    inst.setPlacementStatus('PLACED'); moved.append(inst)
    for x in inst.getITerms():
        if x.getNet() is not None and not x.getNet().isSpecial(): dirty.add(x.getNet())
    log.write(f'RESIZE\t{nm}\t{o}->{m}\n')
for nm, m, x, y in topo_i:
    assert block.findInst(nm) is None, nm
    b = odb.dbInst.create(block, db.findMaster(m), nm)
    b.setOrient('R0'); b.setLocation(x, y); b.setPlacementStatus('PLACED'); moved.append(b)
    log.write(f'NEW\t{nm}\t{m}\t{x}\t{y}\n')
for n in topo_n:
    net = block.findNet(esc(n)) or block.findNet(n)
    if net is None: net = odb.dbNet.create(block, n); log.write(f'NEWNET\t{n}\n')
    elif net.getWire() is not None: odb.dbWire.destroy(net.getWire())
for n, pins in topo_n.items():
    net = block.findNet(esc(n)) or block.findNet(n)
    for p in pins:
        i, pin = p.rsplit('/', 1)
        if i == 'PIN': continue
        inst = block.findInst(esc(i)) or block.findInst(i)
        it = inst.findITerm(pin)
        if it.getNet() is not None and it.getNet().getName() != net.getName():
            dirty.add(it.getNet()); it.disconnect()
        if it.getNet() is None: it.connect(net)
    dirty.add(net)
# every replayed net must now carry exactly its pin list
bad = 0
for n, pins in topo_n.items():
    net = block.findNet(esc(n)) or block.findNet(n)
    have = sorted([f'{it.getInst().getName()}/{it.getMTerm().getName()}' for it in net.getITerms()] + [f'PIN/{b.getName()}' for b in net.getBTerms()])
    if have != sorted(pins): bad += 1; log.write(f'MISMATCH\t{n}\n')
log.close()
assert bad == 0, f'{bad} nets do not match the topology'
say(f'topology replayed: {len(topo_n)} nets match; dirty nets {len(dirty)}')
site = block.getRows()[0].getSite()
design.getOpendp().detailedPlacement(int(design.micronToDBU(1000) / site.getWidth()), int(design.micronToDBU(500) / site.getHeight()))
say(f'legalized {len(moved)} instances')
for n in dirty: g.addDirtyNet(n)
grt_inc.updateRoutes(True)
for i, st in locked:
    if i.getPlacementStatus() == 'LOCKED': i.setPlacementStatus(st)
say(f'incremental global route of {len(dirty)} nets')
tcl(f'detailed_route -output_drc {OUT}.drt.drc -droute_end_iter 64 -or_seed 42 -verbose 1')
say('detailed_route done')
tcl(f'filler_placement "{FILL_LIST}"')
total = sum(r.getSiteCount() * r.getSite().getWidth() for r in block.getRows())
used = sum(i.getMaster().getWidth() for i in block.getInsts() if mtype(i.getMaster()).startswith('CORE') and i.isPlaced())
say(f'filler_placement: empty sites {(total - used) // site.getWidth()}')
for pin, n, kind in (('VPWR', 'vccd1', 'power'), ('VPB', 'vccd1', 'power'), ('VGND', 'vssd1', 'ground'), ('VNB', 'vssd1', 'ground')):
    tcl(f'add_global_connection -net {n} -inst_pattern .* -pin_pattern ^{pin}$ -{kind}')
tcl('global_connect')
unp = sum(1 for i in block.getInsts() if mtype(i.getMaster()).startswith('CORE')
          for it in i.getITerms() if it.getSigType() in ('POWER', 'GROUND') and it.getNet() is None)
say(f'global_connect: core power/ground pins left unconnected {unp}')
tcl(f'ant_count {os.environ["OUT"]}.after')
tcl(f'write_def {OUT}.def')
say(f'{os.environ["OUT"]} written')
