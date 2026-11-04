# 7: the long nets that one driver buffer cannot fix, IN MEMORY ONLY (nothing written
# but reports). OpenROAD dcf3613 (openroad -python):
#   - read the DEF (no route guides: estimate_parasitics on guide routes crashes)
#   - libs: std cells ss_100C_1v60, SRAM / row / AXI their typical lib; SDC without
#     set_max_transition / set_max_fanout (lib limits); RC as OL1 (set_wire_rc
#     signal met2, clock met3; layer RC from the tech LEF)
#   - the listed nets lose their wires (in memory) and get a fresh global_route -allow_congestion
#   - row-macro drivers: a buffer (ROWBUF) at the macro output pin, the macro pin
#     drives only the buffer (as for the SRAM dout pins)
#   - set_dont_touch on every net and instance outside the list (the long nets, their
#     drivers, the new buffers)
#   - estimate_parasitics -global_routing; DRV of the listed nets before
#   - repair_design -slew_margin M -cap_margin M (incremental GRT inside);
#     estimate again; DRV after; every new buffer with its location and net
# env: IN (def) LIST (plan rows: net kind driver_pin driver_cell ...) OUT (prefix) MARGIN ROWBUF
#      SLEW_MARGIN / CAP_MARGIN (override MARGIN), DRY (estimate only)
import os, time
import odb
from openroad import Design, Tech

P = os.environ['ECO_DIR']
HERE = os.environ.get('ECO_TOOLS') or os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(P, os.environ['OUT']); M = os.environ.get('MARGIN', '25'); ROWBUF = os.environ.get('ROWBUF', 'sky130_fd_sc_hd__buf_4')
os.makedirs(os.path.dirname(OUT), exist_ok=True)
L = os.path.join(os.environ['PDK_ROOT'], 'sky130A', 'libs.ref')
t0 = time.time()
def hwm():
    for l in open('/proc/self/status'):
        if l.startswith('VmHWM'): return int(l.split()[1]) // 1024
def say(msg): print(f'PROBE {msg}; {time.time() - t0:.0f} s, peak {hwm()} MB', flush=True)
def esc(n): return n.replace('[', '\\[').replace(']', '\\]')

tech = Tech(); design = Design(tech); tcl = design.evalTclString
tcl(f'source {HERE}/common.tcl')
for lib in (f'{L}/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__ss_100C_1v60.lib',
            f'{L}/sky130_sram_macros/lib/sky130_sram_2kbyte_1rw1r_32x512_8_TT_1p8V_25C.lib',
            f'{P}/lib/ProcessingElementRow.lib', f'{P}/lib/GemmAxiShell.lib'):
    tcl(f'read_liberty {lib}')
tcl(f'read_def {os.environ["IN"]}'); tcl('route_setup')   # no guides: estimate on guide routes crashes (EST layer lookup)
tcl(f'read_sdc {P}/in/GEMM_top.libdrv.sdc'); tcl('set_propagated_clock [all_clocks]')
tcl(f'source {HERE}/layer_rc.tcl')
tcl('set_wire_rc -signal -layer met2'); tcl('set_wire_rc -clock -layer met3')
tcl('set_dont_use [get_lib_cells {' + ' '.join(os.environ['DONT_USE'].split()) + '}]')
block = design.getBlock(); db = block.getDataBase()
say('read DEF + guides + libs')

rows = [l.rstrip('\n').split('\t') for l in open(os.environ['LIST']) if l.strip()]
listed = {}
for r in rows:
    n = block.findNet(esc(r[0])) or block.findNet(r[0])
    if n is None: print('PROBE net not found', r[0]); continue
    listed[n.getName()] = (n, r)


