# ---------------------------------------------------------------------------
# Level 3 - the hardened GEMM core: GemmAccelerator (rtl_asic/GEMM_core.v)
#   InputBuffer + BufferFeeder(+GemmComputeCore + array) + OutputBuffer
#   = 32 row macros (row_v1) + 80 sky130 OpenRAM macros + standard cells.
# Floorplan, PDN pitch/offset and pin order come from gen_core_files.py
# (sizes.tcl / macro.cfg / pin_order.cfg). Run order:
#   openlane/run_flow.sh core-sim   RTL with the real SRAM models
#   openlane/run_flow.sh core-pre   synthesis + floorplan only (~1 h)
#   openlane/run_flow.sh core       the full run
# Everything learned on the array is applied here (see the comments).
# ---------------------------------------------------------------------------
source $::env(DESIGN_DIR)/../gemm_common.tcl
source $::env(DESIGN_DIR)/sizes.tcl

set ::env(DESIGN_NAME) "GemmAccelerator"

set SRC $::env(DESIGN_DIR)/src
set ::env(VERILOG_FILES) [list \
    $SRC/GEMM_core.v $SRC/In_buffer.v $SRC/Buffer_feeder.v $SRC/Out_buffer.v \
    $SRC/Gemm_compute_core.v $SRC/PE_array.v $SRC/FeatureSkew.v $SRC/OutputDeskew.v \
    $SRC/DelayLine.v $SRC/sram_1r1w.v $SRC/Signed_adder.v $SRC/Right_shifter.v]
# port-only views ("/// sta-blackbox"): the row macro and the OpenRAM macro
set ::env(VERILOG_FILES_BLACKBOX) [list $::env(DESIGN_DIR)/PE_row_bb.v $::env(DESIGN_DIR)/sram_bb.v]
set ::env(VERILOG_INCLUDE_DIRS)   [list $SRC]
# buffer depths come from gemm_asic_cfg.vh (W 1024 / F 512 / O 512);
# SRAM_USE_SKY130_OPENRAM turns every sram_1r1w into OpenRAM macros
set ::env(SYNTH_DEFINES) [list GEMM_DP_RESET=$::env(GEMM_DP_RESET) SRAM_USE_SKY130_OPENRAM]

# ---- hard macros: the hardened row + the OpenRAM 2 kB macro from the PDK
set ROW  $::env(DESIGN_DIR)/../gemm_row/runs/row_v1/results/final
set SRAM_NAME sky130_sram_2kbyte_1rw1r_32x512_8
set SRAM $::env(PDK_ROOT)/$::env(PDK)/libs.ref/sky130_sram_macros
# The OpenRAM LEF has no antenna data, so ARC / repair_antennas / the antenna ECO
# could not see the gates behind the SRAM pins. sram_antenna.lef is the same LEF
# (same macro name) with ANTENNAGATEAREA / ANTENNADIFFAREA on every signal pin,
# written by macro_antenna_lef.py (run_flow.sh core_install); values and reasons
# in its header. The row LEF already has antenna data (940 gate, 1868 diff).
set SRAM_LEF $::env(DESIGN_DIR)/sram_antenna.lef
foreach f [list $ROW/lef/ProcessingElementRow.lef $ROW/gds/ProcessingElementRow.gds \
                $SRAM_LEF $SRAM/gds/$SRAM_NAME.gds] {
    if { ![file exists $f] } { puts stderr "\[ERROR\]: gemm_core: missing $f"; exit 1 }
}
set ::env(EXTRA_LEFS)      [list $ROW/lef/ProcessingElementRow.lef $SRAM_LEF]
set ::env(EXTRA_GDS_FILES) [list $ROW/gds/ProcessingElementRow.gds $SRAM/gds/$SRAM_NAME.gds]
set libs [list]
if { [file exists $ROW/lib/ProcessingElementRow.lib] } { lappend libs $ROW/lib/ProcessingElementRow.lib }
set sram_lib [lindex [glob -nocomplain $SRAM/lib/${SRAM_NAME}_TT_1p8V_25C.lib] 0]
if { $sram_lib ne "" } { lappend libs $sram_lib }
set ::env(EXTRA_LIBS) $libs

