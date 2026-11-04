# Per listed net: worst slew/limit over its pins and driver cap/limit, at one lib corner
# and one RC corner with the SPEF OL1 extracted (OpenROAD of OL1). Read-only.
# env: C (tt|ff|ss) RC (min|nom|max) ODB SPEF NETS OUTF
set P $::env(ECO_DIR); set L $::env(PDK_ROOT)/sky130A/libs.ref
array set LIB {tt tt_025C_1v80 ff ff_n40C_1v95 ss ss_100C_1v60}
read_liberty $L/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__$LIB($::env(C)).lib
read_liberty $L/sky130_sram_macros/lib/sky130_sram_2kbyte_1rw1r_32x512_8_TT_1p8V_25C.lib
read_liberty $P/lib/ProcessingElementRow.lib
read_liberty $P/lib/GemmAxiShell.lib
read_db $::env(ODB)
read_sdc $P/in/GEMM_top.libdrv.sdc
set_propagated_clock [all_clocks]
read_spef $::env(SPEF)
set corner [sta::cmd_corner]
report_worst_slack -max
proc r {kind p} {
    sta::redirect_string_begin
    if { $kind eq "slew" } { sta::report_slew_limit_short $p $::corner max } else { sta::report_capacitance_limit_short $p $::corner max }
    set s [lrange [string trim [sta::redirect_string_end]] 1 2]
    lassign $s l v
    if { $l eq "" || $v eq "" || $l == 0 } { return 0 }
    return [expr {$v / $l}]
}
set fi [open $::env(NETS)]; set fo [open $::env(OUTF) w]
while { [gets $fi n] >= 0 } {
    set net [get_nets $n]
    sta::check_slew_limits $net 0 $corner max; sta::check_capacitance_limits $net 0 $corner max
    set ws 0; set wc 0
    foreach p [get_pins -of_objects $net] {
        set x [r slew $p]; if { $x > $ws } { set ws $x }
        if { [get_property $p direction] eq "output" } { set x [r cap $p]; if { $x > $wc } { set wc $x } }
    }
    puts $fo [format "%s\t%.3f\t%.3f" $n $ws $wc]
}
close $fi; close $fo
puts "RATIO done"
