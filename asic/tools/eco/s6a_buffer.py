# 6a (2): ECO buffer on the sink side of one pin (as Odb.InsertECOBuffers with a
# sink target), placed at the sink instance (OpenROAD dcf3613, openroad -python):
#   remove CORE SPACER cells within +-15 um of the sink instance, lock every other
#   instance, create BUF, move the sink pin to a new net driven by BUF/X with
#   BUF/A on the old net, legalize (only BUF moves), incremental global route of
#   both nets, detailed_route (INCR), filler_placement (OL1 list), global connect
#   (OL1), antenna check, write ODB + DEF.
# Setup slack of the paths through the sink pin at TT and SS before and after:
#   OpenRCX with the PDK nom rules (the file OL1 uses), std cells tt / ss lib,
#   macros their typical lib, propagated clock, final SDC.
# env: IN (odb) OUT (prefix) PIN (inst/pin) BUF (master) MODE (eco|timing) TAG (timing)
import os, time
import odb, grt as GRT
from openroad import Design, Tech

P = os.environ['ECO_DIR']
HERE = os.environ.get('ECO_TOOLS') or os.path.dirname(os.path.abspath(__file__))
PDK = os.path.join(os.environ['PDK_ROOT'], 'sky130A')
IN = os.environ['IN']; OUT = os.path.join(P, os.environ['OUT']); WIN = 15.0
TINST, TPIN = os.environ['PIN'].rsplit('/', 1); BUF = os.environ['BUF']
os.makedirs(os.path.dirname(OUT), exist_ok=True)
FILL_LIST = ('sky130_ef_sc_hd__decap_12 sky130_fd_sc_hd__decap_8 sky130_fd_sc_hd__decap_6 '
             'sky130_fd_sc_hd__decap_4 sky130_fd_sc_hd__decap_3 sky130_fd_sc_hd__fill*')
L = f'{PDK}/libs.ref'
RCX = f'{PDK}/libs.tech/openlane/rules.openrcx.sky130A.nom.calibre'
t0 = time.time()
def hwm():
    for l in open('/proc/self/status'):
        if l.startswith('VmHWM'): return int(l.split()[1]) // 1024
def say(msg): print(f'PROBE {msg}; {time.time() - t0:.0f} s, peak {hwm()} MB', flush=True)
def mtype(m):
    t = m.getType(); return t if isinstance(t, str) else t.getString()

tech = Tech(); design = Design(tech); tcl = design.evalTclString
tcl(f'source {HERE}/common.tcl')
tcl('define_corners tt ss')
for c, lib in (('tt', 'tt_025C_1v80'), ('ss', 'ss_100C_1v60')):
    tcl(f'read_liberty -corner {c} {L}/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__{lib}.lib')
    tcl(f'read_liberty -corner {c} {L}/sky130_sram_macros/lib/sky130_sram_2kbyte_1rw1r_32x512_8_TT_1p8V_25C.lib')
    tcl(f'read_liberty -corner {c} {P}/lib/ProcessingElementRow.lib')
    tcl(f'read_liberty -corner {c} {P}/lib/GemmAxiShell.lib')
tcl(f'read_db {IN}' if IN.endswith('.odb') else f'read_def {IN}'); tcl('route_setup')
tcl(f'read_sdc {P}/in/GEMM_top.sdc'); tcl('set_propagated_clock [all_clocks]')
block = design.getBlock(); db = block.getDataBase(); dbu = block.getDbUnitsPerMicron()
say(f'read {IN}')

tcl('define_process_corner -ext_model_index 0 X')
def timing(tag):
    tcl(f'extract_parasitics -ext_model_file {RCX}')
    tcl(f'write_spef {OUT}.{tag}.spef')
    for c in ('tt', 'ss'): tcl(f'read_spef -corner {c} {OUT}.{tag}.spef')
    say(f'{tag}: OpenRCX (nom rules) done')
    for c in ('tt', 'ss'):
        tcl(f'report_checks -path_delay max -corner {c} -through [get_pins {{{TINST}/{TPIN}}}] '
            f'-format full_clock_expanded -fields {{cap slew fanout}} -digits 3 > {OUT}.{tag}.{c}.rpt')
        s = tcl(f'get_property [lindex [find_timing_paths -path_delay max -corner {c} -through [get_pins {{{TINST}/{TPIN}}}]] 0] slack')
        print(f'PROBE {tag} setup slack through {TINST}/{TPIN} at {c.upper()}: {s} ns', flush=True)

# OpenRCX reorders the dbWires (non-orthogonal joins, DRT-1010), so it never runs
# in the process that routes: MODE=timing measures only, MODE=eco edits only
MODE = os.environ.get('MODE', 'eco')
if MODE == 'timing':
    timing(os.environ['TAG']); say('done'); raise SystemExit(0)
tcl(f'ant_count {os.environ["OUT"]}.before')

inst = block.findInst(TINST); master = db.findMaster(BUF)
assert inst is not None and master is not None
w = int(WIN * dbu); b = inst.getBBox(); kill = {}
for o in block.getInsts():
    if mtype(o.getMaster()) != 'CORE_SPACER': continue
    ob = o.getBBox()
    if ob.xMax() >= b.xMin() - w and ob.xMin() <= b.xMax() + w and ob.yMax() >= b.yMin() - w and ob.yMin() <= b.yMax() + w:
        kill[o.getName()] = o
for o in kill.values(): odb.dbInst.destroy(o)
say(f'removed {len(kill)} CORE SPACER instances (+-{WIN:g} um)')

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

target = inst.findITerm(TPIN); net = target.getNet()
k = 0
while block.findInst(f'eco_buffer_{k}') is not None or block.findNet(f'eco_buffer_{k}_net') is not None: k += 1
buf = odb.dbInst.create(block, master, f'eco_buffer_{k}')
enet = odb.dbNet.create(block, f'eco_buffer_{k}_net')
ba = [it for it in buf.getITerms() if it.isInputSignal()][0]
bx = [it for it in buf.getITerms() if it.isOutputSignal()][0]
target.disconnect(); ba.connect(net); bx.connect(enet); target.connect(enet)
buf.setOrient('R0'); buf.setLocation(*inst.getLocation()); buf.setPlacementStatus('PLACED')
site = block.getRows()[0].getSite()
design.getOpendp().detailedPlacement(int(design.micronToDBU(1000) / site.getWidth()), int(design.micronToDBU(500) / site.getHeight()))
print(f'PROBE inserted eco_buffer_{k} ({BUF}) on {TINST}/{TPIN}: net {net.getName()} -> buffer A, buffer X -> new net eco_buffer_{k}_net; '
      f'{TINST} at {inst.getLocation()}, buffer legalized at {buf.getLocation()} {buf.getOrient()}', flush=True)
g.addDirtyNet(net); g.addDirtyNet(enet)
grt_inc.updateRoutes(True)
for i, st in locked:
    i.setPlacementStatus(st)
say('incremental global route done')

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
tcl(f'write_db {OUT}.odb'); tcl(f'write_def {OUT}.def')
say(f'{os.environ["OUT"]} written')