# ---- no buffer trees from synthesis (core v4). OpenLane 1.0.2 lets ABC build
# buffer trees for every net above MAX_FANOUT_CONSTRAINT ("buffer -N 10" in
# scripts/yosys/synth.tcl) and, unlike ORFS (remove_buffers in floorplan.tcl),
# never removes them before placement. ABC groups the sinks without knowing
# where they will be, so every leaf buffer of the OutputBuffer control nets
# (write-data select, first-K zeroing, read-hold select, the 32 shifters'
# shift amount, the output enables: ~1000 sinks each) ties together cells of
# different lanes. Global placement then pulled the logic of all 32 lanes into
# the middle of region B, and those leaf nets ran mm-long through the narrow
# SRAM gaps: core_v1 (layout v3) ended global route with 321k overflow, 99 % of
# it on standard-cell-only nets, mostly mux2/mux4/a21oi (core-triage). With
# buffering off, placement sees the plain high-fanout nets and the resizer
# (repair_design, max fanout from core.sdc) builds the trees after placement,
# from where the cells really are.
set ::env(SYNTH_BUFFERING) 0

# ---- nothing but hold buffers in the channels between the row macros (core v6).
# The rows block met1-met4; a cell in a channel can only reach the outside by
# crossing a row, which the router cannot do. core_v4/v5 had ~1300 such cells
# (repair_design repeaters on the diagonal feeder -> row-31 weight nets, plus
# some logic): 6k overflow over the rows, 9.5k shorts in detailed routing.
# keep_rows_clear.tcl moves them to the strip / band right before every
# detailed_placement (hook added to OpenLane by run_flow.sh); hold buffers on
# the row-to-row nets stay in the channel, where they belong.
set ::env(DPL_PRE_HOOK) $::env(DESIGN_DIR)/keep_rows_clear.tcl

set ::env(MACRO_PLACEMENT_CFG) $::env(DESIGN_DIR)/macro.cfg
set ::env(FP_PDN_MACRO_HOOKS)  ".*g_pe_row.* vccd1 vssd1 vccd1 vssd1, .*u_macro.* vccd1 vssd1 vccd1 vssd1"
set ::env(PL_MACRO_HALO)       "5 5"
set ::env(FP_PIN_ORDER_CFG)    $::env(DESIGN_DIR)/pin_order.cfg
set ::env(DESIGN_IS_CORE)      1
# ---- placement (core_v1 diverged in global placement, GPL-0307, at overflow
# ~0.25 when the routability-driven inflation kicked in). This floorplan has
# large free areas next to narrow channels: no routability inflation, a
# higher target density so cells stay near their pins instead of spreading
# over the empty corner, and room for detailed placement to pull cells off
# the 417 um tall SRAMs (default limit 100 um in y).
set ::env(PL_TARGET_DENSITY)       0.55
set ::env(PL_ROUTABILITY_DRIVEN)   0
set ::env(PL_TIME_DRIVEN)          1
set ::env(PL_MAX_DISPLACEMENT_X)   1000
set ::env(PL_MAX_DISPLACEMENT_Y)   500
# core_v1 still diverged with both modes off: util is only ~5 % of a 54 mm2
# core, HPWL ~1.7e10 dbu, and RePlAce's density-penalty step (max_phi_coef
# 1.05) overshoots. OpenLane v1 does not expose these knobs, so run_flow.sh
# adds a 1-line hook to $OL/scripts/openroad/gpl.tcl that appends this
# variable to global_placement (no effect on designs that do not set it).
set ::env(GPL_EXTRA_ARGS) "-max_phi_coef 1.02 -overflow 0.15"

# ---- I/O constraints measured from the real clock arrival (array lesson)
if { [file exists $::env(DESIGN_DIR)/clk_latency.tcl] } {
    source $::env(DESIGN_DIR)/clk_latency.tcl
} else {
    source $::env(DESIGN_DIR)/clk_latency_seed.tcl
}
set ::env(BASE_SDC_FILE) $::env(DESIGN_DIR)/core.sdc
set ::env(SYNTH_CLK_DRIVING_CELL)     sky130_fd_sc_hd__clkbuf_16
set ::env(SYNTH_CLK_DRIVING_CELL_PIN) X

