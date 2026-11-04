# ---------------------------------------------------------------------------
# shell.sdc - GemmAxiShell measurement run: one clock (S_AXI_ACLK, 100 MHz),
# every port gets GEMM_SHELL_IO_PCT of the period as outside budget, the
# rest of OpenLane's base.sdc (driving cell, load, uncertainty, derate) as is.
#
# Clock-latency-aware port delays, as in gemm_core/core.sdc: in the IP the
# ports face flops on the SAME balanced clock tree (the AXI master's on one
# side, the core's on the other), not an ideal clock at 0 ns. With plain
# base.sdc every input of "reg" would see a hold miss as large as the shell's
# own clock latency and the resizer would pad all ~560 of them with delay
# cells - area and power that the IP would not have. So the outside flops are
# assumed to get their clock between GEMM_CLK_LAT_MIN and GEMM_CLK_LAT_MAX:
# 0 in the first (calibration) run, then the shell's own measured latency
# (run_flow.sh axi-shell, tools/clock_latency.py -> clk_latency.tcl).
# ---------------------------------------------------------------------------
set T     $::env(CLOCK_PERIOD)
set EXT   [expr {$T * $::env(GEMM_SHELL_IO_PCT)}]
set L_MIN [expr {[info exists ::env(GEMM_CLK_LAT_MIN)] ? $::env(GEMM_CLK_LAT_MIN) : 0.0}]
set L_MAX [expr {[info exists ::env(GEMM_CLK_LAT_MAX)] ? $::env(GEMM_CLK_LAT_MAX) : 0.0}]

create_clock [get_ports $::env(CLOCK_PORT)] -name $::env(CLOCK_PORT) -period $T
set clk [get_clocks $::env(CLOCK_PORT)]

set_max_fanout $::env(MAX_FANOUT_CONSTRAINT) [current_design]
if { [info exists ::env(MAX_TRANSITION_CONSTRAINT)] } {
    set_max_transition $::env(MAX_TRANSITION_CONSTRAINT) [current_design]
}

set clk_input [get_port $::env(CLOCK_PORT)]
set clk_indx  [lsearch [all_inputs] $clk_input]
set ins       [lreplace [all_inputs] $clk_indx $clk_indx ""]

# inputs: launched outside by a flop clocked at L_MIN..L_MAX
set_input_delay  -max [expr {$L_MAX + $EXT}] -clock $clk $ins
set_input_delay  -min [expr {$L_MIN}]        -clock $clk $ins
# outputs: captured outside by a flop clocked at L_MIN..L_MAX
set_output_delay -max [expr {$EXT - $L_MIN}] -clock $clk [all_outputs]
set_output_delay -min [expr {-$L_MAX}]       -clock $clk [all_outputs]
puts "\[INFO\]: shell.sdc: outside clock latency $L_MIN..$L_MAX ns, outside budget $EXT ns"

# the asynchronous reset input goes only into ResetSync (async assert);
# its release is synchronised there, so no timing path starts at the port
set_false_path -from [get_ports S_AXI_ARESETN]

if { ![info exists ::env(SYNTH_CLK_DRIVING_CELL)] } {
    set ::env(SYNTH_CLK_DRIVING_CELL) $::env(SYNTH_DRIVING_CELL)
}
if { ![info exists ::env(SYNTH_CLK_DRIVING_CELL_PIN)] } {
    set ::env(SYNTH_CLK_DRIVING_CELL_PIN) $::env(SYNTH_DRIVING_CELL_PIN)
}
set_driving_cell -lib_cell $::env(SYNTH_DRIVING_CELL) -pin $::env(SYNTH_DRIVING_CELL_PIN) $ins
set_driving_cell -lib_cell $::env(SYNTH_CLK_DRIVING_CELL) -pin $::env(SYNTH_CLK_DRIVING_CELL_PIN) $clk_input

set_load [expr {$::env(OUTPUT_CAP_LOAD) / 1000.0}] [all_outputs]
set_clock_uncertainty $::env(SYNTH_CLOCK_UNCERTAINTY) $clk
set_clock_transition  $::env(SYNTH_CLOCK_TRANSITION)  $clk
set_timing_derate -early [expr {1 - $::env(SYNTH_TIMING_DERATE)}]
set_timing_derate -late  [expr {1 + $::env(SYNTH_TIMING_DERATE)}]
