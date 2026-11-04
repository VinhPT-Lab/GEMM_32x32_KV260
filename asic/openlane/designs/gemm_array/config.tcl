# ---------------------------------------------------------------------------
# Level 2 - ProcessingElementArray = FeatureSkew + 32 row macros + OutputDeskew.
# A rehearsal of the final integration (and a GDS you can show): the row is a
# black box here, only ~20-40k standard cells are placed at this level.
#   ./flow.tcl -design gemm_array -tag array_v1 -overwrite
#
# NOTE on sky130: only ONE level of hard macros is practical (a macro inside a
# macro would be left with too few routing layers). So the final chip top
# (GemmAccelerator / GEMM_top) will instantiate the 32 row macros DIRECTLY,
# like this file does, rather than hardening this array as a macro.
# ---------------------------------------------------------------------------
source $::env(DESIGN_DIR)/../gemm_common.tcl
source $::env(DESIGN_DIR)/sizes.tcl

set ::env(DESIGN_NAME) "ProcessingElementArray"

set SRC $::env(DESIGN_DIR)/src
# the row must NOT be in VERILOG_FILES - it is read as a black box only
set ::env(VERILOG_FILES)          [list $SRC/PE_array.v $SRC/FeatureSkew.v $SRC/OutputDeskew.v $SRC/DelayLine.v]
# port-only view of the row ("/// sta-blackbox" on line 1): lint and synthesis
# see the ports, STA skips it and takes the row timing from EXTRA_LIBS
set ::env(VERILOG_FILES_BLACKBOX) [list $::env(DESIGN_DIR)/PE_row_bb.v]
set ::env(VERILOG_INCLUDE_DIRS)   [list $SRC]
set ::env(SYNTH_DEFINES)          [list GEMM_DP_RESET=$::env(GEMM_DP_RESET)]

# the hardened row (run gemm_row with -tag row_v1 first)
set ROW $::env(DESIGN_DIR)/../gemm_row/runs/row_v1/results/final
set ::env(EXTRA_LEFS)      [list $ROW/lef/ProcessingElementRow.lef]
set ::env(EXTRA_GDS_FILES) [list $ROW/gds/ProcessingElementRow.gds]
if { [file exists $ROW/lib/ProcessingElementRow.lib] } {
    set ::env(EXTRA_LIBS) [list $ROW/lib/ProcessingElementRow.lib]
}

# rows stacked by hand, pins aligned; power hooked with one regex for all 32
set ::env(MACRO_PLACEMENT_CFG) $::env(DESIGN_DIR)/macro.cfg
set ::env(FP_PDN_MACRO_HOOKS)  "g_pe_row.* vccd1 vssd1 vccd1 vssd1"
set ::env(PL_MACRO_HALO)       "5 5"
set ::env(FP_PIN_ORDER_CFG)    $::env(DESIGN_DIR)/pin_order.cfg

# top-level grid: met5 pitch/offset, PDN/tap halos come from sizes.tcl - met5
# phased to the rows so a VDD/VSS pair crosses the met4 left in every channel
# and in the band above row 0 (otherwise PSM-0069), two pairs over every row
set ::env(DESIGN_IS_CORE)  1

set ::env(PL_TARGET_DENSITY) 0.45

# I/O constraints measured from the clock the inside flops really get (see
# array.sdc); clk_latency.tcl is written by run_flow.sh from the previous run
if { [file exists $::env(DESIGN_DIR)/clk_latency.tcl] } {
    source $::env(DESIGN_DIR)/clk_latency.tcl
}
set ::env(BASE_SDC_FILE) $::env(DESIGN_DIR)/array.sdc
set ::env(SYNTH_CLK_DRIVING_CELL)     sky130_fd_sc_hd__clkbuf_16
set ::env(SYNTH_CLK_DRIVING_CELL_PIN) X

# clock tree over ~20 mm2. Measured on array_v1: skew 0.96 ns right after
# CTS but 4.35 ns at signoff, flop clock arrival 4.9..16.5 ns. Cause: the
# sky130 default CLOCK_WIRE_RC_LAYER is met5, so CTS and the resizer estimated
# clock wires as met5 - but the router put the clock trunks on met3/met4
# (met5 0 mm) and the long branches came out far slower than CTS assumed.
# Estimate with met3, which is where the clock really goes (RT_CLOCK_MIN_LAYER
# met3), so CTS buffers and balances against realistic RC.
set ::env(CLOCK_WIRE_RC_LAYER)          met3
# no post-CTS repair_clock_nets (it only buffers the long branches -> skew);
# a stronger buffer available for the trunks
set ::env(CTS_CLK_MAX_WIRE_LENGTH)      0
set ::env(CTS_CLK_BUFFER_LIST) "sky130_fd_sc_hd__clkbuf_16 sky130_fd_sc_hd__clkbuf_8 sky130_fd_sc_hd__clkbuf_4"

# hold: repair runs on estimated parasitics and array_v1 still missed ~0.6 ns
# flop-to-flop after detailed routing (still -0.22 with 0.3) -> more margin,
# bigger buffer budget; setup has >4 ns of slack to pay for it
set ::env(PL_RESIZER_HOLD_SLACK_MARGIN)       0.3
set ::env(GLB_RESIZER_HOLD_SLACK_MARGIN)      0.4
set ::env(PL_RESIZER_HOLD_MAX_BUFFER_PERCENT) 80
set ::env(GLB_RESIZER_HOLD_MAX_BUFFER_PERCENT) 80

# XOR of magic vs klayout GDS is slow on a big die; turn back on for signoff
set ::env(RUN_KLAYOUT_XOR) 0

# antenna: same treatment as the row (long top-level nets)
set ::env(RUN_HEURISTIC_DIODE_INSERTION) 1
set ::env(GRT_ANT_ITERS)                 30
set ::env(GRT_ANT_MARGIN)                30
# re-run global route + antenna check + diode repair until the count stops
# dropping (default is a single pass)
set ::env(GRT_MAX_DIODE_INS_ITERS)       3
set ::env(HEURISTIC_ANTENNA_THRESHOLD)   50