# ---- clock tree (array lesson: CTS must estimate clock wires on met3, where
# the router really puts them; no post-CTS repair_clock_nets)
set ::env(CLOCK_WIRE_RC_LAYER)      met3
set ::env(CTS_CLK_MAX_WIRE_LENGTH)  0
set ::env(CTS_CLK_BUFFER_LIST) "sky130_fd_sc_hd__clkbuf_16 sky130_fd_sc_hd__clkbuf_8 sky130_fd_sc_hd__clkbuf_4"

# ---- hold (array passed with these; setup had > 6 ns spare)
# core_v7r: hold -0.01 ns (one path in the OutputDeskew delay line,
# _52351_ -> _52372_) with 0.3, setup +1.21 ns to spare -> 0.5 from core_v8.
# core_v9 (0.5): hold -0.12 ns at the Fastest corner with max RC (one path,
# OutputDeskew delay line again), setup typical +1.01 ns. core_v10 tried 0.7:
# hold clean at every corner, but setup typical -0.06 ns (one path) and the
# slow corner 1.4 ns worse -> back to 0.5.
# Acts in the post-CTS resizer, so it needs a full core run, not core-route.
set ::env(PL_RESIZER_HOLD_SLACK_MARGIN)        0.5
set ::env(GLB_RESIZER_HOLD_SLACK_MARGIN)       0.4
set ::env(PL_RESIZER_HOLD_MAX_BUFFER_PERCENT)  80
set ::env(GLB_RESIZER_HOLD_MAX_BUFFER_PERCENT) 80

# ---- antenna (array passed with these)
# Heuristic diodes OFF from core_v8. They were the main source of global-route
# congestion on the core: global route of core_v7r's post-CTS layout, ITERS 18,
# met1 adjustment 0.5 - without them total overflow 46 and no net through a
# macro; with them (core_v7r) 515 and net3191 left straight through an SRAM
# (23 met2 shorts with every DRT seed); more congestion iterations made it
# worse (ITERS 30: 2487, 26 nets through SRAMs). Antennas now rely on
# repair_antennas in the global route plus the antenna ECO rounds after
# detailed routing (run_flow.sh ANT_ECO=3).
# The OpenRAM LEF has no ANTENNA data; run_flow.sh writes sram_antenna.lef
# (macro_antenna_lef.py, smallest gate/diffusion area of the hd library) so
# repair_antennas, ARC and the ECO see the SRAM pins (core_v9: 0 left on them).
set ::env(RUN_HEURISTIC_DIODE_INSERTION) 0
set ::env(GRT_ANT_ITERS)                 30
set ::env(GRT_ANT_MARGIN)                30
set ::env(GRT_MAX_DIODE_INS_ITERS)       3
set ::env(HEURISTIC_ANTENNA_THRESHOLD)   50
# GRT_ANT_MARGIN 50 (core_v10): 30k more diodes, same ~220 nets left -> 30.

# ---- signoff on a 54 mm2 die with 80 OpenRAM macros
# Magic DRC on the abstract view: the OpenRAM bitcells break generic sky130
# rules on purpose (foundry-qualified cell, own rule deck) and the rows were
# DRC-clean on their own run. The standard cells still get their full layout
# (gemm_magic_drc in route_signoff.tcl). KLayout XOR off (slow on this size).
set ::env(MAGIC_DRC_USE_GDS) 0
set ::env(RUN_KLAYOUT_XOR)   0
# fewer router threads = lower peak RAM on a 16 GB machine
set ::env(ROUTING_CORES) 8

