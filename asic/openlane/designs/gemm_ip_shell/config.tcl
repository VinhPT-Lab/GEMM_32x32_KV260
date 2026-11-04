# ---------------------------------------------------------------------------
# The AXI macro of the complete IP (gemm_ip): GemmAxiShell, lean + clock
# gating, hardened as a block (met1-met4, power pins vccd1/vssd1 on met4 like
# the row macro) and placed by gemm_ip as instance u_axi_shell.
#   openlane/run_flow.sh ip-shell     tags ip_shell_cal (clock latency), ip_shell
# Same RTL, variant and port budget as the axi-shell measurement run, so this
# file starts from gemm_axi_shell/config.tcl and changes only what the
# integration needs:
#   - a tall, narrow die along the IP's West edge (sizes.tcl, pin_order.cfg from
#     gen_ip_files.py): core-side pins at the y of core_v11's West pins;
#   - antenna 0: diodes on the inputs + heuristic diodes, more repair rounds in
#     the global route, and the antenna ECO rounds after detailed routing
#     (shell_full.tcl runs gemm_core/route_signoff.tcl, as the core does).
# ---------------------------------------------------------------------------
source $::env(DESIGN_DIR)/../gemm_axi_shell/config.tcl

# files of gemm_axi_shell that config.tcl looks for in DESIGN_DIR
set ::env(BASE_SDC_FILE) $::env(DESIGN_DIR)/../gemm_axi_shell/shell.sdc
if { $::env(GEMM_AXIS_CG) } {
    set ::env(VERILOG_FILES_BLACKBOX) [list $::env(DESIGN_DIR)/../gemm_axi_shell/dlclkp_bb.v]
}

# clock gates with the x4 ICG (rtl_asic/axi/AxisClockGate.v): with dlclkp_1 the
# GCLK net (14 loads, 0.34 pF, 3.3 ns slew) put the gated banks at 7.2 ns of
# latency against ~3 ns for the rest, so every input got ~6 hold buffers
# (ip_shell3: ~5600). axi-* keep dlclkp_1 (no define there).
lappend ::env(SYNTH_DEFINES) GEMM_ICG_X4
# and 16 clock gates per data bank, each on a run of adjacent bits
# (AxisSkidBuffer / AxisFwdSlice P_CG_GROUPS): with one gate per bank the gated
# branch still had ~5.2 ns of latency against ~2.8 ns (ip_shell4, dlclkp_4).
# The pins of every bus follow the bit order (gen_ip_files.py checks it), so
# each group sits in one stretch of the macro.
# The IP (gemm_ip) uses the macro of run ip_shell5, built with these settings
# (x4 ICG + 16 groups): gated branch median 3.35 ns against 2.78 ns ungated,
# no internal setup/hold violation at any of the 3 corners, no I/O hold
# violation at Typical (ip_shell4, 1 group: 11 internal setup paths at Slowest).
if { ![info exists ::env(GEMM_CG_GROUPS)] } { set ::env(GEMM_CG_GROUPS) 16 }
lappend ::env(SYNTH_DEFINES) GEMM_CG_GROUPS=$::env(GEMM_CG_GROUPS)

# The die is 160 um wide and 5.9 mm tall: ~3 % of the core area is cells, and
# most nets are short horizontal bit slices. The long nets are the control
# fan-outs of the slices (load enable, clock-gate GCLK, reset) along the whole
# height; those are the antenna risk (shell_lean_cg: 12 met1 islands with no
# diode in them, Required 400).
# ip_shell (second try): at 0.30 the result path (256-bit i_result_data in,
# result_axis_tdata out, pins in the bottom 370 um) plus its ~1800 hold buffers
# filled the bottom 400 um to 60-67 % while the macro as a whole is 11.6 %
# used; the antenna diodes found no site near their gates there (38-87 um
# away) and every violation left was a hold-buffer input in that corner.
# 0.15 lets global placement spread that logic upwards.
set ::env(PL_TARGET_DENSITY) 0.15

# antenna (row_v1 reached 0 with these; ECO rounds from route_signoff.tcl on top)
set ::env(DIODE_ON_PORTS)                "in"
set ::env(RUN_HEURISTIC_DIODE_INSERTION) 1
set ::env(HEURISTIC_ANTENNA_THRESHOLD)   50
set ::env(GRT_REPAIR_ANTENNAS)           1
set ::env(GRT_ANT_ITERS)                 30
set ::env(GRT_ANT_MARGIN)                30
set ::env(GRT_MAX_DIODE_INS_ITERS)       3
# less long met1 (gemm_core: fewer antenna islands with met1 at 50 %)
set ::env(GRT_LAYER_ADJUSTMENTS)         "0.99,0.5,0,0,0,0"
set ::env(GEMM_ANT_ECO_ITERS)            3
# diodes before the first global route (shell_full.tcl, ant_seed.py): one next
# to every gate on an input-port net or more than this far from its driver
set ::env(GEMM_ANT_SEED_DIST)            40
# ant_eco.py adds at most --max-total diodes per call (3000 by default; ip_shell3:
# 3631 seeded pins, 631 left without a diode). The ant_eco.py installed next to
# this file is ant_eco_max.py, which passes this limit to gemm_core/ant_eco.py.
set ::env(GEMM_ANT_ECO_MAX_TOTAL)        8000
# no extra site left of each diode: with ~2300 seeded diodes the 2-site padding
# made the global router's diode legalization fail (DPL-0036, ip_shell experiment)
set ::env(DIODE_PADDING)                 0

# a dirty route ends the run in route_signoff.tcl only after every seed was tried
set ::env(QUIT_ON_TR_DRC) 1

if { [file exists $::env(DESIGN_DIR)/overrides.tcl] } {
    puts "\[INFO\]: gemm_ip_shell: applying overrides.tcl"
    source $::env(DESIGN_DIR)/overrides.tcl
}
