# ---------------------------------------------------------------------------
# array.sdc - OpenLane's base.sdc with clock-latency-aware I/O delays.
#
# The ports of this block will face flops of the SAME clock tree in the final
# chip (Buffer_feeder in, Out_buffer out), not an ideal clock at 0 ns. With
# base.sdc the inside flops see a propagated clock of several ns while the
# ports see 0, which in array_v1 gave
#   hold  -2.6 ns  i_feature_vector -> first FeatureSkew flop
#   setup -3.9 ns  flop -> o_partial_sum_vector
# and thousands of useless hold buffers. Here the outside flops are assumed to
# get their clock between GEMM_CLK_LAT_MIN and GEMM_CLK_LAT_MAX (measured from
# the previous run by tools/clock_latency.py -> clk_latency.tcl; 0 if absent,
# which is plain base.sdc behaviour).
# ---------------------------------------------------------------------------
set T     $::env(CLOCK_PERIOD)
set L_MIN [expr {[info exists ::env(GEMM_CLK_LAT_MIN)] ? $::env(GEMM_CLK_LAT_MIN) : 0.0}]
set L_MAX [expr {[info exists ::env(GEMM_CLK_LAT_MAX)] ? $::env(GEMM_CLK_LAT_MAX) : 0.0}]
set EXT   [expr {$T * $::env(IO_PCT)}]      ;# budget for logic outside the block

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
set_input_delay -max [expr {$L_MAX + $EXT}] -clock $clk $ins
set_input_delay -min [expr {$L_MIN}]        -clock $clk $ins
# outputs: captured outside by a flop clocked at L_MIN..L_MAX
set_output_delay -max [expr {$EXT - $L_MIN}] -clock $clk [all_outputs]
set_output_delay -min [expr {-$L_MAX}]       -clock $clk [all_outputs]
puts "\[INFO\]: array.sdc: outside clock latency $L_MIN..$L_MAX ns, external budget $EXT ns"

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