# ---- one run = one complete set of signoff reports. run_flow.sh judges
# PASS/FAIL from the numbers (check_openlane_run.py: router DRC, Magic DRC,
# LVS, antenna, timing), so letting the flow continue past a DRC/LVS problem
# loses nothing and an unattended run still ends with GDS + every report.
# ...except a dirty detailed route: core_v6 went on with one short and netgen
# then spent 7 h listing every cell of a 157k-device netlist as unmatched.
# run_flow.sh core routes again from the post-CTS layout with other seeds.
set ::env(QUIT_ON_TR_DRC)           1
set ::env(QUIT_ON_MAGIC_DRC)        0
set ::env(QUIT_ON_LVS_ERROR)        0
set ::env(QUIT_ON_ILLEGAL_OVERLAPS) 0
# The two informational STA runs after the GRT resizer steps (rsz_*_sta.log)
# start a fresh OpenROAD, reload the global routes from the guides stored in
# the ODB and estimate parasitics from them. core_v1r crashed right there
# (17-rsz_design_sta.log). Most likely suspect: this OpenROAD's
# GlobalRouter::loadGuidesFromDB lacks the "net is not routed by the global
# router" guard that readGuides (used by the detailed router) has. The resizer
# scripts estimate from the routes they just made, so only these two
# informational reports are lost.
set ::env(GRT_ESTIMATE_PARASITICS) 0
# Global route: stop the congestion iterations at 18. FastRoute in this
# OpenROAD runs a "hard benchmark" extra pass right after iteration 19 and
# then the late, ever-wider maze iterations; that is where core_v1 crashed
# (route longer than its x+y buffer) and the second floorplan crawled for hours. If some
# overflow is left after 18 iterations, carry on (detailed routing resolves
# small overflow) instead of stopping; the GRT-0096 table in
# logs/routing/*resizer_design.log says how much was left.
set ::env(GRT_OVERFLOW_ITERS)   18
set ::env(GRT_ALLOW_CONGESTION) 1
# met1 capacity cut to 50 % for the global route: less long met1, fewer
# antenna islands (post-CTS of core_v9: overflow 46; met1 0.65 -> more
# antenna violations, 0.8 -> overflow 4490 and 53 nets through macros).
set ::env(GRT_LAYER_ADJUSTMENTS) "0.99,0.5,0,0,0,0"
# The timing repair after global routing (resizer_routing_timing.tcl) died
# with SIGSEGV in the layout-v3 run, during the incremental re-routes of the nets it had
# just buffered ("GRT-0009 rerouting N nets"). Setup/hold are already repaired
# after CTS (hold margin 0.3 ns, see above); skip this optional step.
set ::env(GLB_RESIZER_TIMING_OPTIMIZATIONS) 0
# Its sibling (repair_design on global-route parasitics) uses the same
# incremental re-route code; it survived once, but it only fixes slew/cap on a
# few long nets (not judged at signoff; repair_design already ran after
# placement). One crash point less for an unattended run.
set ::env(GLB_RESIZER_DESIGN_OPTIMIZATIONS) 0
# informational steps that are slow/heavy on a ~60 mm2 die and not judged:
# IR drop (PSM) and the second GDS from KLayout (only used for XOR, which is off)
set ::env(RUN_IRDROP_REPORT) 0
set ::env(RUN_KLAYOUT)       0

# No signal routing on met5 over the OpenRAM macros. They block met1-met4, so
# a net crossing one has met5 (horizontal) only, and any track change on the
# way is a wrong-way met5 jog. core_v6 and core_v6r (router seeds 42 and 7)
# both ended with the same single short: two such jogs over the SRAM of lane 4
# in region B, at (3122, 2140) - nothing the detailed router can clear. With
# met5 blocked over the SRAMs, global and detailed routing take those nets
# through the gaps, where every layer exists. GEMM_SRAM_MET5_OBS comes from
# gen_core_files.py (sizes.tcl); run_flow.sh MET5_OVER_SRAM=1 switches it off.
if { [info exists ::env(GEMM_SRAM_MET5_OBS)] && $::env(GEMM_SRAM_MET5_OBS) ne "" } {
    set ::env(GRT_OBS) $::env(GEMM_SRAM_MET5_OBS)
}

# run_flow.sh writes overrides.tcl when it retries a failed step with a
# fallback setting (e.g. PL_TIME_DRIVEN 0 after another GPL divergence)
if { [file exists $::env(DESIGN_DIR)/overrides.tcl] } {
    puts "\[INFO\]: gemm_core: applying overrides.tcl"
    source $::env(DESIGN_DIR)/overrides.tcl
}
