# 6a: antenna fix by resizing the receiving cell (OpenROAD dcf3613, openroad -python).
# For each SWAP (inst:master): remove CORE SPACER cells meeting a +-15 um window
# around the instance, swap its master in place (same pin names), legalize with
# every other instance locked (only the swapped cells move), mark every signal
# net of the swapped cells dirty and update the global route incrementally
# (as Odb.InsertECOBuffers), detailed_route (INCR), filler_placement with the OL1
# list, global connect as OL1, antenna check, write ODB + DEF.
# env: IN (odb) OUT (prefix under the probe) SWAP ("inst:master inst:master")
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

tech = Tech(); design = Design(tech); tcl = design.evalTclString
tcl(f'source {HERE}/common.tcl')
tcl(f'read_db {IN}'); tcl('route_setup')
# dbSta's swapMaster callback compares the liberty cells of the old and new master
tcl(f'read_liberty {PDK}/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib')
block = design.getBlock(); db = block.getDataBase(); dbu = block.getDbUnitsPerMicron()
say(f'read {IN}')
tcl(f'ant_count {os.environ["OUT"]}.before')

swaps = [(s.split(':')[0], s.split(':')[1]) for s in os.environ['SWAP'].split()]
targets = []
for iname, mname in swaps:
    inst = block.findInst(iname); master = db.findMaster(mname)
    assert inst is not None and master is not None, (iname, mname)
    old = inst.getMaster()
    assert sorted(m.getName() for m in old.getMTerms()) == sorted(m.getName() for m in master.getMTerms()), 'pin names differ'
    targets.append((inst, master))

# remove fillers around the targets
w = int(WIN * dbu); kill = {}
for inst, _ in targets:
    b = inst.getBBox(); x0, y0, x1, y1 = b.xMin() - w, b.yMin() - w, b.xMax() + w, b.yMax() + w
    for o in block.getInsts():
        if mtype(o.getMaster()) != 'CORE_SPACER': continue
        ob = o.getBBox()
        if ob.xMax() >= x0 and ob.xMin() <= x1 and ob.yMax() >= y0 and ob.yMin() <= y1: kill[o.getName()] = o
for o in kill.values(): odb.dbInst.destroy(o)
say(f'removed {len(kill)} CORE SPACER instances (+-{WIN:g} um windows)')

# lock everything (as eco_buffer.py / eco_diode.py), keep the previous status
locked = []
for inst in block.getInsts():
    if inst.getPlacementStatus() != 'LOCKED':
        locked.append((inst, inst.getPlacementStatus())); inst.setPlacementStatus('LOCKED')
g = design.getGlobalRouter()
# as _grt_setup of LibreLane's odbpy reader (layers / adjustments already set by
# route_setup): allow congestion, so the incremental route never pulls in and
# rips up the nets crossing congested GCells, then init FastRoute
lv = lambda n: tech.getDB().getTech().findLayer(n).getRoutingLevel()
g.setAllowCongestion(True)
g.setMinLayerForClock(lv('met3')); g.setMaxLayerForClock(lv('met5'))
g.initFastRoute(lv('met1'), lv('met5'))
grt_inc = GRT.IncrementalGRoute(g, block)

# swap, unlock only the swapped cells, legalize
dirty = set()
for inst, master in targets:
    before = (inst.getMaster().getName(), inst.getLocation(), inst.getOrient())
    assert inst.swapMaster(master), 'swapMaster failed'
    inst.setPlacementStatus('PLACED')
    for it in inst.getITerms():
        n = it.getNet()
        if n is not None and not n.isSpecial(): dirty.add(n)
    print(f'PROBE swap {inst.getName()}: {before[0]} -> {master.getName()} at {before[1]} {before[2]}', flush=True)
site = block.getRows()[0].getSite()
design.getOpendp().detailedPlacement(int(design.micronToDBU(1000) / site.getWidth()), int(design.micronToDBU(500) / site.getHeight()))
for inst, master in targets:
    print(f'PROBE legalized {inst.getName()} {master.getName()} at {inst.getLocation()} {inst.getOrient()}', flush=True)
for n in dirty: g.addDirtyNet(n)
grt_inc.updateRoutes(True)
for inst, st in locked:
    if inst.getPlacementStatus() == 'LOCKED': inst.setPlacementStatus(st)
say(f'incremental global route of {len(dirty)} nets: ' + ' '.join(sorted(n.getName() for n in dirty)))

tcl(f'detailed_route -output_drc {OUT}.drt.drc -droute_end_iter 64 -or_seed 42 -verbose 1')
say('detailed_route done')
tcl(f'filler_placement "{FILL_LIST}"')
total = sum(r.getSiteCount() * r.getSite().getWidth() for r in block.getRows())
used = sum(i.getMaster().getWidth() for i in block.getInsts() if mtype(i.getMaster()).startswith('CORE') and i.isPlaced())
say(f'filler_placement: empty sites {(total - used) // site.getWidth()}')
for pin, net, kind in (('VPWR', 'vccd1', 'power'), ('VPB', 'vccd1', 'power'), ('VGND', 'vssd1', 'ground'), ('VNB', 'vssd1', 'ground')):
    tcl(f'add_global_connection -net {net} -inst_pattern .* -pin_pattern ^{pin}$ -{kind}')
tcl('global_connect')
unp = sum(1 for i in block.getInsts() if mtype(i.getMaster()).startswith('CORE')
          for it in i.getITerms() if it.getSigType() in ('POWER', 'GROUND') and it.getNet() is None)
say(f'global_connect: core power/ground pins left unconnected {unp}')
tcl(f'ant_count {os.environ["OUT"]}.after')
tcl(f'write_db {OUT}.odb'); tcl(f'write_def {OUT}.def')
say(f'{os.environ["OUT"]} written')