# row-macro drivers, and hold delay cells (kept as they are, see DT_MASTERS): a buffer
# at the driver output pin, the driver then drives only that buffer
import re as _re
_dt = _re.compile(os.environ.get('DT_MASTERS', r'dlygate|clkdlybuf|dlymetal'))
k = 0; rowbufs = []; dt_nets = set()
for name, (n, r) in list(listed.items()):
    drv = [x for x in n.getITerms() if x.isOutputSignal()]
    if not drv: continue
    it = drv[0]; inst = it.getInst(); mname = inst.getMaster().getName()
    is_row = mname == 'ProcessingElementRow'; is_dt = bool(_dt.search(mname))
    if not (is_row or is_dt): continue
    c = it.getBBox()
    while block.findInst(f'eco_long_{k}') is not None: k += 1
    b = odb.dbInst.create(block, db.findMaster(ROWBUF), f'eco_long_{k}')
    nn = odb.dbNet.create(block, f'eco_long_{k}_net')
    b.setLocation((c.xMin() + c.xMax()) // 2, (c.yMin() + c.yMax()) // 2); b.setOrient('R0'); b.setPlacementStatus('PLACED')
    a = [x for x in b.getITerms() if x.isInputSignal()][0]; xo = [x for x in b.getITerms() if x.isOutputSignal()][0]
    it.disconnect(); it.connect(nn); a.connect(nn); xo.connect(n)
    rowbufs.append(b)
    if is_dt: dt_nets.add(nn.getName())
    k += 1
say(f'{len(rowbufs)} {ROWBUF} at row-macro / hold-cell output pins ({len(dt_nets)} hold cells)')

# the listed nets lose their wires in memory and get a fresh global route (every other
# net keeps its wires and counts as used resources); the new row-buffer nets too
for name, (n, r) in listed.items():
    if n.getWire() is not None: odb.dbWire.destroy(n.getWire())
tcl('global_route -allow_congestion -verbose')
say('fresh global route of the listed nets')

# dont_touch everything outside the list
rb_nets = {b.getName() + '_net' for b in rowbufs}
keep_nets = set(listed) | rb_nets
keep_insts = {b.getName() for b in rowbufs}
# A: drivers and sinks of the listed nets stay free, so repair_design can move sinks
# onto its new buffers (with the sinks dont_touch it stops on RSZ-3006)
for name, (n, r) in listed.items():
    for it in n.getITerms(): keep_insts.add(it.getInst().getName())
# hold delay cells stay as they are (repair_design would swap a dlygate for a buf),
# and so does the short net from a hold cell to its new buffer
keep_nets -= dt_nets
keep_insts = {x for x in keep_insts if not _dt.search(block.findInst(x).getMaster().getName())}
nd = ni = 0
for n in block.getNets():
    if n.getName() not in keep_nets and not n.isSpecial(): n.setDoNotTouch(True); nd += 1
for i in block.getInsts():
    if i.getName() not in keep_insts: i.setDoNotTouch(True); ni += 1
say(f'dont_touch: {nd} nets, {ni} instances; free: {len(keep_nets)} nets, {len(keep_insts)} instances')

def drv(tag):
    """nets with a slew / cap violation (estimate, SS, lib limits) among the nets
    left free (not dont_touch): the listed long nets and every net made since"""
    import re
    tcl('estimate_parasitics -global_routing')
    rpt = f'{OUT}.{tag}.drv.rpt'
    tcl(f'report_check_types -max_slew -max_capacitance -violators > {rpt}')
    bad = set()
    for line in open(rpt):
        m = re.match(r'^(\S+)\s+\S+\s+\S+\s+\S+\s+\(VIOLATED\)', line)
        if not m: continue
        iname, pin = m.group(1).rsplit('/', 1) if '/' in m.group(1) else (None, None)
        if iname is None: continue
        inst = block.findInst(esc(iname)) or block.findInst(iname)
        it = inst.findITerm(pin) if inst is not None else None
        n = it.getNet() if it is not None else None
        if n is not None and not n.isDoNotTouch(): bad.add(n.getName())
    lst = {x for x in bad if x in listed}
    say(f'{tag}: free nets over a lib limit (estimate): {len(bad)}, of them listed long nets {len(lst)}, other (new) {len(bad) - len(lst)}')
    return bad

# per free net: worst slew / limit over its pins and driver cap / limit (estimate),
# to compare with the margined limit (1 - MARGIN/100)
tcl('''proc lim_ratio {kind p} {
    sta::redirect_string_begin
    if { $kind eq "slew" } { sta::report_slew_limit_short $p "NULL" max } else { sta::report_capacitance_limit_short $p "NULL" max }
    set s [string trim [sta::redirect_string_end]]
    lassign [lrange $s 1 2] l v
    if { $l eq "" || $v eq "" || $l == 0 } { return 0 }
    return [expr {$v / $l}]
}
proc net_ratios {out names} {
    set corner [sta::cmd_corner]
    set f [open $out w]
    foreach nm $names {
        set net [get_nets -quiet $nm]; if { $net eq "" } { continue }
        sta::check_slew_limits $net 0 $corner max; sta::check_capacitance_limits $net 0 $corner max
        set ws 0; set wc 0
        foreach p [get_pins -of_objects $net] {
            set r [lim_ratio slew $p]; if { $r > $ws } { set ws $r }
            if { [get_property $p direction] eq "output" } { set r [lim_ratio cap $p]; if { $r > $wc } { set wc $r } }
        }
        puts $f [format "%s\t%.3f\t%.3f" $nm $ws $wc]
    }
    close $f
}''')
def ratios(tag):
    names = sorted(n.getName() for n in block.getNets() if not n.isSpecial() and not n.isDoNotTouch())
    tcl(f'estimate_parasitics -global_routing')
    tcl('net_ratios ' + f'{OUT}.{tag}.ratio.tsv' + ' {' + ' '.join('{' + x + '}' for x in names) + '}')
    lim = 1 - float(M) / 100; bad = 0
    for l in open(f'{OUT}.{tag}.ratio.tsv'):
        t = l.split('\t')
        if float(t[1]) > lim or float(t[2]) > lim: bad += 1
    say(f'{tag}: free nets over the margined limit ({lim:.3f} of lib): {bad}')
before = drv('before'); ratios('before')
if os.environ.get('DRY'):
    say('DRY: estimate only, no repair'); raise SystemExit(0)
n0 = {i.getName() for i in block.getInsts()}
snap = {i.getName(): (i.getMaster().getName(), i.getLocation()) for i in block.getInsts()}
if os.environ.get('RSZDBG'): tcl('set_debug_level RSZ repair_net ' + os.environ['RSZDBG'])
SM = os.environ.get('SLEW_MARGIN', M); CM = os.environ.get('CAP_MARGIN', M)
tcl(f'repair_design -slew_margin {SM} -cap_margin {CM} -verbose')
new = [i for i in block.getInsts() if i.getName() not in n0]
say(f'repair_design: {len(new)} new instances')
after = drv('after'); ratios('after')
with open(f'{OUT}.newbufs.tsv', 'w') as f:
    for i in new:
        x, y = i.getLocation()
        ins = [it.getNet().getName() for it in i.getITerms() if it.isInputSignal() and it.getNet()]
        outs = [it.getNet().getName() for it in i.getITerms() if it.isOutputSignal() and it.getNet()]
        f.write(f'{i.getName()}\t{i.getMaster().getName()}\t{x}\t{y}\t{",".join(ins)}\t{",".join(outs)}\n')
# what changed among the old instances (master or location)
with open(f'{OUT}.oldchg.tsv', 'w') as f:
    for i in block.getInsts():
        o = snap.get(i.getName())
        if o is None: continue
        if o[0] != i.getMaster().getName() or tuple(o[1]) != tuple(i.getLocation()):
            f.write(f'{i.getName()}\t{o[0]}\t{i.getMaster().getName()}\t{o[1]}\t{i.getLocation()}\n')
# topology to replay on the routed DEF: every new instance, then the full pin list of
# every listed net and every net made here (row buffers, repair_design)
with open(f'{OUT}.topo.tsv', 'w') as f:
    for b in rowbufs + new:
        x, y = b.getLocation(); f.write(f'INST\t{b.getName()}\t{b.getMaster().getName()}\t{x}\t{y}\n')
    for n in block.getNets():
        nm = n.getName()
        if not n.isSpecial() and (nm in listed or nm in rb_nets or not n.isDoNotTouch()):
            pins = [f'{it.getInst().getName()}/{it.getMTerm().getName()}' for it in n.getITerms()]
            pins += [f'PIN/{bt.getName()}' for bt in n.getBTerms()]
            f.write(f'NET\t{nm}\t' + ' '.join(sorted(pins)) + '\n')
with open(f'{OUT}.after.nets', 'w') as f: f.write('\n'.join(sorted(after)) + '\n')
with open(f'{OUT}.before.nets', 'w') as f: f.write('\n'.join(sorted(before)) + '\n')
say('done (nothing written to the layout)')
