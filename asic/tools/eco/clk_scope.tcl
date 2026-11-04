# B: every pin on every clock net (clknet_*, S_AXI_ACLK) with its slew and limit, and the
# clock arrival at every sink; last column: the slew itself (max rise/fall; SRAM
# pins carry no limit, so the limit columns are empty for them) (OpenROAD of OL1, SPEF extracted by OL1). Read-only.
# env: C (tt|ff|ss) RC (min|nom|max) ODB SPEF OUTF
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
proc lim {p} {
    sta::redirect_string_begin
    sta::report_slew_limit_short $p $::corner max
    return [lrange [string trim [sta::redirect_string_end]] 1 2]
}
set fo [open $::env(OUTF) w]
set nets [lsort -unique [concat [get_nets -quiet clknet_*] [get_nets -quiet eco_clk_*] [get_nets -quiet S_AXI_ACLK] [get_nets -of_objects [get_pins -hier */clk0]] [get_nets -of_objects [get_pins -hier */clk1]]]]
set block [ord::get_db_block]
foreach net $nets {
    sta::check_slew_limits $net 0 $corner max
    set nm [get_full_name $net]
    set drv [lindex [get_pins -quiet -of_objects $net -filter "direction==output"] 0]
    set dname [expr {$drv eq "" ? "PORT" : [get_full_name $drv]}]
    set dref [expr {$drv eq "" ? "-" : [get_property [$drv instance] ref_name]}]
    set w [[$block findNet $nm] getWire]
    set wl [expr {$w eq "NULL" ? 0 : [$w getLength] / 1000.0}]
    foreach p [get_pins -of_objects $net] {
        set ref [get_property [$p instance] ref_name]
        set dir [get_property $p direction]
        lassign [lim $p] l v
        set a [get_property $p arrival_max_rise]; if { $a eq "" } { set a nan }
        set ai [get_property $p arrival_min_rise]; if { $ai eq "" } { set ai nan }
        set sl [get_property $p slew_max_rise]; set sf [get_property $p slew_max_fall]
        set sw [expr {($sl eq "" || $sf eq "") ? "nan" : max($sl, $sf)}]
        puts $fo "$nm\t$dname\t$dref\t[format %.1f $wl]\t[get_full_name $p]\t$ref\t$dir\t$l\t$v\t$a\t$ai\t$sw"
    }
}
close $fo
puts "CLKSCOPE done [llength $nets] nets"
