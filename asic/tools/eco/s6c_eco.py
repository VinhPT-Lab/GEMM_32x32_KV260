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
# env: IN (def) GUIDE OUT (prefix) PLAN
import os, time, bisect
import odb, grt as GRT
from openroad import Design, Tech

P = os.environ['ECO_DIR']
HERE = os.environ.get('ECO_TOOLS') or os.path.dirname(os.path.abspath(__file__))
PDK = os.path.join(os.environ['PDK_ROOT'], 'sky130A')
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
tcl(f'read_liberty {PDK}/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib')  # swapMaster callback
tcl(f'read_def {IN}'); tcl('route_setup'); tcl(f'read_guides {os.environ["GUIDE"]}')
block = design.getBlock(); db = block.getDataBase(); dbu = block.getDbUnitsPerMicron()
say(f'read {IN} + guides')
tcl(f'ant_count {os.environ["OUT"]}.before')

def find_iterm(pin):
    i, p = pin.rsplit('/', 1)
    inst = block.findInst(esc(i)) or block.findInst(i)
    if inst is None: return None, None
    return inst, inst.findITerm(p)

plan = []
for l in open(os.environ['PLAN']):
    t = l.rstrip('\n').split('\t')
    if t[10] in ('RESIZE', 'BUFFER', 'SINKBUF'): plan.append(t)
# windows to clear: instance bbox (resize) or the pin location (buffers)
spots = []; skipped = []
for t in plan:
    inst, it = find_iterm(t[2])
    if it is None: skipped.append(t[2]); continue
    if t[10] == 'RESIZE':
        b = inst.getBBox(); spots.append((b.xMin(), b.yMin(), b.xMax(), b.yMax()))
    else:
        b = it.getBBox(); spots.append((b.xMin(), b.yMin(), b.xMax(), b.yMax()))
rows = {}
for o in block.getInsts():
    if mtype(o.getMaster()) == 'CORE_SPACER':
        ob = o.getBBox(); rows.setdefault(ob.yMin(), []).append((ob.xMin(), ob.xMax(), o))
for k in rows: rows[k].sort(key=lambda r: r[0])
ykeys = sorted(rows); w = int(WIN * dbu); kill = {}
for (x0, y0, x1, y1) in spots:
    x0 -= w; y0 -= w; x1 += w; y1 += w
    for yk in ykeys[bisect.bisect_left(ykeys, y0 - 2720):bisect.bisect_right(ykeys, y1)]:
        r = rows[yk]; i = bisect.bisect_left(r, (x0 - 5520,))
        while i < len(r) and r[i][0] <= x1:
            if r[i][1] >= x0: kill[r[i][2].getName()] = r[i][2]
            i += 1
for o in kill.values(): odb.dbInst.destroy(o)
say(f'removed {len(kill)} CORE SPACER instances (+-{WIN:g} um); plan rows {len(plan)}, not found {len(skipped)} {skipped[:5]}')

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

dirty = set(); moved = []; k = 0; cnt = {}
def new_buf(master_name, x, y):
    global k
    while block.findInst(f'eco_drv_{k}') is not None or block.findNet(f'eco_drv_{k}_net') is not None: k += 1
    b = odb.dbInst.create(block, db.findMaster(master_name), f'eco_drv_{k}')
    n = odb.dbNet.create(block, f'eco_drv_{k}_net')
    b.setOrient('R0'); b.setLocation(x, y); b.setPlacementStatus('PLACED')
    a = [it for it in b.getITerms() if it.isInputSignal()][0]
    xo = [it for it in b.getITerms() if it.isOutputSignal()][0]
    k += 1
    return b, n, a, xo
log = open(OUT + '.applied.tsv', 'w')
for t in plan:
    inst, it = find_iterm(t[2])
    if it is None: continue
    act, cell = t[10], t[11]
    if act == 'RESIZE':
        old = inst.getMaster().getName()
        assert inst.swapMaster(db.findMaster(cell)), (t[2], cell)
        inst.setPlacementStatus('PLACED'); moved.append(inst)
        for x in inst.getITerms():
            if x.getNet() is not None and not x.getNet().isSpecial(): dirty.add(x.getNet())
        log.write(f'{t[0]}\tRESIZE\t{inst.getName()}\t{old}->{cell}\n')
    elif act == 'BUFFER':
        net = it.getNet(); c = it.getBBox()
        b, n, a, xo = new_buf(cell, (c.xMin() + c.xMax()) // 2, (c.yMin() + c.yMax()) // 2)
        it.disconnect(); it.connect(n); a.connect(n); xo.connect(net)
        moved.append(b); dirty.add(net); dirty.add(n)
        log.write(f'{t[0]}\tBUFFER_{t[1]}\t{b.getName()}\t{cell}\n')
    elif act == 'SINKBUF':
        net = it.getNet(); c = it.getBBox(); cx, cy = (c.xMin() + c.xMax()) // 2, (c.yMin() + c.yMax()) // 2
        src = net; names = []
        for m in cell.split('+'):
            b, n, a, xo = new_buf(m, cx, cy)
            a.connect(src); xo.connect(n); src = n; moved.append(b); dirty.add(n); names.append(b.getName())
        it.disconnect(); it.connect(src); dirty.add(net)
        log.write(f'{t[0]}\tSINKBUF\t{"+".join(names)}\t{cell}\n')
    cnt[act + ('_' + t[1] if act == 'BUFFER' else '')] = cnt.get(act + ('_' + t[1] if act == 'BUFFER' else ''), 0) + 1
log.close()
site = block.getRows()[0].getSite()
design.getOpendp().detailedPlacement(int(design.micronToDBU(1000) / site.getWidth()), int(design.micronToDBU(500) / site.getHeight()))
say(f'applied {cnt}; legalized {len(moved)} instances')
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
