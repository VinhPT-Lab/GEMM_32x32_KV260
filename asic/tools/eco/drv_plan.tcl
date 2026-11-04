# 6c DRV ECO, planning (read-only, OpenROAD of OpenLane 1.0.2), judged at SS RC max:
# std cells ss_100C_1v60, macros their typical lib, SPEF RC max, final SDC without
# set_max_transition / set_max_fanout (lib limits), propagated clock.
# Nets: every standard-cell net over a lib limit (env NETS: file, union of the
# TT / SS lists) plus every SRAM dout net over its cap limit here. Clock nets skipped.
# For a std-cell driver: try the larger sizes of its family (same pin names, not
# DONT_USE) in place (replace_cell, the SPEF of the net stays) and keep the smallest
# with every pin of the net at slew <= limit / 1.2 and the driver load <= cap limit / 1.2.
# Otherwise (dlygate, macro / SRAM driver, no larger size, or none passes): BUFFER,
# the buffer size is picked offline (drv_pick.py) from the numbers written here.
# Out: $P/s6c/<ROUND>.plan_raw.tsv
#   net kind driver_pin driver_cell load_pF drv_slew drv_slew_lim drv_cap_lim worst_sink_slew sink_lim action cell
set P $::env(ECO_DIR); set L $::env(PDK_ROOT)/sky130A/libs.ref
set t0 [clock seconds]
read_liberty $L/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__ss_100C_1v60.lib
read_liberty $L/sky130_sram_macros/lib/sky130_sram_2kbyte_1rw1r_32x512_8_TT_1p8V_25C.lib
read_liberty $P/lib/ProcessingElementRow.lib
read_liberty $P/lib/GemmAxiShell.lib
read_db $::env(ODB)
read_sdc $P/in/GEMM_top.libdrv.sdc
set_propagated_clock [all_clocks]
read_spef $::env(SPEF)
set block [ord::get_db_block]
set corner [sta::cmd_corner]
set M 1.2
proc pnames {cell} { set r {}; foreach p [get_lib_pins */$cell/*] { lappend r [get_name $p] }; return [lsort -unique $r] }
set dont_use [split [string trim $::env(DONT_USE)]]
proc dont {m} { foreach p $::dont_use { if { [string match $p $m] } { return 1 } }; return 0 }
proc lim_row {kind p} {
    # "pin limit value slack (VIOLATED)" of report_*_limit_short
    sta::redirect_string_begin
    if { $kind eq "slew" } { sta::report_slew_limit_short $p $::corner max } else { sta::report_capacitance_limit_short $p $::corner max }
    set s [sta::redirect_string_end]
    return [lrange [string trim $s] 1 2]
}
# slew <= limit / M on every pin of the net, load <= cap limit / M at the driver
proc net_ok {net drv} {
    set ws 0; set wl 9; set ok 1
    sta::check_capacitance_limits $net 0 $::corner max   ;# sets up the limit checkers
    foreach p [sta::check_slew_limits $net 0 $::corner max] {
        lassign [lim_row slew $p] lim val
        if { $lim eq "" } { continue }
        if { $val * $::M > $lim } { set ok 0 }
        if { $p ne $drv && $val > $ws } { set ws $val; set wl $lim }
    }
    lassign [lim_row cap $drv] clim cval
    if { $clim ne "" && $cval * $::M > $clim } { set ok 0 }
    return [list $ok $ws $wl]
}
# nets: the union list + SRAM dout cap violators here
set nets [dict create]
set fh [open $::env(NETS)]; while { [gets $fh n] >= 0 } { if { $n ne "" } { dict set nets $n cell } }; close $fh
# SRAM dout cap violators from report_check_types (also builds the timing graph
# before the per-pin limit reports, which crash on an unbuilt graph)
report_check_types -max_capacitance -violators > $P/s6c/$::env(ROUND).cap.rpt
set fh [open $P/s6c/$::env(ROUND).cap.rpt]
while { [gets $fh line] >= 0 } {
    if { [regexp {^(\S+/dout\S*)\s+\S+\s+\S+\s+\S+\s+\(VIOLATED\)} $line -> pin] } {
        set p [sta::find_pin $pin]
        if { $p ne "NULL" && [string match "sky130_sram*" [get_property [$p instance] ref_name]] } {
            dict set nets [get_full_name [get_nets -of_objects $p]] dout
        }
    }
}
close $fh
puts "PLAN nets to look at: [dict size $nets]; [expr {[clock seconds]-$t0}] s"
set out [open $P/s6c/$::env(ROUND).plan_raw.tsv w]
set cnt [dict create]
dict for {n kind} $nets {
    set net [get_nets -quiet $n]
    if { $net eq "" } { puts "PLAN net $n not found"; continue }
    set dn [$block findNet $n]
    if { $dn ne "NULL" && ([$dn getSigType] eq "CLOCK" || [string match clknet_* $n]) } { dict incr cnt skip_clock; continue }
    set drv [lindex [get_pins -quiet -of_objects $net -filter "direction==output"] 0]
    if { $drv eq "" } { puts $out [join [list $n $kind port - - - - - - - SKIP_PORT -] \t]; dict incr cnt skip_port; continue }
    set inst [$drv instance]; set ref [get_property $inst ref_name]
    if { [info exists ::env(TRACE)] } { puts "TRACE $n $ref [get_full_name $drv]"; flush stdout }
    set load [sta::Net_capacitance $net $corner max]
    # the per-pin limit reports need check_*_limits first (checker set-up)
    sta::check_slew_limits $net 0 $corner max; sta::check_capacitance_limits $net 0 $corner max
    lassign [lim_row slew $drv] dsl dsv
    lassign [lim_row cap $drv] dcl dcv
    lassign [net_ok $net $drv] ok ws wl
    set action BUFFER; set cell -
    if { [regexp {^(sky130_fd_sc_hd__\w+?)_(\d+)$} $ref -> fam sz] && ![string match "*dlygate*" $ref] } {
        set myports [pnames $ref]
        set cands {}
        foreach lc [get_lib_cells */${fam}_*] {
            set m [get_name $lc]
            if { ![regexp "^${fam}_(\\d+)\$" $m -> s2] || $s2 <= $sz || [dont $m] } { continue }
            if { [pnames $m] ne $myports } { continue }
            lappend cands [list $s2 $m]
        }
        foreach c [lsort -integer -index 0 $cands] {
            set m [lindex $c 1]
            if { [info exists ::env(TRACE)] } { puts "TRACE   try $m"; flush stdout }
            replace_cell $inst $m
            lassign [net_ok $net $drv] ok2 ws2 wl2
            replace_cell $inst $ref
            if { $ok2 } { set action RESIZE; set cell $m; break }
        }
    }
    dict incr cnt "${kind}_$action"
    puts $out [join [list $n $kind [get_full_name $drv] $ref $load $dsv $dsl $dcl $ws $wl $action $cell] \t]
}
close $out
puts "PLAN counts: $cnt; [expr {[clock seconds]-$t0}] s, peak [expr {[lindex [exec grep VmHWM /proc/[pid]/status] 1]/1024}] MB"
